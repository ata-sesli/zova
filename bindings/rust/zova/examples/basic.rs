use zova::{Database, Step};

fn main() -> zova::Result<()> {
    let path = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "rust-basic.zova".to_string());
    let _ = std::fs::remove_file(&path);

    let mut db = Database::create(&path)?;
    db.exec("create table notes(id integer primary key, body text not null)")?;

    let mut insert = db.prepare("insert into notes(body) values (?1)")?;
    insert.bind_text(1, "hello from Rust")?;
    assert_eq!(insert.step()?, Step::Done);
    drop(insert);

    let mut query = db.prepare("select body from notes where id = ?1")?;
    query.bind_i64(1, 1)?;
    assert_eq!(query.step()?, Step::Row);
    println!("{}", query.column_text(0)?.unwrap_or_default());

    Ok(())
}
