package zova

import "testing"

func TestNotificationsFollowTransactionsAndSQLNotify(t *testing.T) {
	path := tempZovaPath(t, "notifications")
	db, err := Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	sub, err := db.Listen("messages")
	if err != nil {
		t.Fatal(err)
	}
	defer sub.Close()

	must(t, db.Notify("messages", "outside"))
	note, err := sub.TryReceive()
	if err != nil {
		t.Fatal(err)
	}
	if note == nil || note.Channel != "messages" || note.Payload != "outside" || note.Sequence != 1 || note.DroppedBefore != 0 {
		t.Fatalf("unexpected notification: %#v", note)
	}
	note, err = sub.TryReceive()
	if err != nil {
		t.Fatal(err)
	}
	if note != nil {
		t.Fatalf("expected empty queue, got %#v", note)
	}

	must(t, db.BeginImmediate())
	must(t, db.Notify("messages", "committed"))
	note, err = sub.TryReceive()
	if err != nil {
		t.Fatal(err)
	}
	if note != nil {
		t.Fatalf("expected pending notification before commit, got %#v", note)
	}
	must(t, db.Commit())
	note, err = sub.TryReceive()
	if err != nil {
		t.Fatal(err)
	}
	if note == nil || note.Payload != "committed" {
		t.Fatalf("expected committed notification, got %#v", note)
	}

	must(t, db.BeginImmediate())
	must(t, db.Notify("messages", "rolled-back"))
	must(t, db.Rollback())
	note, err = sub.TryReceive()
	if err != nil {
		t.Fatal(err)
	}
	if note != nil {
		t.Fatalf("rollback delivered notification: %#v", note)
	}

	must(t, db.BeginImmediate())
	must(t, db.Savepoint("inner"))
	must(t, db.Notify("messages", "discarded-savepoint"))
	must(t, db.RollbackToSavepoint("inner"))
	must(t, db.Notify("messages", "kept-savepoint"))
	must(t, db.ReleaseSavepoint("inner"))
	must(t, db.Commit())
	note, err = sub.TryReceive()
	if err != nil {
		t.Fatal(err)
	}
	if note == nil || note.Payload != "kept-savepoint" {
		t.Fatalf("expected savepoint notification, got %#v", note)
	}
	note, err = sub.TryReceive()
	if err != nil {
		t.Fatal(err)
	}
	if note != nil {
		t.Fatalf("savepoint rollback delivered discarded notification: %#v", note)
	}

	sqlSub, err := db.Listen("sql")
	if err != nil {
		t.Fatal(err)
	}
	defer sqlSub.Close()
	stmt, err := db.Prepare("select zova_notify('sql', 'from-sql')")
	if err != nil {
		t.Fatal(err)
	}
	step, err := stmt.Step()
	if err != nil || step != StepRow {
		t.Fatalf("sql notify step = %v, %v", step, err)
	}
	must(t, stmt.Close())
	note, err = sqlSub.TryReceive()
	if err != nil {
		t.Fatal(err)
	}
	if note == nil || note.Payload != "from-sql" {
		t.Fatalf("expected SQL notification, got %#v", note)
	}
}

func TestSubscriptionCloseAndValidation(t *testing.T) {
	path := tempZovaPath(t, "notification-close")
	db, err := Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	if _, err := db.Listen("_zova_private"); !errorStatusIs(err, StatusInvalidArgument) {
		t.Fatalf("expected invalid channel error, got %v", err)
	}
	if err := db.Notify("bad channel", "payload"); !errorStatusIs(err, StatusInvalidArgument) {
		t.Fatalf("expected invalid notify channel error, got %v", err)
	}
	if err := db.Notify("events", string([]byte{0xff})); !errorStatusIs(err, StatusInvalidArgument) {
		t.Fatalf("expected invalid payload error, got %v", err)
	}

	sub, err := db.Listen("events")
	if err != nil {
		t.Fatal(err)
	}
	if err := db.Exec("select zova_notify('_zova_private', 'payload')"); !errorStatusIs(err, StatusSQLiteError) {
		t.Fatalf("expected SQL notify error, got %v", err)
	}
	if note, err := sub.TryReceive(); err != nil || note != nil {
		t.Fatalf("invalid SQL notify enqueued notification: %#v, %v", note, err)
	}
	must(t, sub.Close())
	if _, err := sub.TryReceive(); !errorStatusIs(err, StatusMisuse) {
		t.Fatalf("expected closed subscription error, got %v", err)
	}
}

