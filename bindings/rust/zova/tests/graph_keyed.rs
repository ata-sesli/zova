use zova::{
    abi_version, abi_version_string, Database, GraphEdgeInput, GraphEdgePayloadReplacement,
    GraphFreshEdgeInput, GraphFreshEdgePayloadInput, GraphFreshNodeInput, GraphKeyedDegreeOptions,
    GraphNeighborDirection, GraphNeighborsOptions, GraphNodeInput, GraphScanCursor,
    GraphScanOptions, GraphTargetType, GraphWalkDirectionOptions, SharedDatabase, Status,
    VectorCollectionOptions, VectorElementType, VectorInput, VectorMetric,
    VectorMultiI8Aggregation, VectorMultiI8SearchMode, VectorMultiI8SearchOptions, VectorValues,
};

fn node<'a>(graph_name: &'a str, node_id: &'a str, kind: &'a str) -> GraphNodeInput<'a> {
    GraphNodeInput {
        graph_name,
        node_id,
        kind,
        target_type: GraphTargetType::None,
        target_namespace: None,
        target_ref: None,
    }
}

fn edge<'a>(
    graph_name: &'a str,
    from: &'a str,
    edge_type: &'a str,
    to: &'a str,
) -> GraphEdgeInput<'a> {
    GraphEdgeInput {
        graph_name,
        from_node_id: from,
        edge_type,
        to_node_id: to,
    }
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
fn abi_version_matches_the_version_string() {
    let version = abi_version();
    assert_eq!(
        abi_version_string(),
        format!("{}.{}.{}", version.major, version.minor, version.patch)
    );
}

#[test]
fn keyed_graph_crud_payloads_degrees_and_scan() {
    let mut db = Database::create_memory().unwrap();
    db.create_graph("g").unwrap();
    let node_keys = db
        .put_graph_nodes_keyed(&[
            node("g", "a", "file"),
            node("g", "b", "file"),
            node("g", "c", "dir"),
        ])
        .unwrap();
    assert_eq!(node_keys.len(), 3);
    assert!(node_keys.iter().all(|key| *key > 0));
    let edge_keys = db
        .put_graph_edges_keyed(&[
            edge("g", "a", "calls", "b"),
            edge("g", "a", "contains", "c"),
        ])
        .unwrap();
    assert_eq!(edge_keys.len(), 2);
    assert!(db.put_graph_nodes_keyed(&[]).unwrap().is_empty());

    let nodes = db
        .get_graph_nodes_keyed("g", &[node_keys[1], i64::MAX])
        .unwrap();
    let b = nodes[0].as_ref().unwrap();
    assert_eq!(
        (b.node_key, b.node_id.as_str(), b.kind.as_str()),
        (node_keys[1], "b", "file")
    );
    assert!(nodes[1].is_none());

    let edges = db.get_graph_edges_keyed("g", &[edge_keys[0]]).unwrap();
    let calls = edges[0].as_ref().unwrap();
    assert_eq!(calls.source_node_key, node_keys[0]);
    assert_eq!(calls.target_node_key, node_keys[1]);
    assert_eq!(calls.edge_type, "calls");

    let neighbors = db
        .graph_neighbors_keyed(GraphNeighborsOptions {
            graph_name: "g",
            node_id: "a",
            direction: GraphNeighborDirection::Outgoing,
            edge_type: None,
            limit: 10,
        })
        .unwrap();
    assert_eq!(
        neighbors
            .iter()
            .map(|item| (item.edge_key, item.neighbor_node_key, item.node_id.as_str()))
            .collect::<Vec<_>>(),
        [
            (edge_keys[0], node_keys[1], "b"),
            (edge_keys[1], node_keys[2], "c")
        ]
    );

    let degrees = db
        .graph_degrees_keyed(GraphKeyedDegreeOptions {
            graph_name: "g",
            node_keys: &node_keys,
            direction: GraphNeighborDirection::Outgoing,
            edge_type: None,
        })
        .unwrap();
    assert_eq!(degrees, [2, 0, 0]);

    db.replace_graph_edge_payloads(
        "g",
        &[GraphEdgePayloadReplacement {
            edge_key: edge_keys[0],
            payload: b"weight=3",
        }],
    )
    .unwrap();
    let payloads = db
        .get_graph_edge_payloads("g", &[edge_keys[0], edge_keys[1], i64::MAX])
        .unwrap();
    assert_eq!(payloads[0].as_deref(), Some(&b"weight=3"[..]));
    assert_eq!(payloads[1].as_deref(), Some(&b""[..]));
    assert!(payloads[2].is_none());

    let mut options = GraphScanOptions {
        graph_name: "g",
        node_after: GraphScanCursor::default(),
        edge_after: GraphScanCursor::default(),
        node_limit: 2,
        edge_limit: 1,
    };
    let first = db.graph_scan(options).unwrap();
    assert_eq!(first.nodes.len(), 2);
    assert_eq!(first.edges.len(), 1);
    assert!(first.has_more_nodes && first.has_more_edges);
    let last_node = first.nodes.last().unwrap();
    let last_edge = first.edges.last().unwrap();
    options.node_after = GraphScanCursor {
        created_order: last_node.created_order,
        key: last_node.node_key,
    };
    options.edge_after = GraphScanCursor {
        created_order: last_edge.created_order,
        key: last_edge.edge_key,
    };
    let second = db.graph_scan(options).unwrap();
    assert_eq!(second.nodes[0].node_id, "c");
    assert_eq!(second.edges[0].edge_key, edge_keys[1]);
    assert!(!second.has_more_nodes && !second.has_more_edges);
}

