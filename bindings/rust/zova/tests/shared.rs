use std::thread;
use zova::{
    object_id, GraphEdgeInput, GraphNeighborDirection, GraphNeighborsOptions, GraphNodeInput,
    GraphTargetType, GraphWalkOptions, SharedDatabase, SharedObjectWriter, SharedStatement, Status,
    Step, VectorCollectionOptions, VectorInput, VectorMetric, DEFAULT_GRAPH_NAME,
};

fn temp_path(name: &str) -> String {
    let mut path = std::env::temp_dir();
    path.push(format!(
        "zova-rust-shared-{}-{}-{name}.zova",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let _ = std::fs::remove_file(&path);
    path.to_str().unwrap().to_owned()
}

fn fixture_bytes(len: usize) -> Vec<u8> {
    (0..len)
        .map(|index| ((index * 17 + index / 5) % 251) as u8)
        .collect()
}

fn assert_send<T: Send>() {}

fn assert_send_sync<T: Send + Sync>() {}

fn graph_node<'a>(node_id: &'a str) -> GraphNodeInput<'a> {
    GraphNodeInput {
        graph_name: DEFAULT_GRAPH_NAME,
        node_id,
        kind: "message",
        target_type: GraphTargetType::None,
        target_namespace: None,
        target_ref: None,
    }
}

fn graph_edge<'a>(
    from_node_id: &'a str,
    edge_type: &'a str,
    to_node_id: &'a str,
) -> GraphEdgeInput<'a> {
    GraphEdgeInput {
        graph_name: DEFAULT_GRAPH_NAME,
        from_node_id,
        edge_type,
        to_node_id,
    }
}

#[test]
fn shared_database_traits_are_thread_safe_opt_in_surface() {
    assert_send_sync::<SharedDatabase>();
    assert_send::<SharedStatement>();
    assert_send::<SharedObjectWriter>();

    let path = temp_path("traits");
    let db = SharedDatabase::create(&path).unwrap();
    let cloned = db.clone();
    cloned
        .exec("create table t(id integer primary key)")
        .unwrap();
    drop(db);
    cloned.exec("insert into t default values").unwrap();
    let _ = std::fs::remove_file(path);
}

#[test]
fn cloned_shared_database_serializes_concurrent_sql_calls() {
    let path = temp_path("sql");
    let db = SharedDatabase::create(&path).unwrap();
    db.exec("create table events(id integer primary key, worker integer, seq integer)")
        .unwrap();

    let mut threads = Vec::new();
    for worker in 0..6 {
        let db = db.clone();
        threads.push(thread::spawn(move || {
            for seq in 0..25 {
                db.exec(&format!(
                    "insert into events(worker, seq) values ({worker}, {seq})"
                ))
                .unwrap();
            }
        }));
    }
    for thread in threads {
        thread.join().unwrap();
    }

    let mut query = db.prepare("select count(*) from events").unwrap();
    assert_eq!(query.step().unwrap(), Step::Row);
    assert_eq!(query.column_i64(0).unwrap(), 150);
    let _ = std::fs::remove_file(path);
}

#[test]
fn shared_statement_can_move_to_another_thread() {
    let path = temp_path("statement");
    let db = SharedDatabase::create(&path).unwrap();
    let mut statement = db.prepare("select ?1 as body").unwrap();
    statement.bind_text(1, "from another thread").unwrap();

    let result = thread::spawn(move || {
        assert_eq!(statement.step().unwrap(), Step::Row);
        assert_eq!(statement.column_name(0).unwrap(), "body");
        statement.column_text(0).unwrap()
    })
    .join()
    .unwrap();

    assert_eq!(result, Some("from another thread".to_string()));
    let _ = std::fs::remove_file(path);
}

#[test]
fn shared_object_writer_can_move_to_another_thread() {
    let path = temp_path("writer");
    let db = SharedDatabase::create(&path).unwrap();
    let bytes = fixture_bytes(96_000);
    let expected = object_id(&bytes).unwrap();
    let writer = db.object_writer().unwrap();
    let writer_bytes = bytes.clone();

    let id = thread::spawn(move || {
        let mut writer = writer;
        for chunk in writer_bytes.chunks(137) {
            writer.write(chunk).unwrap();
        }
        writer.finish().unwrap()
    })
    .join()
    .unwrap();

    assert_eq!(id, expected);
    assert_eq!(db.get_object(id).unwrap(), bytes);
    let _ = std::fs::remove_file(path);
}

