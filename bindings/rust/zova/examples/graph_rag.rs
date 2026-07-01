use zova::{
    Database, GraphEdgeInput, GraphNeighborsOptions, GraphNodeInput, GraphTargetType, Step,
    VectorCollectionOptions, VectorMetric, DEFAULT_GRAPH_NAME,
};

fn hex(bytes: [u8; 32]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn main() -> zova::Result<()> {
    let path = std::env::temp_dir().join(format!(
        "zova-rust-graph-rag-example-{}.zova",
        std::process::id()
    ));
    let _ = std::fs::remove_file(&path);

    let mut db = Database::create(&path)?;
    db.exec("create table chunks(id text primary key, body text not null)")?;
    db.exec("insert into chunks(id, body) values ('chunk:1', 'Zova stores records, objects, and vectors together')")?;
    db.create_graph(DEFAULT_GRAPH_NAME)?;

    db.create_vector_collection(
        "chunks",
        VectorCollectionOptions {
            dimensions: 2,
            metric: VectorMetric::L2,
        },
    )?;
    db.put_vector("chunks", "chunk:1", &[0.0, 1.0])?;

    let object_id = db.put_object(b"attachment bytes")?;
    let object_hex = hex(object_id.into_bytes());

    db.put_graph_node(GraphNodeInput {
        graph_name: DEFAULT_GRAPH_NAME,
        node_id: "chunk:1",
        kind: "chunk",
        target_type: GraphTargetType::Vector,
        target_namespace: Some("chunks"),
        target_ref: Some("chunk:1"),
    })?;
    db.put_graph_node(GraphNodeInput {
        graph_name: DEFAULT_GRAPH_NAME,
        node_id: "attachment:1",
        kind: "attachment",
        target_type: GraphTargetType::Object,
        target_namespace: Some("sha256"),
        target_ref: Some(&object_hex),
    })?;
    db.put_graph_node(GraphNodeInput {
        graph_name: DEFAULT_GRAPH_NAME,
        node_id: "entity:zova",
        kind: "entity",
        target_type: GraphTargetType::Entity,
        target_namespace: None,
        target_ref: Some("zova"),
    })?;
    db.put_graph_edge(GraphEdgeInput {
        graph_name: DEFAULT_GRAPH_NAME,
        from_node_id: "chunk:1",
        edge_type: "mentions",
        to_node_id: "entity:zova",
    })?;
    db.put_graph_edge(GraphEdgeInput {
        graph_name: DEFAULT_GRAPH_NAME,
        from_node_id: "chunk:1",
        edge_type: "has_attachment",
        to_node_id: "attachment:1",
    })?;

    let nearest = db.search_vectors("chunks", &[0.0, 1.0], 1)?;
    for hit in nearest {
        let neighbors = db.graph_neighbors(GraphNeighborsOptions {
            graph_name: DEFAULT_GRAPH_NAME,
            node_id: &hit.id,
            direction: zova::GraphNeighborDirection::Outgoing,
            edge_type: None,
            limit: 10,
        })?;
        for neighbor in neighbors {
            if neighbor.node_id == "attachment:1" {
                println!("attachment bytes: {}", db.get_object(object_id)?.len());
            } else {
                let mut stmt = db.prepare("select body from chunks where id = ?1")?;
                stmt.bind_text(1, &hit.id)?;
                if stmt.step()? == Step::Row {
                    println!(
                        "{}: {}",
                        neighbor.node_id,
                        stmt.column_text(0)?.unwrap_or_default()
                    );
                }
            }
        }
    }

    let _ = std::fs::remove_file(path);
    Ok(())
}
