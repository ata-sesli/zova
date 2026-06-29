use zova::{Database, Step, VectorCollectionOptions, VectorMetric};

fn main() -> zova::Result<()> {
    let path = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "rust-notifications.zova".to_string());
    let _ = std::fs::remove_file(&path);

    let mut db = Database::create(&path)?;
    db.exec(
        "create table attachments(
            id integer primary key,
            filename text not null,
            object_id blob not null
        )",
    )?;

    let mut listener = db.listen("message:1:attachments")?;

    let object_id = db.put_object(b"hello from an object notification")?;

    db.begin_immediate()?;
    {
        let mut insert =
            db.prepare("insert into attachments(filename, object_id) values (?1, ?2)")?;
        insert.bind_text(1, "hello.txt")?;
        insert.bind_blob(2, object_id.as_ref())?;
        assert_eq!(insert.step()?, Step::Done);
    }
    db.notify("message:1:attachments", "changed")?;
    assert!(listener.try_receive()?.is_none());
    db.commit()?;

    let notification = listener.try_receive()?.expect("notification after commit");
    println!("{} {}", notification.channel, notification.payload);

    let mut query = db.prepare("select filename from attachments where id = 1")?;
    assert_eq!(query.step()?, Step::Row);
    println!("reload {}", query.column_text(0)?.unwrap_or_default());
    drop(query);

    db.exec("create table chunks(id text primary key, vector_id text not null)")?;
    db.create_vector_collection(
        "chunks",
        VectorCollectionOptions {
            dimensions: 2,
            metric: VectorMetric::L2,
        },
    )?;
    db.put_vector("chunks", "chunk:1", &[0.0, 0.0])?;
    let mut vector_listener = db.listen("vectors:chunks")?;
    db.begin_immediate()?;
    db.exec("insert into chunks(id, vector_id) values ('c1', 'chunk:1')")?;
    db.notify("vectors:chunks", "changed")?;
    db.commit()?;
    let vector_event = vector_listener.try_receive()?.expect("vector notification");
    let results = db.search_vectors("chunks", &[0.0, 0.0], 1)?;
    println!("{} {}", vector_event.channel, results[0].id);
    Ok(())
}
