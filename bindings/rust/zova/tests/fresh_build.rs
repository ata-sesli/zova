use zova::{
    Database, FreshValue, GraphFreshEdgePayloadInput, GraphFreshNodeInput, GraphTargetType,
    SharedDatabase, Status, Step, VectorCollectionOptions, VectorElementType, VectorInput,
    VectorMetric, VectorValues,
};

const SCHEMA: &str = "create table files(id integer primary key, path text not null);
create index files_path on files(path);
create virtual table bodies using fts5(body);";

fn count(db: &mut Database, sql: &str) -> i64 {
    let mut statement = db.prepare(sql).unwrap();
    assert_eq!(statement.step().unwrap(), Step::Row);
    statement.column_i64(0).unwrap()
}

fn fresh_node(node_id: &str) -> GraphFreshNodeInput<'_> {
    GraphFreshNodeInput {
        node_id,
        kind: "file",
        target_type: GraphTargetType::None,
        target_namespace: None,
        target_ref: None,
    }
}

#[test]
fn fresh_build_commits_tables_fts_graph_and_vectors_together() {
    let mut db = Database::create_memory().unwrap();
    db.exec(SCHEMA).unwrap();
    db.create_vector_collection(
        "embeddings",
        VectorCollectionOptions {
            dimensions: 2,
            metric: VectorMetric::L2,
            element_type: VectorElementType::F32,
        },
    )
    .unwrap();

    let mut build = db.begin_fresh_build().unwrap();
    build
        .table_rows(
            "files",
            &["id", "path"],
            &[
                FreshValue::Int64(1),
                FreshValue::Text("a.rs"),
                FreshValue::Int64(2),
                FreshValue::Text("b.rs"),
            ],
        )
        .unwrap();
    build
        .fts_rows("bodies", &["body"], &[FreshValue::Text("fn main")])
        .unwrap();
    build
        .graph(
            "code",
            &[fresh_node("a.rs"), fresh_node("b.rs")],
            &[GraphFreshEdgePayloadInput {
                from_node_ordinal: 0,
                edge_type: "imports",
                to_node_ordinal: 1,
                payload: b"line=1",
            }],
        )
        .unwrap();
    build
        .vectors(
            "embeddings",
            &[VectorInput {
                id: "a.rs",
                values: VectorValues::F32(&[1.0, 0.0]),
            }],
        )
        .unwrap();
    let result = build.finish().unwrap();

    assert_eq!(result.node_keys.len(), 2);
    assert_eq!(result.edge_keys.len(), 1);
    assert_eq!(result.profile.table_rows, 2);
    assert_eq!(result.profile.fts_rows, 1);
    assert_eq!(result.profile.vector_rows, 1);
    assert_eq!(count(&mut db, "select count(*) from files"), 2);
    assert_eq!(
        count(
            &mut db,
            "select count(*) from bodies where bodies match 'main'"
        ),
        1
    );
    assert_eq!(
        count(
            &mut db,
            "select count(*) from sqlite_schema where type='index' and name='files_path'"
        ),
        1
    );
    let payloads = db
        .get_graph_edge_payloads("code", &result.edge_keys)
        .unwrap();
    assert_eq!(payloads[0].as_deref(), Some(&b"line=1"[..]));
    assert_eq!(db.get_vector("embeddings", "a.rs").unwrap().id, "a.rs");
}

#[test]
fn failed_or_dropped_fresh_builds_roll_back() {
    let mut db = Database::create_memory().unwrap();
    db.exec(SCHEMA).unwrap();

    let mut build = db.begin_fresh_build().unwrap();
    build
        .table_rows(
            "files",
            &["id", "path"],
            &[FreshValue::Int64(1), FreshValue::Text("a.rs")],
        )
        .unwrap();
    drop(build);
    assert_eq!(count(&mut db, "select count(*) from files"), 0);

    let mut build = db.begin_fresh_build().unwrap();
    build
        .table_rows(
            "files",
            &["id", "path"],
            &[FreshValue::Int64(1), FreshValue::Text("a.rs")],
        )
        .unwrap();
    let error = build
        .table_rows("missing", &["id"], &[FreshValue::Int64(1)])
        .unwrap_err();
    assert_ne!(error.status(), Some(Status::Misuse));
    let error = build
        .table_rows("files", &["id"], &[FreshValue::Int64(2)])
        .unwrap_err();
    assert_eq!(error.status(), Some(Status::Misuse));
    assert_eq!(build.finish().unwrap_err().status(), Some(Status::Misuse));
    assert_eq!(count(&mut db, "select count(*) from files"), 0);

    let mut build = db.begin_fresh_build().unwrap();
    let error = build
        .table_rows("files", &["id", "path"], &[FreshValue::Int64(1)])
        .unwrap_err();
    assert_eq!(error.status(), Some(Status::InvalidArgument));
    drop(build);

    let build = db.begin_fresh_build().unwrap();
    build.abort().unwrap();
    db.exec("insert into files(id, path) values (9, 'ok')")
        .unwrap();
    assert_eq!(count(&mut db, "select count(*) from files"), 1);
    db.create_graph("existing").unwrap();
    assert_eq!(
        db.begin_fresh_build().map(|_| ()).unwrap_err().status(),
        Some(Status::InvalidArgument),
        "a fresh build requires an empty graph store"
    );
}

#[test]
fn shared_fresh_build_blocks_other_calls_until_finished() {
    let db = SharedDatabase::create_memory().unwrap();
    db.exec(SCHEMA).unwrap();
    let mut build = db.begin_fresh_build().unwrap();
    assert_eq!(
        db.exec("select 1").unwrap_err().status(),
        Some(Status::InvalidArgument)
    );
    build
        .table_rows(
            "files",
            &["id", "path"],
            &[FreshValue::Int64(1), FreshValue::Text("a.rs")],
        )
        .unwrap();
    build.finish().unwrap();
    let mut statement = db.prepare("select count(*) from files").unwrap();
    assert_eq!(statement.step().unwrap(), Step::Row);
    assert_eq!(statement.column_i64(0).unwrap(), 1);
}

#[test]
fn owned_fresh_build_outlives_its_database_borrow() {
    let mut db = Database::create_memory().unwrap();
    db.exec(SCHEMA).unwrap();
    let mut build = db.begin_fresh_build_owned().unwrap();
    // The owned session does not borrow `db`, but the handle stays blocked.
    assert_eq!(
        db.exec("select 1").unwrap_err().status(),
        Some(Status::InvalidArgument)
    );
    build
        .table_rows(
            "files",
            &["id", "path"],
            &[FreshValue::Int64(1), FreshValue::Text("a.rs")],
        )
        .unwrap();
    let result = build.finish().unwrap();
    assert_eq!(result.profile.table_rows, 1);
    assert_eq!(build.abort().unwrap_err().status(), Some(Status::Misuse));
    assert_eq!(count(&mut db, "select count(*) from files"), 1);

    let mut aborted = db.begin_fresh_build_owned().unwrap();
    aborted.abort().unwrap();
    let dropped = db.begin_fresh_build_owned().unwrap();
    drop(db);
    // The session keeps the native handle alive and rolls back on drop.
    drop(dropped);
}