#[test]
fn directional_walks_follow_the_requested_direction() {
    let mut db = Database::create_memory().unwrap();
    db.create_graph("g").unwrap();
    db.put_graph_nodes(&[
        node("g", "a", "file"),
        node("g", "b", "file"),
        node("g", "c", "file"),
    ])
    .unwrap();
    db.put_graph_edges(&[edge("g", "a", "calls", "b"), edge("g", "b", "calls", "c")])
        .unwrap();
    let options = GraphWalkDirectionOptions {
        graph_name: "g",
        start_node_id: "c",
        direction: GraphNeighborDirection::Incoming,
        edge_type: Some("calls"),
        max_depth: 5,
        limit: 10,
    };
    let walk = db.graph_walk_direction(options).unwrap();
    assert_eq!(
        walk.iter()
            .map(|item| (item.node_id.as_str(), item.depth))
            .collect::<Vec<_>>(),
        [("c", 0), ("b", 1), ("a", 2)]
    );
    let (profiled, profile) = db.graph_walk_direction_profiled(options).unwrap();
    assert_eq!(profiled, walk);
    assert_eq!(profile.result_count, 3);

    let outgoing = db
        .graph_walk_direction(GraphWalkDirectionOptions {
            direction: GraphNeighborDirection::Outgoing,
            ..options
        })
        .unwrap();
    assert_eq!(outgoing.len(), 1);
}

#[test]
fn fresh_graph_builds_publish_input_aligned_keys() {
    let mut db = Database::create_memory().unwrap();
    let nodes = [fresh_node("a"), fresh_node("b"), fresh_node("c")];
    let keys = db
        .build_fresh_graph_keyed(
            "g",
            &nodes,
            &[
                GraphFreshEdgeInput {
                    from_node_ordinal: 0,
                    edge_type: "calls",
                    to_node_ordinal: 1,
                },
                GraphFreshEdgeInput {
                    from_node_ordinal: 1,
                    edge_type: "calls",
                    to_node_ordinal: 2,
                },
            ],
        )
        .unwrap();
    assert_eq!(keys.node_keys.len(), 3);
    assert_eq!(keys.edge_keys.len(), 2);
    let found = db.get_graph_nodes_keyed("g", &keys.node_keys).unwrap();
    assert_eq!(found[2].as_ref().unwrap().node_id, "c");

    let mut db = Database::create_memory().unwrap();
    let keys = db
        .build_fresh_graph_prepared_keyed_with_payloads(
            "p",
            &nodes[..2],
            &[GraphFreshEdgePayloadInput {
                from_node_ordinal: 0,
                edge_type: "calls",
                to_node_ordinal: 1,
                payload: b"line=4",
            }],
        )
        .unwrap();
    let payloads = db.get_graph_edge_payloads("p", &keys.edge_keys).unwrap();
    assert_eq!(payloads[0].as_deref(), Some(&b"line=4"[..]));

    let mut db = Database::create_memory().unwrap();
    let error = db
        .build_fresh_graph_prepared_keyed(
            "q",
            &nodes[..1],
            &[GraphFreshEdgeInput {
                from_node_ordinal: 0,
                edge_type: "calls",
                to_node_ordinal: 9,
            }],
        )
        .unwrap_err();
    assert_eq!(error.status(), Some(Status::InvalidArgument));
}