#[test]
fn cloned_shared_database_handles_objects_and_vectors_from_threads() {
    let path = temp_path("objects-vectors");
    let db = SharedDatabase::create(&path).unwrap();
    db.create_vector_collection(
        "items",
        VectorCollectionOptions {
            dimensions: 2,
            metric: VectorMetric::L2,
        },
    )
    .unwrap();

    let mut threads = Vec::new();
    for index in 0..8 {
        let db = db.clone();
        threads.push(thread::spawn(move || {
            let bytes = format!("object-{index}").into_bytes();
            let id = db.put_object(&bytes).unwrap();
            let mut prefix = vec![0; 6];
            assert_eq!(db.read_object_range(id, 0, &mut prefix).unwrap(), 6);
            assert_eq!(&prefix, b"object");

            let vector_id = format!("v{index}");
            db.put_vector("items", &vector_id, &[index as f32, 0.0])
                .unwrap();
        }));
    }
    for thread in threads {
        thread.join().unwrap();
    }

    let nearest = db.search_vectors("items", &[0.0, 0.0], 3).unwrap();
    assert_eq!(nearest[0].id, "v0");
    let _ = std::fs::remove_file(path);
}

#[test]
fn cloned_shared_database_handles_graphs_from_threads() {
    let path = temp_path("graphs");
    let db = SharedDatabase::create(&path).unwrap();
    db.create_graph(DEFAULT_GRAPH_NAME).unwrap();

    let mut threads = Vec::new();
    for index in 0..8 {
        let db = db.clone();
        threads.push(thread::spawn(move || {
            let node_id = format!("message:{index}");
            db.put_graph_node(GraphNodeInput {
                graph_name: DEFAULT_GRAPH_NAME,
                node_id: &node_id,
                kind: "message",
                target_type: GraphTargetType::Record,
                target_namespace: Some("messages"),
                target_ref: Some(&node_id),
            })
            .unwrap();
            assert!(db.has_graph_node(DEFAULT_GRAPH_NAME, &node_id).unwrap());
        }));
    }
    for thread in threads {
        thread.join().unwrap();
    }

    db.put_graph_edge(graph_edge("message:0", "mentions", "message:1"))
        .unwrap();
    let neighbors = db
        .graph_neighbors(GraphNeighborsOptions {
            graph_name: DEFAULT_GRAPH_NAME,
            node_id: "message:0",
            direction: GraphNeighborDirection::Outgoing,
            edge_type: Some("mentions"),
            limit: 10,
        })
        .unwrap();
    assert_eq!(neighbors[0].node_id, "message:1");

    let err = db
        .get_graph_node(DEFAULT_GRAPH_NAME, "missing")
        .unwrap_err();
    assert_eq!(err.status(), Some(Status::GraphNodeNotFound));
    let message = err.to_string();
    db.exec("select 1").unwrap();
    assert!(message.contains("ZOVA_GRAPH_NODE_NOT_FOUND"));
    let _ = std::fs::remove_file(path);
}

#[test]
fn shared_graph_operations_work_inside_transactions_and_savepoints() {
    let path = temp_path("graph-transactions");
    let db = SharedDatabase::create(&path).unwrap();
    db.create_graph(DEFAULT_GRAPH_NAME).unwrap();

    let err = db
        .transaction_immediate(|guard| {
            guard.put_graph_node(graph_node("rolled-back"))?;
            guard.get_graph_node(DEFAULT_GRAPH_NAME, "missing")?;
            Ok(())
        })
        .unwrap_err();
    assert_eq!(err.status(), Some(zova::Status::GraphNodeNotFound));
    assert!(!db
        .has_graph_node(DEFAULT_GRAPH_NAME, "rolled-back")
        .unwrap());

    db.transaction_immediate(|guard| {
        guard.put_graph_node(graph_node("root"))?;
        guard.with_savepoint("sp_graph", |guard| {
            guard.put_graph_node(graph_node("child"))?;
            guard.put_graph_edge(graph_edge("root", "links", "child"))?;
            Ok(())
        })?;
        Ok(())
    })
    .unwrap();

    let walk = db
        .graph_walk(GraphWalkOptions {
            graph_name: DEFAULT_GRAPH_NAME,
            start_node_id: "root",
            edge_type: None,
            max_depth: 2,
            limit: 10,
        })
        .unwrap();
    assert_eq!(
        walk.iter()
            .map(|item| item.node_id.as_str())
            .collect::<Vec<_>>(),
        ["root", "child"]
    );
    let _ = std::fs::remove_file(path);
}

