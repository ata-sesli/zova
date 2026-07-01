use zova::{
    Database, GraphEdgeInput, GraphNeighborDirection, GraphNeighborsOptions, GraphNodeInput,
    GraphTargetType, GraphWalkOptions, OpenOptions, Status, Step, VectorCollectionOptions,
    VectorMetric, DEFAULT_GRAPH_NAME,
};

fn temp_path(name: &str) -> String {
    let mut path = std::env::temp_dir();
    path.push(format!(
        "zova-rust-graphs-{}-{}-{name}.zova",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let _ = std::fs::remove_file(&path);
    path.to_str().unwrap().to_owned()
}

fn hex(bytes: [u8; 32]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn node<'a>(
    graph_name: &'a str,
    node_id: &'a str,
    kind: &'a str,
    target_type: GraphTargetType,
    target_namespace: Option<&'a str>,
    target_ref: Option<&'a str>,
) -> GraphNodeInput<'a> {
    GraphNodeInput {
        graph_name,
        node_id,
        kind,
        target_type,
        target_namespace,
        target_ref,
    }
}

fn edge<'a>(
    graph_name: &'a str,
    from_node_id: &'a str,
    edge_type: &'a str,
    to_node_id: &'a str,
) -> GraphEdgeInput<'a> {
    GraphEdgeInput {
        graph_name,
        from_node_id,
        edge_type,
        to_node_id,
    }
}

#[test]
fn graph_lifecycle_node_edge_traversal_and_delete() {
    let path = temp_path("lifecycle");
    let mut db = Database::create(&path).unwrap();
    db.exec("create table messages(id text primary key, body text)")
        .unwrap();
    db.exec("insert into messages(id, body) values ('m1', 'hello')")
        .unwrap();

    assert!(!db.has_graph("app").unwrap());
    db.create_graph("app").unwrap();
    db.create_graph("knowledge").unwrap();
    assert_eq!(
        db.create_graph("app").unwrap_err().status(),
        Some(Status::GraphExists)
    );

    let graphs = db.list_graphs().unwrap();
    assert_eq!(
        graphs
            .iter()
            .map(|graph| graph.name.as_str())
            .collect::<Vec<_>>(),
        ["app", "knowledge"]
    );

    db.put_graph_node(node(
        "app",
        "message:m1",
        "message",
        GraphTargetType::Record,
        Some("messages"),
        Some("m1"),
    ))
    .unwrap();
    db.put_graph_node(node(
        "app",
        "message:m2",
        "message",
        GraphTargetType::None,
        None,
        None,
    ))
    .unwrap();
    db.put_graph_node(node(
        "app",
        "attachment:a1",
        "attachment",
        GraphTargetType::External,
        None,
        Some("file://attachment-a1"),
    ))
    .unwrap();

    let message = db.get_graph_node("app", "message:m1").unwrap();
    assert_eq!(message.kind, "message");
    assert_eq!(message.target_type, GraphTargetType::Record);
    assert_eq!(message.target_namespace.as_deref(), Some("messages"));
    assert_eq!(message.target_ref.as_deref(), Some("m1"));
    assert!(db.has_graph_node("app", "message:m2").unwrap());

    db.put_graph_edge(edge("app", "message:m1", "replies_to", "message:m2"))
        .unwrap();
    db.put_graph_edge(edge("app", "message:m1", "has_attachment", "attachment:a1"))
        .unwrap();
    db.put_graph_edge(edge("app", "message:m1", "has_attachment", "attachment:a1"))
        .unwrap();
    assert_eq!(
        db.put_graph_edge(edge("app", "message:m1", "missing", "missing-node"))
            .unwrap_err()
            .status(),
        Some(Status::GraphNodeNotFound)
    );

    let edge_row = db
        .get_graph_edge("app", "message:m1", "has_attachment", "attachment:a1")
        .unwrap();
    assert_eq!(edge_row.edge_type, "has_attachment");
    assert!(db
        .has_graph_edge("app", "message:m1", "has_attachment", "attachment:a1")
        .unwrap());

    let outgoing = db
        .graph_neighbors(GraphNeighborsOptions {
            graph_name: "app",
            node_id: "message:m1",
            direction: GraphNeighborDirection::Outgoing,
            edge_type: None,
            limit: 10,
        })
        .unwrap();
    assert_eq!(
        outgoing
            .iter()
            .map(|item| (item.node_id.as_str(), item.edge_type.as_str()))
            .collect::<Vec<_>>(),
        [
            ("message:m2", "replies_to"),
            ("attachment:a1", "has_attachment")
        ]
    );

    let incoming = db
        .graph_neighbors(GraphNeighborsOptions {
            graph_name: "app",
            node_id: "message:m2",
            direction: GraphNeighborDirection::Incoming,
            edge_type: Some("replies_to"),
            limit: 10,
        })
        .unwrap();
    assert_eq!(incoming[0].node_id, "message:m1");

    let limited = db
        .graph_neighbors(GraphNeighborsOptions {
            graph_name: "app",
            node_id: "message:m1",
            direction: GraphNeighborDirection::Outgoing,
            edge_type: None,
            limit: 1,
        })
        .unwrap();
    assert_eq!(limited.len(), 1);

    let walk = db
        .graph_walk(GraphWalkOptions {
            graph_name: "app",
            start_node_id: "message:m1",
            edge_type: None,
            max_depth: 2,
            limit: 10,
        })
        .unwrap();
    assert_eq!(
        walk.iter()
            .map(|item| (item.node_id.as_str(), item.depth))
            .collect::<Vec<_>>(),
        [("message:m1", 0), ("message:m2", 1), ("attachment:a1", 1)]
    );

    db.delete_graph_node("app", "attachment:a1").unwrap();
    assert_eq!(
        db.get_graph_edge("app", "message:m1", "has_attachment", "attachment:a1")
            .unwrap_err()
            .status(),
        Some(Status::GraphEdgeNotFound)
    );

    let info = db.graph_info("app").unwrap();
    assert_eq!(info.node_count, 2);
    assert_eq!(info.edge_count, 1);
    db.delete_graph("knowledge").unwrap();
    assert!(!db.has_graph("knowledge").unwrap());

    let _ = std::fs::remove_file(path);
}