#[test]
fn shared_database_exposes_keyed_graph_and_multi_i8_search() {
    let db = SharedDatabase::create_memory().unwrap();
    db.create_graph("g").unwrap();
    let node_keys = db
        .put_graph_nodes_keyed(&[node("g", "a", "file"), node("g", "b", "file")])
        .unwrap();
    let edge_keys = db
        .put_graph_edges_keyed(&[edge("g", "a", "calls", "b")])
        .unwrap();
    let degrees = db
        .with_exclusive(|guard| {
            guard.graph_degrees_keyed(GraphKeyedDegreeOptions {
                graph_name: "g",
                node_keys: &node_keys,
                direction: GraphNeighborDirection::Incoming,
                edge_type: None,
            })
        })
        .unwrap();
    assert_eq!(degrees, [0, 1]);
    assert!(db.get_graph_edges_keyed("g", &edge_keys).unwrap()[0].is_some());

    db.create_vector_collection(
        "codes",
        VectorCollectionOptions {
            dimensions: 2,
            metric: VectorMetric::Cosine,
            element_type: VectorElementType::I8,
        },
    )
    .unwrap();
    db.put_vectors(
        "codes",
        &[
            VectorInput {
                id: "x",
                values: VectorValues::I8(&[1, 0]),
            },
            VectorInput {
                id: "y",
                values: VectorValues::I8(&[0, 1]),
            },
            VectorInput {
                id: "xy",
                values: VectorValues::I8(&[1, 1]),
            },
        ],
    )
    .unwrap();
    let options = VectorMultiI8SearchOptions {
        collection_name: "codes",
        query_values: &[1, 0, 0, 1],
        query_count: 2,
        dimensions: 2,
        candidate_ids: &[],
        mode: VectorMultiI8SearchMode::GlobalMinCosine,
        aggregation: VectorMultiI8Aggregation::MinCosine,
        prefilter_query_index: 0,
        prefilter_limit: 0,
        limit: 3,
    };
    let results = db.search_vectors_multi_i8(options).unwrap();
    // Min-cosine aggregation scores each vector by its least similar query row.
    assert_eq!(
        results
            .iter()
            .map(|item| item.id.as_str())
            .collect::<Vec<_>>(),
        ["xy", "x", "y"]
    );
    assert!((results[0].distance - (1.0 - 0.5f64.sqrt())).abs() < 1e-9);
    assert!((results[1].distance - 1.0).abs() < 1e-9);

    let results = db
        .search_vectors_multi_i8(VectorMultiI8SearchOptions {
            candidate_ids: &["xy", "y"],
            mode: VectorMultiI8SearchMode::CbmPrefilterMinCosine,
            prefilter_query_index: 1,
            prefilter_limit: 1,
            ..options
        })
        .unwrap();
    assert_eq!(
        results
            .iter()
            .map(|item| item.id.as_str())
            .collect::<Vec<_>>(),
        ["y"]
    );

    let error = db
        .search_vectors_multi_i8(VectorMultiI8SearchOptions {
            query_count: 3,
            ..options
        })
        .unwrap_err();
    assert_eq!(error.status(), Some(Status::InvalidArgument));
}
