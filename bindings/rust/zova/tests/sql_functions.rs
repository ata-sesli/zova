use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use zova::{Database, SharedDatabase, SqlFunctionFlags, SqlFunctionResult, SqlValue, Status, Step};

fn deterministic() -> SqlFunctionFlags {
    SqlFunctionFlags {
        deterministic: true,
        ..SqlFunctionFlags::default()
    }
}

fn describe(args: &[SqlValue<'_>]) -> SqlFunctionResult {
    let parts = args
        .iter()
        .map(|value| match value {
            SqlValue::Null => "null".to_owned(),
            SqlValue::Integer(value) => format!("i:{value}"),
            SqlValue::Float(value) => format!("f:{value}"),
            SqlValue::Text(value) => format!("t:{value}"),
            SqlValue::Blob(value) => format!("b:{}", value.len()),
        })
        .collect::<Vec<_>>();
    SqlFunctionResult::Text(parts.join(","))
}

#[test]
fn scalar_functions_receive_arguments_and_return_every_result_type() {
    let mut db = Database::create_memory().unwrap();
    db.register_function("describe", -1, deterministic(), describe)
        .unwrap();
    db.register_function("pick", 1, SqlFunctionFlags::default(), |args| {
        match args[0] {
            SqlValue::Integer(0) => SqlFunctionResult::Null,
            SqlValue::Integer(1) => SqlFunctionResult::Integer(7),
            SqlValue::Integer(2) => SqlFunctionResult::Float(2.5),
            SqlValue::Integer(3) => SqlFunctionResult::Blob(vec![1, 2, 3]),
            _ => SqlFunctionResult::Error("pick: unsupported".to_owned()),
        }
    })
    .unwrap();

    let mut statement = db
        .prepare("select describe(null, 1, 1.5, 'x', x'0102'), pick(0), pick(1), pick(2), pick(3)")
        .unwrap();
    assert_eq!(statement.step().unwrap(), Step::Row);
    assert_eq!(
        statement.column_text(0).unwrap().as_deref(),
        Some("null,i:1,f:1.5,t:x,b:2")
    );
    assert_eq!(statement.column_type(1).unwrap(), zova::ColumnType::Null);
    assert_eq!(statement.column_i64(2).unwrap(), 7);
    assert_eq!(statement.column_f64(3).unwrap(), 2.5);
    assert_eq!(statement.column_blob(4).unwrap(), Some(vec![1, 2, 3]));
    drop(statement);

    let error = db.exec("select pick(9)").unwrap_err();
    assert!(error.to_string().contains("pick: unsupported"), "{error}");
}

#[test]
fn panics_and_invalid_utf8_become_sql_errors() {
    let mut db = Database::create_memory().unwrap();
    db.register_function("boom", 0, SqlFunctionFlags::default(), |_| {
        panic!("boom");
    })
    .unwrap();
    db.register_function("echo", 1, SqlFunctionFlags::default(), describe)
        .unwrap();
    assert!(db
        .exec("select boom()")
        .unwrap_err()
        .to_string()
        .contains("panicked"));
    assert!(db
        .exec("select echo(cast(x'ff' as text))")
        .unwrap_err()
        .to_string()
        .contains("UTF-8"));
    // The handle remains usable after a callback failure.
    db.exec("select echo(1)").unwrap();
}

#[test]
fn invalid_registrations_are_rejected_and_release_the_closure() {
    let mut db = Database::create_memory().unwrap();
    let drops = Arc::new(AtomicUsize::new(0));
    struct Counted(Arc<AtomicUsize>);
    impl Drop for Counted {
        fn drop(&mut self) {
            self.0.fetch_add(1, Ordering::SeqCst);
        }
    }
    let make = |drops: &Arc<AtomicUsize>| {
        let counted = Counted(Arc::clone(drops));
        move |_: &[SqlValue<'_>]| {
            let _ = &counted;
            SqlFunctionResult::Null
        }
    };

    for (name, arity) in [("zova_reserved", 0), ("bad name", 0), ("", 0), ("ok", 128)] {
        let error = db
            .register_function(name, arity, SqlFunctionFlags::default(), make(&drops))
            .unwrap_err();
        assert_eq!(
            error.status(),
            Some(Status::InvalidArgument),
            "{name}/{arity}"
        );
    }
    assert_eq!(drops.load(Ordering::SeqCst), 4);

    db.register_function("once", 0, SqlFunctionFlags::default(), make(&drops))
        .unwrap();
    assert!(db
        .register_function("once", 0, SqlFunctionFlags::default(), make(&drops))
        .is_err());
    assert_eq!(drops.load(Ordering::SeqCst), 5);
    db.register_function("once", 1, SqlFunctionFlags::default(), make(&drops))
        .unwrap();
    drop(db);
    assert_eq!(drops.load(Ordering::SeqCst), 7);
}

#[test]
fn shared_database_functions_run_on_other_threads() {
    let db = SharedDatabase::create_memory().unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    let counter = Arc::clone(&calls);
    db.register_function("bump", 1, SqlFunctionFlags::default(), move |args| {
        counter.fetch_add(1, Ordering::SeqCst);
        match args[0] {
            SqlValue::Integer(value) => SqlFunctionResult::Integer(value + 1),
            _ => SqlFunctionResult::Null,
        }
    })
    .unwrap();
    db.with_exclusive(|guard| {
        guard.register_function("twice", 1, deterministic(), |args| match args[0] {
            SqlValue::Integer(value) => SqlFunctionResult::Integer(value * 2),
            _ => SqlFunctionResult::Null,
        })
    })
    .unwrap();

    let handles = (0..4)
        .map(|index| {
            let db = db.clone();
            std::thread::spawn(move || {
                let mut statement = db.prepare("select twice(bump(?1))").unwrap();
                statement.bind_i64(1, index).unwrap();
                assert_eq!(statement.step().unwrap(), Step::Row);
                statement.column_i64(0).unwrap()
            })
        })
        .collect::<Vec<_>>();
    let mut results = handles
        .into_iter()
        .map(|handle| handle.join().unwrap())
        .collect::<Vec<_>>();
    results.sort();
    assert_eq!(results, [2, 4, 6, 8]);
    assert_eq!(calls.load(Ordering::SeqCst), 4);
}