#[test]
fn shared_transactions_hold_the_rust_mutex_for_the_whole_closure() {
    let path = temp_path("transaction");
    let db = SharedDatabase::create(&path).unwrap();
    db.exec("create table tx(id integer primary key, value text)")
        .unwrap();

    let err = db
        .transaction(|guard| {
            guard.exec("insert into tx(value) values ('rolled back')")?;
            guard.exec("select * from missing_table")?;
            Ok(())
        })
        .unwrap_err();
    assert!(err.to_string().contains("missing_table"));

    let mut count = db.prepare("select count(*) from tx").unwrap();
    assert_eq!(count.step().unwrap(), Step::Row);
    assert_eq!(count.column_i64(0).unwrap(), 0);
    drop(count);

    db.transaction_immediate(|guard| {
        guard.exec("insert into tx(value) values ('a')")?;
        guard.exec("insert into tx(value) values ('b')")?;
        assert_eq!(guard.changes()?, 1);
        assert_eq!(guard.last_insert_rowid()?, 2);
        Ok(())
    })
    .unwrap();

    let mut count = db.prepare("select count(*) from tx").unwrap();
    assert_eq!(count.step().unwrap(), Step::Row);
    assert_eq!(count.column_i64(0).unwrap(), 2);
    let _ = std::fs::remove_file(path);
}

#[test]
fn shared_database_savepoints_work_directly_and_inside_guards() {
    let path = temp_path("savepoints");
    let db = SharedDatabase::create(&path).unwrap();
    db.exec("create table tx(id integer primary key, value text)")
        .unwrap();

    db.begin_immediate().unwrap();
    db.exec("insert into tx(value) values ('outer')").unwrap();
    db.savepoint("sp_direct").unwrap();
    db.exec("insert into tx(value) values ('rolled back')")
        .unwrap();
    db.rollback_to_savepoint("sp_direct").unwrap();
    db.release_savepoint("sp_direct").unwrap();
    db.commit().unwrap();

    let mut count = db.prepare("select count(*) from tx").unwrap();
    assert_eq!(count.step().unwrap(), Step::Row);
    assert_eq!(count.column_i64(0).unwrap(), 1);
    drop(count);

    db.transaction_immediate(|guard| {
        guard.savepoint("sp_guard")?;
        guard.exec("insert into tx(value) values ('discarded')")?;
        guard.rollback_to_savepoint("sp_guard")?;
        guard.release_savepoint("sp_guard")?;
        guard.savepoint("sp_kept")?;
        guard.exec("insert into tx(value) values ('kept')")?;
        guard.release_savepoint("sp_kept")?;
        Ok(())
    })
    .unwrap();

    let invalid = db.savepoint("_zova_private").unwrap_err();
    assert_eq!(invalid.status(), Some(zova::Status::InvalidArgument));
    let missing = db.rollback_to_savepoint("missing_sp").unwrap_err();
    assert!(missing.to_string().contains("no such savepoint"));

    let mut count = db
        .prepare("select count(*) from tx where value != 'discarded'")
        .unwrap();
    assert_eq!(count.step().unwrap(), Step::Row);
    assert_eq!(count.column_i64(0).unwrap(), 2);
    let _ = std::fs::remove_file(path);
}

#[test]
fn shared_scoped_savepoint_helpers_hold_guard_and_cleanup() {
    let path = temp_path("scoped-savepoints");
    let db = SharedDatabase::create(&path).unwrap();
    db.exec("create table tx(id integer primary key, value text)")
        .unwrap();

    let value = db
        .with_savepoint("sp_keep", |guard| {
            guard.exec("insert into tx(value) values ('kept shared')")?;
            Ok(7)
        })
        .unwrap();
    assert_eq!(value, 7);

    let err = db
        .with_savepoint("sp_fail", |guard| {
            guard.exec("insert into tx(value) values ('rolled back shared')")?;
            guard.exec("select * from missing_table")
        })
        .unwrap_err();
    assert_eq!(err.status(), Some(zova::Status::SqliteError));

    db.transaction_immediate(|guard| {
        guard.with_savepoint("sp_guard_keep", |guard| {
            guard.exec("insert into tx(value) values ('kept guard')")
        })?;
        let err = guard
            .with_savepoint("sp_guard_fail", |guard| {
                guard.exec("insert into tx(value) values ('rolled back guard')")?;
                guard.exec("select * from missing_table")
            })
            .unwrap_err();
        assert_eq!(err.status(), Some(zova::Status::SqliteError));
        Ok(())
    })
    .unwrap();

    let err = db
        .with_savepoint("bad name", |guard| {
            guard.exec("insert into tx(value) values ('not invoked')")
        })
        .unwrap_err();
    assert_eq!(err.status(), Some(zova::Status::InvalidArgument));

    let mut count = db
        .prepare("select count(*) from tx where value in ('kept shared', 'kept guard')")
        .unwrap();
    assert_eq!(count.step().unwrap(), Step::Row);
    assert_eq!(count.column_i64(0).unwrap(), 2);
    drop(count);

    let mut rolled_back = db
        .prepare(
            "select count(*) from tx where value like '%rolled back%' or value = 'not invoked'",
        )
        .unwrap();
    assert_eq!(rolled_back.step().unwrap(), Step::Row);
    assert_eq!(rolled_back.column_i64(0).unwrap(), 0);
    let _ = std::fs::remove_file(path);
}

