use zova::{
    Database, GraphEdgeInput, GraphNeighborDirection, GraphNeighborsOptions, GraphNodeInput,
    GraphTargetType, Step, DEFAULT_GRAPH_NAME,
};

fn main() -> zova::Result<()> {
    let path = std::env::temp_dir().join(format!(
        "zova-rust-graphs-example-{}.zova",
        std::process::id()
    ));
    let _ = std::fs::remove_file(&path);

    let mut db = Database::create(&path)?;
    db.exec("create table messages(id text primary key, body text not null)")?;
    db.exec("insert into messages(id, body) values ('m1', 'hello'), ('m2', 'reply')")?;
    db.create_graph(DEFAULT_GRAPH_NAME)?;

    for id in ["m1", "m2"] {
        db.put_graph_node(GraphNodeInput {
            graph_name: DEFAULT_GRAPH_NAME,
            node_id: id,
            kind: "message",
            target_type: GraphTargetType::Record,
            target_namespace: Some("messages"),
            target_ref: Some(id),
        })?;
    }
    db.put_graph_edge(GraphEdgeInput {
        graph_name: DEFAULT_GRAPH_NAME,
        from_node_id: "m2",
        edge_type: "replies_to",
        to_node_id: "m1",
    })?;

    let neighbors = db.graph_neighbors(GraphNeighborsOptions {
        graph_name: DEFAULT_GRAPH_NAME,
        node_id: "m2",
        direction: GraphNeighborDirection::Outgoing,
        edge_type: Some("replies_to"),
        limit: 10,
    })?;

    for neighbor in neighbors {
        let mut stmt = db.prepare("select body from messages where id = ?1")?;
        stmt.bind_text(1, &neighbor.node_id)?;
        if stmt.step()? == Step::Row {
            println!(
                "{} -> {}",
                neighbor.edge_type,
                stmt.column_text(0)?.unwrap_or_default()
            );
        }
    }

    let _ = std::fs::remove_file(path);
    Ok(())
}