func TestNotificationObjectMetadataWorkflow(t *testing.T) {
	path := tempZovaPath(t, "notification-object-workflow")
	db, err := Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	must(t, db.Exec("create table attachments(id integer primary key, object_id blob not null)"))
	sub, err := db.Listen("message:1:attachments")
	if err != nil {
		t.Fatal(err)
	}
	defer sub.Close()

	objectID, err := db.PutObject([]byte("attachment bytes"))
	if err != nil {
		t.Fatal(err)
	}
	must(t, db.BeginImmediate())
	insert, err := db.Prepare("insert into attachments(object_id) values (?1)")
	if err != nil {
		t.Fatal(err)
	}
	must(t, insert.BindBlob(1, objectID[:]))
	if step, err := insert.Step(); err != nil || step != StepDone {
		t.Fatalf("insert object id = %v, %v", step, err)
	}
	must(t, insert.Close())
	must(t, db.Notify("message:1:attachments", "changed"))
	if note, err := sub.TryReceive(); err != nil || note != nil {
		t.Fatalf("notification before commit = %#v, %v", note, err)
	}
	must(t, db.Commit())

	note, err := sub.TryReceive()
	if err != nil {
		t.Fatal(err)
	}
	if note == nil || note.Payload != "changed" {
		t.Fatalf("expected object workflow notification, got %#v", note)
	}

	query, err := db.Prepare("select object_id from attachments")
	if err != nil {
		t.Fatal(err)
	}
	defer query.Close()
	if step, err := query.Step(); err != nil || step != StepRow {
		t.Fatalf("query object id = %v, %v", step, err)
	}
	stored, ok, err := query.ColumnBlob(0)
	if err != nil || !ok {
		t.Fatalf("stored object id = %v, %v", ok, err)
	}
	var storedID ObjectID
	copy(storedID[:], stored)
	got, err := db.GetObject(storedID)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "attachment bytes" {
		t.Fatalf("stored object = %q", got)
	}
}

func TestNotificationVectorMetadataWorkflow(t *testing.T) {
	path := tempZovaPath(t, "notification-vector-workflow")
	db, err := Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	must(t, db.Exec("create table chunks(id text primary key, vector_id text not null)"))
	must(t, db.CreateVectorCollection("chunks", VectorCollectionOptions{
		Dimensions: 2,
		Metric:     VectorMetricL2,
	}))
	must(t, db.PutVector("chunks", "chunk:1", []float32{0, 0}))
	sub, err := db.Listen("vectors:chunks")
	if err != nil {
		t.Fatal(err)
	}
	defer sub.Close()

	must(t, db.BeginImmediate())
	must(t, db.Exec("insert into chunks(id, vector_id) values ('c1', 'chunk:1')"))
	must(t, db.Notify("vectors:chunks", "changed"))
	if note, err := sub.TryReceive(); err != nil || note != nil {
		t.Fatalf("notification before commit = %#v, %v", note, err)
	}
	must(t, db.Commit())

	note, err := sub.TryReceive()
	if err != nil {
		t.Fatal(err)
	}
	if note == nil || note.Payload != "changed" {
		t.Fatalf("expected vector workflow notification, got %#v", note)
	}
	results, err := db.SearchVectors("chunks", []float32{0, 0}, 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(results) != 1 || results[0].ID != "chunk:1" {
		t.Fatalf("unexpected vector results: %#v", results)
	}
}
