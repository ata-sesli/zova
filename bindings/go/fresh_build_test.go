package zova

import "testing"

const freshSchema = `create table files(id integer primary key, path text not null);
create index files_path on files(path);
create virtual table bodies using fts5(body);`

func queryInt(t *testing.T, db *DB, sql string) int64 {
	t.Helper()
	stmt, err := db.Prepare(sql)
	must(t, err)
	defer stmt.Close()
	if step, err := stmt.Step(); err != nil || step != StepRow {
		t.Fatalf("%s: %v %v", sql, step, err)
	}
	value, err := stmt.ColumnInt64(0)
	must(t, err)
	return value
}

func TestFreshBuildCommitsTablesFTSGraphAndVectors(t *testing.T) {
	db := memoryDB(t)
	must(t, db.Exec(freshSchema))
	must(t, db.CreateVectorCollection("embeddings", VectorCollectionOptions{Dimensions: 2, Metric: VectorMetricL2, ElementType: VectorElementTypeF32}))

	build, err := db.BeginFreshBuild()
	must(t, err)
	defer build.Close()
	must(t, build.TableRows("files", []string{"id", "path"}, []any{int64(1), "a.rs", 2, "b.rs"}))
	must(t, build.FTSRows("bodies", []string{"body"}, []any{"fn main"}))
	must(t, build.Graph("code", []GraphFreshNodeInput{freshNode("a.rs"), freshNode("b.rs")}, []GraphFreshEdgePayloadInput{
		{FromNodeOrdinal: 0, EdgeType: "imports", ToNodeOrdinal: 1, Payload: []byte("line=1")},
	}))
	must(t, build.Vectors("embeddings", []VectorInput{{ID: "a.rs", Values: VectorValues{ElementType: VectorElementTypeF32, F32: []float32{1, 0}}}}))
	result, err := build.Finish()
	must(t, err)
	if len(result.NodeKeys) != 2 || len(result.EdgeKeys) != 1 || result.Profile.TableRows != 2 || result.Profile.FTSRows != 1 || result.Profile.VectorRows != 1 {
		t.Fatalf("Finish = %+v", result)
	}
	if got := queryInt(t, db, "select count(*) from files"); got != 2 {
		t.Fatalf("files = %d", got)
	}
	if got := queryInt(t, db, "select count(*) from bodies where bodies match 'main'"); got != 1 {
		t.Fatalf("fts matches = %d", got)
	}
	payloads, err := db.GetGraphEdgePayloads("code", result.EdgeKeys)
	if err != nil || string(payloads[0]) != "line=1" {
		t.Fatalf("payloads = %q, %v", payloads, err)
	}
	if _, err := db.GetVector("embeddings", "a.rs"); err != nil {
		t.Fatal(err)
	}
}

func TestFailedOrClosedFreshBuildsRollBack(t *testing.T) {
	db := memoryDB(t)
	must(t, db.Exec(freshSchema))
	row := []any{int64(1), "a.rs"}

	build, err := db.BeginFreshBuild()
	must(t, err)
	must(t, build.TableRows("files", []string{"id", "path"}, row))
	if err := db.Exec("select 1"); !errorStatusIs(err, StatusInvalidArgument) {
		t.Fatalf("Exec during fresh build = %v", err)
	}
	must(t, build.Close())
	if got := queryInt(t, db, "select count(*) from files"); got != 0 {
		t.Fatalf("closed build kept %d rows", got)
	}

	build, err = db.BeginFreshBuild()
	must(t, err)
	must(t, build.TableRows("files", []string{"id", "path"}, row))
	if err := build.TableRows("missing", []string{"id"}, []any{1}); err == nil || errorStatusIs(err, StatusMisuse) {
		t.Fatalf("missing table = %v", err)
	}
	if err := build.TableRows("files", []string{"id"}, []any{2}); !errorStatusIs(err, StatusMisuse) {
		t.Fatalf("step after failure = %v", err)
	}
	if _, err := build.Finish(); !errorStatusIs(err, StatusMisuse) {
		t.Fatalf("finish after failure = %v", err)
	}
	must(t, build.Close())
	if got := queryInt(t, db, "select count(*) from files"); got != 0 {
		t.Fatalf("failed build kept %d rows", got)
	}

	build, err = db.BeginFreshBuild()
	must(t, err)
	if err := build.TableRows("files", []string{"id", "path"}, []any{1}); !errorStatusIs(err, StatusInvalidArgument) {
		t.Fatalf("partial row = %v", err)
	}
	if err := build.TableRows("files", []string{"id"}, []any{struct{}{}}); !errorStatusIs(err, StatusMisuse) {
		t.Fatalf("step after partial row = %v", err)
	}
	must(t, build.Close())

	build, err = db.BeginFreshBuild()
	must(t, err)
	must(t, build.Abort())
	must(t, build.Close())
	must(t, db.Exec("insert into files(id, path) values (9, 'ok')"))
	must(t, db.CreateGraph("existing"))
	if _, err := db.BeginFreshBuild(); !errorStatusIs(err, StatusInvalidArgument) {
		t.Fatalf("fresh build over non-empty graph store = %v", err)
	}

	// Closing the DB releases a live session.
	other := memoryDB(t)
	must(t, other.Exec(freshSchema))
	live, err := other.BeginFreshBuild()
	must(t, err)
	must(t, other.Close())
	if err := live.Close(); err == nil {
		t.Fatal("Close after DB close succeeded")
	}
}