#[test]
fn graph_targets_cover_records_objects_chunks_vectors_and_concepts() {
    let path = temp_path("targets");
    let mut db = Database::create(&path).unwrap();
    db.create_graph("app").unwrap();

    let object_bytes = b"graph object target";
    let object_id = db.put_object(object_bytes).unwrap();
    let object_hex = hex(object_id.into_bytes());
    let manifest = db.object_manifest(object_id).unwrap();
    let chunk_hex = hex(manifest.chunks[0].hash.into_bytes());

    db.create_vector_collection(
        "chunks",
        VectorCollectionOptions {
            dimensions: 2,
            metric: VectorMetric::L2,
        },
    )
    .unwrap();
    db.put_vector("chunks", "chunk-vector", &[1.0, 0.0])
        .unwrap();

    let targets = [
        (
            "record:1",
            GraphTargetType::Record,
            Some("messages"),
            Some("1"),
        ),
        (
            "object:1",
            GraphTargetType::Object,
            Some("sha256"),
            Some(object_hex.as_str()),
        ),
        (
            "chunk:1",
            GraphTargetType::ObjectChunk,
            Some("sha256"),
            Some(chunk_hex.as_str()),
        ),
        (
            "vector:1",
            GraphTargetType::Vector,
            Some("chunks"),
            Some("chunk-vector"),
        ),
        (
            "entity:1",
            GraphTargetType::Entity,
            None,
            Some("person:ata"),
        ),
        ("fact:1", GraphTargetType::Fact, None, Some("fact:alpha")),
        ("concept:1", GraphTargetType::Concept, None, Some("storage")),
        (
            "external:1",
            GraphTargetType::External,
            None,
            Some("https://example.test"),
        ),
    ];

    for (node_id, target_type, target_namespace, target_ref) in targets {
        db.put_graph_node(node(
            "app",
            node_id,
            "target",
            target_type,
            target_namespace,
            target_ref,
        ))
        .unwrap();
        let stored = db.get_graph_node("app", node_id).unwrap();
        assert_eq!(stored.target_type, target_type);
        assert_eq!(stored.target_namespace.as_deref(), target_namespace);
        assert_eq!(stored.target_ref.as_deref(), target_ref);
    }

    let _ = std::fs::remove_file(path);
}