#[test]
fn shared_transaction_rolls_back_when_commit_fails() {
    let path = temp_path("commit-failure");
    let db = SharedDatabase::create(&path).unwrap();
    db.exec("pragma foreign_keys = on").unwrap();
    db.exec("create table parent(id integer primary key)")
        .unwrap();
    db.exec(
        "create table child(
            parent_id integer references parent(id) deferrable initially deferred
        )",
    )
    .unwrap();

    let err = db
        .transaction(|guard| {
            guard.exec("insert into child(parent_id) values (99)")?;
            Ok(())
        })
        .unwrap_err();
    assert!(err.to_string().contains("FOREIGN KEY"));

    db.exec("insert into parent(id) values (99)").unwrap();
    let mut count = db.prepare("select count(*) from child").unwrap();
    assert_eq!(count.step().unwrap(), Step::Row);
    assert_eq!(count.column_i64(0).unwrap(), 0);
    let _ = std::fs::remove_file(path);
}

#[test]
fn shared_errors_copy_diagnostics_before_later_thread_calls() {
    let path = temp_path("diagnostics");
    let db = SharedDatabase::create(&path).unwrap();
    db.exec("create table ok(id integer primary key)").unwrap();

    let failing = db.clone();
    let err = thread::spawn(move || failing.exec("select * from no_such_table").unwrap_err())
        .join()
        .unwrap();

    let succeeding = db.clone();
    thread::spawn(move || succeeding.exec("insert into ok default values").unwrap())
        .join()
        .unwrap();

    assert!(err.to_string().contains("no_such_table"));
    let _ = std::fs::remove_file(path);
}

#[test]
fn child_handles_keep_native_database_alive_after_clones_drop() {
    let path = temp_path("child-lifetime");
    let db = SharedDatabase::create(&path).unwrap();
    db.exec("create table t(id integer primary key, body text)")
        .unwrap();
    db.exec("insert into t(body) values ('kept')").unwrap();

    let mut statement = db.prepare("select body from t").unwrap();
    let mut writer = db.object_writer().unwrap();
    drop(db);

    assert_eq!(statement.step().unwrap(), Step::Row);
    assert_eq!(statement.column_text(0).unwrap(), Some("kept".to_string()));
    drop(statement);

    writer.write(b"still alive").unwrap();
    assert_eq!(writer.finish().unwrap(), object_id(b"still alive").unwrap());
    let _ = std::fs::remove_file(path);
}

#[test]
fn shared_batch_vectors_and_candidate_search_match_database_api() {
    let path = temp_path("vector-parity");
    let db = SharedDatabase::create(&path).unwrap();
    db.create_vector_collection(
        "docs",
        VectorCollectionOptions {
            dimensions: 2,
            metric: VectorMetric::Dot,
        },
    )
    .unwrap();
    db.put_vectors(
        "docs",
        &[
            VectorInput {
                id: "a",
                values: &[1.0, 0.0],
            },
            VectorInput {
                id: "b",
                values: &[0.0, 1.0],
            },
            VectorInput {
                id: "c",
                values: &[2.0, 0.0],
            },
        ],
    )
    .unwrap();

    let results = db
        .search_vectors_by_id_in_within("docs", "a", &["a", "b", "c", "missing"], -1.0, 10)
        .unwrap();
    assert_eq!(
        results
            .iter()
            .map(|item| item.id.as_str())
            .collect::<Vec<_>>(),
        ["c"]
    );
    let _ = std::fs::remove_file(path);
}
