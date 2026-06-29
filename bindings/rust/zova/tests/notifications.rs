use zova::{Database, SharedDatabase, Status, Step, VectorCollectionOptions, VectorMetric};

fn temp_path(name: &str) -> String {
    let mut path = std::env::temp_dir();
    path.push(format!(
        "zova-rust-notify-{}-{}-{name}.zova",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let _ = std::fs::remove_file(&path);
    path.to_str().unwrap().to_owned()
}

#[test]
fn database_notifications_follow_transaction_boundaries() {
    let path = temp_path("database");
    let mut db = Database::create(&path).unwrap();
    let mut sub = db.listen("messages").unwrap();

    db.notify("messages", "outside").unwrap();
    let note = sub.try_receive().unwrap().unwrap();
    assert_eq!(note.channel, "messages");
    assert_eq!(note.payload, "outside");
    assert_eq!(note.sequence, 1);
    assert_eq!(note.dropped_before, 0);
    assert!(sub.try_receive().unwrap().is_none());

    db.begin_immediate().unwrap();
    db.notify("messages", "committed").unwrap();
    assert!(sub.try_receive().unwrap().is_none());
    db.commit().unwrap();
    assert_eq!(sub.try_receive().unwrap().unwrap().payload, "committed");

    db.begin_immediate().unwrap();
    db.notify("messages", "rolled-back").unwrap();
    db.rollback().unwrap();
    assert!(sub.try_receive().unwrap().is_none());

    db.with_savepoint("sp", |db| {
        db.notify("messages", "scoped")?;
        Ok(())
    })
    .unwrap();
    assert_eq!(sub.try_receive().unwrap().unwrap().payload, "scoped");

    drop(sub);
    drop(db);
    let _ = std::fs::remove_file(path);
}

#[test]
fn sql_notify_and_shared_database_notifications_work() {
    let path = temp_path("shared");
    let db = SharedDatabase::create(&path).unwrap();
    let mut sub = db.listen("objects:changed").unwrap();

    db.transaction_immediate(|guard| {
        guard.exec("create table objects(id integer primary key, label text)")?;
        guard.exec("insert into objects(label) values ('first')")?;
        guard.notify("objects:changed", "changed")?;
        Ok(())
    })
    .unwrap();
    assert_eq!(sub.try_receive().unwrap().unwrap().payload, "changed");

    let mut sql_sub = db.listen("sql").unwrap();
    let mut stmt = db.prepare("select zova_notify('sql', 'from-sql')").unwrap();
    assert_eq!(stmt.step().unwrap(), Step::Row);
    drop(stmt);
    assert_eq!(sql_sub.try_receive().unwrap().unwrap().payload, "from-sql");

    drop(sql_sub);
    drop(sub);
    drop(db);
    let _ = std::fs::remove_file(path);
}

#[test]
fn shared_database_notifications_work_across_threads() {
    let path = temp_path("shared-threads");
    let db = SharedDatabase::create(&path).unwrap();
    let mut sub = db.listen("workers").unwrap();

    let mut threads = Vec::new();
    for _ in 0..4 {
        let db = db.clone();
        threads.push(std::thread::spawn(move || {
            db.notify("workers", "changed").unwrap();
        }));
    }
    for thread in threads {
        thread.join().unwrap();
    }

    let mut received = 0;
    while sub.try_receive().unwrap().is_some() {
        received += 1;
    }
    assert_eq!(received, 4);

    drop(sub);
    drop(db);
    let _ = std::fs::remove_file(path);
}

#[test]
fn notification_validation_errors_do_not_enqueue() {
    let path = temp_path("validation");
    let mut db = Database::create(&path).unwrap();
    let mut sub = db.listen("messages").unwrap();

    match db.listen("_zova_private") {
        Ok(_) => panic!("invalid channel unexpectedly created a subscription"),
        Err(err) => assert_eq!(err.status(), Some(Status::InvalidArgument)),
    }

    let err = db.notify("bad channel", "payload").unwrap_err();
    assert_eq!(err.status(), Some(Status::InvalidArgument));

    let long_payload = "x".repeat(64 * 1024 + 1);
    let err = db.notify("messages", &long_payload).unwrap_err();
    assert_eq!(err.status(), Some(Status::InvalidArgument));

    let err = db
        .exec("select zova_notify('_zova_private', 'payload')")
        .unwrap_err();
    assert_eq!(err.status(), Some(Status::SqliteError));
    assert!(sub.try_receive().unwrap().is_none());

    sub.close().unwrap();
    let err = sub.try_receive().unwrap_err();
    assert_eq!(err.status(), Some(Status::Misuse));

    drop(db);
    let _ = std::fs::remove_file(path);
}

#[test]
fn object_metadata_workflow_notifies_after_commit() {
    let path = temp_path("object-workflow");
    let mut db = Database::create(&path).unwrap();
    db.exec("create table attachments(id integer primary key, object_id blob not null)")
        .unwrap();
    let mut sub = db.listen("message:1:attachments").unwrap();

    let object_id = db.put_object(b"attachment bytes").unwrap();
    db.begin_immediate().unwrap();
    let mut insert = db
        .prepare("insert into attachments(object_id) values (?1)")
        .unwrap();
    insert.bind_blob(1, object_id.as_ref()).unwrap();
    assert_eq!(insert.step().unwrap(), Step::Done);
    drop(insert);
    db.notify("message:1:attachments", "changed").unwrap();
    assert!(sub.try_receive().unwrap().is_none());
    db.commit().unwrap();

    assert_eq!(sub.try_receive().unwrap().unwrap().payload, "changed");
    let mut query = db.prepare("select object_id from attachments").unwrap();
    assert_eq!(query.step().unwrap(), Step::Row);
    assert_eq!(query.column_blob(0).unwrap().unwrap(), object_id.as_ref());

    drop(query);
    drop(sub);
    drop(db);
    let _ = std::fs::remove_file(path);
}

#[test]
fn vector_metadata_workflow_notifies_after_commit() {
    let path = temp_path("vector-workflow");
    let mut db = Database::create(&path).unwrap();
    db.exec("create table chunks(id text primary key, vector_id text not null)")
        .unwrap();
    db.create_vector_collection(
        "chunks",
        VectorCollectionOptions {
            dimensions: 2,
            metric: VectorMetric::L2,
        },
    )
    .unwrap();
    db.put_vector("chunks", "chunk:1", &[0.0, 0.0]).unwrap();
    let mut sub = db.listen("vectors:chunks").unwrap();

    db.begin_immediate().unwrap();
    db.exec("insert into chunks(id, vector_id) values ('c1', 'chunk:1')")
        .unwrap();
    db.notify("vectors:chunks", "changed").unwrap();
    assert!(sub.try_receive().unwrap().is_none());
    db.commit().unwrap();

    assert_eq!(sub.try_receive().unwrap().unwrap().payload, "changed");
    let results = db.search_vectors("chunks", &[0.0, 0.0], 1).unwrap();
    assert_eq!(results[0].id, "chunk:1");

    drop(sub);
    drop(db);
    let _ = std::fs::remove_file(path);
}
