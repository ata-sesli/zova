use std::convert::TryFrom;
use zova::{Database, ObjectId, Step};

fn main() -> zova::Result<()> {
    let path = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "rust-objects.zova".to_string());
    let _ = std::fs::remove_file(&path);

    let mut db = Database::create(&path)?;
    db.exec(
        "create table attachments(
            id integer primary key,
            filename text not null,
            object_id blob not null
        )",
    )?;

    let mut writer = db.object_writer()?;
    writer.write(b"hello ")?;
    writer.write(b"from a streamed Rust object")?;
    let object_id = writer.finish()?;

    let mut insert = db.prepare("insert into attachments(filename, object_id) values (?1, ?2)")?;
    insert.bind_text(1, "greeting.txt")?;
    insert.bind_blob(2, object_id.as_ref())?;
    assert_eq!(insert.step()?, Step::Done);
    drop(insert);

    let mut query = db.prepare("select filename, object_id from attachments where id = ?1")?;
    query.bind_i64(1, 1)?;
    assert_eq!(query.step()?, Step::Row);
    let filename = query.column_text(0)?.unwrap_or_default();
    let stored_id = ObjectId::try_from(query.column_blob(1)?.unwrap().as_slice())?;
    drop(query);

    let mut preview = [0_u8; 16];
    let copied = db.read_object_range(stored_id, 0, &mut preview)?;
    println!(
        "{filename}: {}",
        String::from_utf8_lossy(&preview[..copied])
    );

    Ok(())
}
