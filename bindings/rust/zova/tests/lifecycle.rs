use zova::{ColumnType, Database, Error, Status, Step};

fn temp_path(name: &str) -> String {
    let mut path = std::env::temp_dir();
    path.push(format!(
        "zova-rust-safe-{}-{}-{name}.zova",
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
fn create_open_exec_and_prepare_records() {
    let path = temp_path("records");
    {
        let mut db = Database::create(&path).unwrap();
        db.exec("create table records(id integer primary key, name text not null, payload blob)")
            .unwrap();

        let mut insert = db
            .prepare("insert into records(name, payload) values (:name, :payload)")
            .unwrap();
        assert_eq!(insert.parameter_count().unwrap(), 2);
        assert_eq!(insert.parameter_index(":name").unwrap(), Some(1));
        assert_eq!(insert.parameter_index(":missing").unwrap(), None);
        insert.bind_text(1, "alpha").unwrap();
        insert.bind_blob(2, b"\0bytes").unwrap();
        assert_eq!(insert.step().unwrap(), Step::Done);
    }
    {
        let mut db = Database::open(&path).unwrap();
        let mut query = db
            .prepare("select id, name, payload from records where name = ?1")
            .unwrap();
        query.bind_text(1, "alpha").unwrap();
        assert_eq!(query.step().unwrap(), Step::Row);
        assert_eq!(query.column_count().unwrap(), 3);
        assert_eq!(query.column_type(0).unwrap(), ColumnType::Integer);
        assert_eq!(query.column_i64(0).unwrap(), 1);
        assert_eq!(query.column_text(1).unwrap(), Some("alpha".to_string()));
        assert_eq!(query.column_blob(2).unwrap(), Some(b"\0bytes".to_vec()));
        assert_eq!(query.step().unwrap(), Step::Done);
    }
    let _ = std::fs::remove_file(path);
}

#[test]
fn statements_round_trip_all_basic_types_and_nulls() {
    let path = temp_path("types");
    let mut db = Database::create(&path).unwrap();
    db.exec(
        "create table values_table(
            i integer,
            f real,
            n text,
            empty_text text,
            text_value text,
            empty_blob blob,
            blob_value blob
        )",
    )
    .unwrap();

    let mut insert = db
        .prepare("insert into values_table values (?1, ?2, ?3, ?4, ?5, ?6, ?7)")
        .unwrap();
    insert.bind_i64(1, -7).unwrap();
    insert.bind_f64(2, 3.5).unwrap();
    insert.bind_null(3).unwrap();
    insert.bind_text(4, "").unwrap();
    insert.bind_text(5, "hello").unwrap();
    insert.bind_blob(6, b"").unwrap();
    insert.bind_blob(7, &[1, 2, 3]).unwrap();
    assert_eq!(insert.step().unwrap(), Step::Done);
    drop(insert);

    let mut query = db.prepare("select * from values_table").unwrap();
    assert_eq!(query.step().unwrap(), Step::Row);
    assert_eq!(query.column_i64(0).unwrap(), -7);
    assert_eq!(query.column_f64(1).unwrap(), 3.5);
    assert_eq!(query.column_type(2).unwrap(), ColumnType::Null);
    assert_eq!(query.column_text(2).unwrap(), None);
    assert_eq!(query.column_text(3).unwrap(), Some(String::new()));
    assert_eq!(query.column_text(4).unwrap(), Some("hello".to_string()));
    assert_eq!(query.column_blob(5).unwrap(), Some(Vec::new()));
    assert_eq!(query.column_blob(6).unwrap(), Some(vec![1, 2, 3]));
    let _ = std::fs::remove_file(path);
}

#[test]
fn reset_preserves_bindings_and_clear_bindings_removes_them() {
    let path = temp_path("reset");
    let mut db = Database::create(&path).unwrap();
    let mut statement = db.prepare("select ?1").unwrap();
    assert_eq!(
        statement.bind_i64(0, 1).unwrap_err().status(),
        Some(Status::InvalidArgument)
    );
    statement.bind_i64(1, 99).unwrap();
    assert_eq!(statement.step().unwrap(), Step::Row);
    assert_eq!(statement.column_i64(0).unwrap(), 99);

    statement.reset().unwrap();
    assert_eq!(statement.step().unwrap(), Step::Row);
    assert_eq!(statement.column_i64(0).unwrap(), 99);

    statement.reset().unwrap();
    statement.clear_bindings().unwrap();
    assert_eq!(statement.step().unwrap(), Step::Row);
    assert_eq!(statement.column_type(0).unwrap(), ColumnType::Null);
    let _ = std::fs::remove_file(path);
}

#[test]
fn transactions_commit_rollback_and_vacuum_work() {
    let path = temp_path("transactions");
    let mut db = Database::create(&path).unwrap();
    db.exec("create table tx(id integer primary key, value text)")
        .unwrap();

    db.begin().unwrap();
    db.exec("insert into tx(value) values ('commit')").unwrap();
    db.commit().unwrap();

    db.begin_immediate().unwrap();
    db.exec("insert into tx(value) values ('rollback')")
        .unwrap();
    db.rollback().unwrap();

    let mut count = db.prepare("select count(*) from tx").unwrap();
    assert_eq!(count.step().unwrap(), Step::Row);
    assert_eq!(count.column_i64(0).unwrap(), 1);
    drop(count);

    db.vacuum().unwrap();
    let _ = std::fs::remove_file(path);
}

#[test]
fn errors_preserve_status_and_reject_bad_strings() {
    let bad = Database::create("bad\0path.zova").unwrap_err();
    assert!(matches!(bad, Error::InteriorNul { .. }));

    let mut plain_path = std::env::temp_dir();
    plain_path.push(format!(
        "zova-rust-safe-{}-{}.db",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let path = plain_path.to_str().unwrap().to_owned();
    let err = Database::create(&path).unwrap_err();
    assert_eq!(err.status(), Some(Status::NotZovaPath));

    let path = temp_path("sql");
    let mut db = Database::create(&path).unwrap();
    let err = db.exec("select * from no_such_table").unwrap_err();
    assert_eq!(err.status(), Some(Status::SqliteError));
    assert!(err.to_string().contains("no_such_table"));
    let _ = std::fs::remove_file(path);
}
