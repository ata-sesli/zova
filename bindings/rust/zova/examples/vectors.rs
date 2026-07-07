use zova::{
    Database, Step, VectorCollectionOptions, VectorElementType, VectorInput, VectorMetric,
    VectorValues, VectorValuesOwned,
};

fn f32_blob(values: &[f32]) -> Vec<u8> {
    values
        .iter()
        .flat_map(|value| value.to_le_bytes())
        .collect()
}

fn main() -> zova::Result<()> {
    let path = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "rust-vectors.zova".to_string());
    let _ = std::fs::remove_file(&path);

    let mut db = Database::create(&path)?;
    db.exec(
        "create table chunks(
            id text primary key,
            vector_id text not null,
            body text not null,
            document_id text not null
        )",
    )?;

    db.create_vector_collection(
        "chunks",
        VectorCollectionOptions {
            dimensions: 2,
            metric: VectorMetric::L2,
            element_type: VectorElementType::F32,
        },
    )?;
    db.put_vectors(
        "chunks",
        &[
            VectorInput {
                id: "v1",
                values: VectorValues::F32(&[0.0, 0.0]),
            },
            VectorInput {
                id: "v2",
                values: VectorValues::F32(&[1.0, 0.0]),
            },
        ],
    )?;
    db.exec(
        "insert into chunks(id, vector_id, body, document_id) values
         ('c1', 'v1', 'first chunk', 'doc-a'),
         ('c2', 'v2', 'second chunk', 'doc-a')",
    )?;

    let results = db.search_vectors("chunks", VectorValues::F32(&[0.0, 0.0]), 2)?;
    for result in &results {
        let mut row = db.prepare("select body from chunks where vector_id = ?1")?;
        row.bind_text(1, &result.id)?;
        if row.step()? == Step::Row {
            println!(
                "{} {}",
                row.column_text(0)?.unwrap_or_default(),
                result.distance
            );
        }
    }

    let query = f32_blob(&[0.0, 0.0]);
    let mut sql_search = db.prepare(
        "select c.body, s.distance
         from zova_vector_search as s
         join chunks as c on c.vector_id = s.vector_id
         where s.collection = 'chunks'
           and s.query_vector = ?1
           and s.top_k = 2
         order by s.rank",
    )?;
    sql_search.bind_blob(1, &query)?;
    while sql_search.step()? == Step::Row {
        println!(
            "sql: {} {}",
            sql_search.column_text(0)?.unwrap_or_default(),
            sql_search.column_f64(1)?
        );
    }

    db.create_vector_collection(
        "scores_i8",
        VectorCollectionOptions {
            dimensions: 2,
            metric: VectorMetric::L2,
            element_type: VectorElementType::I8,
        },
    )?;
    db.put_vectors(
        "scores_i8",
        &[
            VectorInput {
                id: "near",
                values: VectorValues::I8(&[1, -1]),
            },
            VectorInput {
                id: "far",
                values: VectorValues::I8(&[8, -1]),
            },
        ],
    )?;
    let i8_hit = db.search_vectors("scores_i8", VectorValues::I8(&[0, 0]), 1)?;
    println!("i8: {} {}", i8_hit[0].id, i8_hit[0].distance);

    db.create_vector_collection(
        "halves",
        VectorCollectionOptions {
            dimensions: 2,
            metric: VectorMetric::L2,
            element_type: VectorElementType::F16,
        },
    )?;
    db.put_vector("halves", "one", VectorValues::F16(&[0x3c00, 0x0000]))?;
    let half = db.get_vector("halves", "one")?;
    println!(
        "f16: {:?}",
        match half.values {
            VectorValuesOwned::F16(values) => values,
            other => panic!("unexpected vector values: {other:?}"),
        }
    );

    Ok(())
}