#[test]
fn graph_transactions_savepoints_readonly_and_validation() {
    let path = temp_path("tx");
    let mut db = Database::create(&path).unwrap();
    db.create_graph(DEFAULT_GRAPH_NAME).unwrap();
    assert_eq!(
        db.create_graph(DEFAULT_GRAPH_NAME).unwrap_err().status(),
        Some(Status::GraphExists)
    );
    assert_eq!(
        db.create_graph("_zova_private").unwrap_err().status(),
        Some(Status::GraphInvalid)
    );

    db.begin_immediate().unwrap();
    db.put_graph_node(node(
        DEFAULT_GRAPH_NAME,
        "rolled-back",
        "message",
        GraphTargetType::None,
        None,
        None,
    ))
    .unwrap();
    db.rollback().unwrap();
    assert!(!db
        .has_graph_node(DEFAULT_GRAPH_NAME, "rolled-back")
        .unwrap());

    db.begin_immediate().unwrap();
    db.savepoint("sp_graph").unwrap();
    db.put_graph_node(node(
        DEFAULT_GRAPH_NAME,
        "savepoint-rolled-back",
        "message",
        GraphTargetType::None,
        None,
        None,
    ))
    .unwrap();
    db.rollback_to_savepoint("sp_graph").unwrap();
    db.release_savepoint("sp_graph").unwrap();
    db.commit().unwrap();
    assert!(!db
        .has_graph_node(DEFAULT_GRAPH_NAME, "savepoint-rolled-back")
        .unwrap());

    db.put_graph_node(node(
        DEFAULT_GRAPH_NAME,
        "kept",
        "message",
        GraphTargetType::None,
        None,
        None,
    ))
    .unwrap();
    drop(db);

    let mut readonly = Database::open_with_options(
        &path,
        OpenOptions {
            read_only: true,
            busy_timeout_ms: 0,
        },
    )
    .unwrap();
    assert!(readonly.has_graph_node(DEFAULT_GRAPH_NAME, "kept").unwrap());
    assert_eq!(
        readonly
            .put_graph_node(node(
                DEFAULT_GRAPH_NAME,
                "readonly-write",
                "message",
                GraphTargetType::None,
                None,
                None,
            ))
            .unwrap_err()
            .status(),
        Some(Status::ReadOnly)
    );

    let _ = std::fs::remove_file(path);
}

#[test]
fn sql_native_graph_helpers_join_app_rows() {
    let path = temp_path("sql-native");
    let mut db = Database::create(&path).unwrap();
    db.exec(
        "create table messages(graph_node_id text primary key, body text);
         insert into messages(graph_node_id, body) values
           ('message:1', 'root'),
           ('message:2', 'reply'),
           ('message:3', 'mentioned');",
    )
    .unwrap();
    db.create_graph(DEFAULT_GRAPH_NAME).unwrap();
    for node_id in ["message:1", "message:2", "message:3"] {
        db.put_graph_node(node(
            DEFAULT_GRAPH_NAME,
            node_id,
            "message",
            GraphTargetType::Record,
            Some("messages"),
            Some(node_id),
        ))
        .unwrap();
    }
    db.put_graph_edge(edge(
        DEFAULT_GRAPH_NAME,
        "message:1",
        "replies_to",
        "message:2",
    ))
    .unwrap();
    db.put_graph_edge(edge(
        DEFAULT_GRAPH_NAME,
        "message:2",
        "mentions",
        "message:3",
    ))
    .unwrap();

    let mut neighbors = db
        .prepare(
            "select m.body, g.edge_type
             from zova_graph_neighbors as g
             join messages as m on m.graph_node_id = g.node_id
             where g.graph_name = 'default'
               and g.source_node_id = 'message:1'
               and g.\"limit\" = 10
             order by g.rank",
        )
        .unwrap();
    assert_eq!(neighbors.step().unwrap(), Step::Row);
    assert_eq!(neighbors.column_text(0).unwrap(), Some("reply".to_string()));
    assert_eq!(
        neighbors.column_text(1).unwrap(),
        Some("replies_to".to_string())
    );
    assert_eq!(neighbors.step().unwrap(), Step::Done);
    drop(neighbors);

    let mut walk = db
        .prepare(
            "select node_id, depth, predecessor_node_id, edge_type
             from zova_graph_walk
             where graph_name = 'default'
               and start_node_id = 'message:1'
               and max_depth = 2
               and \"limit\" = 10
             order by rank",
        )
        .unwrap();
    assert_eq!(walk.step().unwrap(), Step::Row);
    assert_eq!(walk.column_text(0).unwrap(), Some("message:1".to_string()));
    assert_eq!(walk.column_i64(1).unwrap(), 0);
    assert_eq!(walk.column_text(2).unwrap(), None);
    assert_eq!(walk.step().unwrap(), Step::Row);
    assert_eq!(walk.column_text(0).unwrap(), Some("message:2".to_string()));
    assert_eq!(walk.column_i64(1).unwrap(), 1);
    assert_eq!(walk.column_text(2).unwrap(), Some("message:1".to_string()));
    assert_eq!(walk.column_text(3).unwrap(), Some("replies_to".to_string()));
    assert_eq!(walk.step().unwrap(), Step::Row);
    assert_eq!(walk.column_text(0).unwrap(), Some("message:3".to_string()));

    let _ = std::fs::remove_file(path);
}
