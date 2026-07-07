use zova::{
    Database, GraphEdgeInput, GraphNodeInput, GraphTargetType, Step, VectorCollectionOptions,
    VectorElementType, VectorMetric, VectorValues, DEFAULT_GRAPH_NAME,
};

fn hex(bytes: [u8; 32]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn exec_one(db: &mut Database, sql: &str) -> zova::Result<()> {
    let mut stmt = db.prepare(sql)?;
    assert_eq!(stmt.step()?, Step::Row);
    Ok(())
}

fn trgm_put(
    db: &mut Database,
    index: &str,
    document_id: &str,
    target_type: &str,
    target_namespace: Option<&str>,
    target_ref: Option<&str>,
    text: &str,
) -> zova::Result<()> {
    let mut stmt = db.prepare("select zova_trgm_put(?1, ?2, ?3, ?4, ?5, ?6)")?;
    stmt.bind_text(1, index)?;
    stmt.bind_text(2, document_id)?;
    stmt.bind_text(3, target_type)?;
    match target_namespace {
        Some(value) => stmt.bind_text(4, value)?,
        None => stmt.bind_null(4)?,
    }
    match target_ref {
        Some(value) => stmt.bind_text(5, value)?,
        None => stmt.bind_null(5)?,
    }
    stmt.bind_text(6, text)?;
    assert_eq!(stmt.step()?, Step::Row);
    Ok(())
}

fn main() -> zova::Result<()> {
    let path = std::env::temp_dir().join(format!(
        "zova-rust-extensions-example-{}.zova",
        std::process::id()
    ));
    let _ = std::fs::remove_file(&path);

    let mut db = Database::create(&path)?;
    db.install_extension("trgm")?;
    db.check_extensions()?;
    exec_one(&mut db, "select zova_trgm_create_index('targets')")?;

    db.exec(
        "create table messages(
            id text primary key,
            graph_node_id text not null,
            body text not null
        )",
    )?;
    db.exec(
        "insert into messages(id, graph_node_id, body)
         values ('m1', 'message:m1', 'Receipt attachment failed to upload')",
    )?;

    let object_id = db.put_object(b"receipt attachment bytes")?;
    let object_hex = hex(object_id.into_bytes());
    db.create_vector_collection(
        "chunks",
        VectorCollectionOptions {
            dimensions: 2,
            metric: VectorMetric::L2,
            element_type: VectorElementType::F32,
        },
    )?;
    db.put_vector("chunks", "chunk:m1", VectorValues::F32(&[0.0, 1.0]))?;
    db.create_graph(DEFAULT_GRAPH_NAME)?;
    db.put_graph_node(GraphNodeInput {
        graph_name: DEFAULT_GRAPH_NAME,
        node_id: "message:m1",
        kind: "message",
        target_type: GraphTargetType::Record,
        target_namespace: Some("messages"),
        target_ref: Some("m1"),
    })?;
    db.put_graph_node(GraphNodeInput {
        graph_name: DEFAULT_GRAPH_NAME,
        node_id: "entity:receipt",
        kind: "entity",
        target_type: GraphTargetType::Entity,
        target_namespace: None,
        target_ref: Some("receipt"),
    })?;
    db.put_graph_edge(GraphEdgeInput {
        graph_name: DEFAULT_GRAPH_NAME,
        from_node_id: "message:m1",
        edge_type: "mentions",
        to_node_id: "entity:receipt",
    })?;

    let mut listener = db.listen("search:indexed")?;
    db.begin_immediate()?;
    trgm_put(
        &mut db,
        "targets",
        "message:m1",
        "record",
        Some("messages"),
        Some("m1"),
        "Receipt attachment failed to upload",
    )?;
    trgm_put(
        &mut db,
        "targets",
        "attachment:m1",
        "object",
        None,
        Some(&object_hex),
        "receipt.pdf",
    )?;
    trgm_put(
        &mut db,
        "targets",
        "chunk:m1",
        "vector",
        Some("chunks"),
        Some("chunk:m1"),
        "receipt upload chunk",
    )?;
    trgm_put(
        &mut db,
        "targets",
        "entity:receipt",
        "graph",
        Some(DEFAULT_GRAPH_NAME),
        Some("entity:receipt"),
        "receipt",
    )?;
    db.notify("search:indexed", "targets")?;
    assert!(listener.try_receive()?.is_none());
    db.commit()?;
    assert_eq!(listener.try_receive()?.unwrap().payload, "targets");

    let mut search = db.prepare(
        "select document_id, target_type, target_namespace, target_ref
         from zova_trgm_search
         where index_name = 'targets'
           and query = ?1
           and \"limit\" = 4
         order by rank",
    )?;
    search.bind_text(1, "reciept attachement")?;
    while search.step()? == Step::Row {
        println!(
            "{} {} {:?} {:?}",
            search.column_text(0)?.unwrap_or_default(),
            search.column_text(1)?.unwrap_or_default(),
            search.column_text(2)?,
            search.column_text(3)?
        );
    }

    let _ = std::fs::remove_file(path);
    Ok(())
}
