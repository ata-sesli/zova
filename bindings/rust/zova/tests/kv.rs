use zova::{Database, KvEntry, SharedDatabase};

fn temp_path(name: &str) -> String {
    let mut path = std::env::temp_dir();
    path.push(format!(
        "zova-rust-kv-{}-{}-{name}.zova",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let _ = std::fs::remove_file(&path);
    path.to_str().unwrap().to_owned()
}

#[test]
fn database_kv_crud_preserves_exact_bytes() {
    let path = temp_path("crud");
    let mut db = Database::create(&path).unwrap();

    db.kv_put(b"settings", b"theme", b"dark").unwrap();
    db.kv_put(b"settings", b"retries", b"\x00\x01\x02").unwrap();
    db.kv_put(b"settings", b"empty", b"").unwrap();

    assert_eq!(
        db.kv_get(b"settings", b"theme").unwrap().as_deref(),
        Some(&b"dark"[..])
    );
    assert_eq!(
        db.kv_get(b"settings", b"retries").unwrap().as_deref(),
        Some(&b"\x00\x01\x02"[..])
    );
    assert_eq!(
        db.kv_get(b"settings", b"empty").unwrap().as_deref(),
        Some(&b""[..])
    );
    assert_eq!(db.kv_get(b"settings", b"ghost").unwrap(), None);
    assert_eq!(db.kv_get(b"other", b"theme").unwrap(), None);

    assert_eq!(db.kv_count(b"settings").unwrap(), 3);

    db.kv_put(b"settings", b"theme", b"light").unwrap();
    assert_eq!(
        db.kv_get(b"settings", b"theme").unwrap().as_deref(),
        Some(&b"light"[..])
    );
    assert_eq!(db.kv_count(b"settings").unwrap(), 3);

    db.kv_delete(b"settings", b"theme").unwrap();
    assert_eq!(db.kv_get(b"settings", b"theme").unwrap(), None);
    assert_eq!(db.kv_count(b"settings").unwrap(), 2);

    db.kv_delete(b"settings", b"ghost").unwrap();
    assert_eq!(db.kv_count(b"settings").unwrap(), 2);

    db.kv_clear_namespace(b"settings").unwrap();
    assert_eq!(db.kv_count(b"settings").unwrap(), 0);

    std::fs::remove_file(&path).unwrap();
}

#[test]
fn database_kv_get_many_preserves_order_and_duplicates() {
    let path = temp_path("get_many");
    let mut db = Database::create(&path).unwrap();

    db.kv_put(b"ns", b"a", b"1").unwrap();
    db.kv_put(b"ns", b"b", b"2").unwrap();
    db.kv_put(b"ns", b"c", b"3").unwrap();

    let keys: [&[u8]; 4] = [b"c", b"ghost", b"a", b"c"];
    let results = db.kv_get_many(b"ns", &keys).unwrap();
    assert_eq!(results.len(), 4);
    assert_eq!(results[0].as_deref(), Some(&b"3"[..]));
    assert_eq!(results[1], None);
    assert_eq!(results[2].as_deref(), Some(&b"1"[..]));
    assert_eq!(results[3].as_deref(), Some(&b"3"[..]));

    std::fs::remove_file(&path).unwrap();
}

#[test]
fn database_kv_put_many_is_atomic_and_delete_many_ignores_missing() {
    let path = temp_path("batch");
    let mut db = Database::create(&path).unwrap();

    db.kv_put_many(
        b"ns",
        &[
            KvEntry::new(b"k1", b"v1"),
            KvEntry::new(b"k2", b"v2"),
            KvEntry::new(b"k3", b""),
        ],
    )
    .unwrap();
    assert_eq!(db.kv_count(b"ns").unwrap(), 3);

    db.kv_delete_many(b"ns", &[b"k1", b"ghost", b"k3"]).unwrap();
    assert_eq!(db.kv_count(b"ns").unwrap(), 1);
    assert_eq!(
        db.kv_get(b"ns", b"k2").unwrap().as_deref(),
        Some(&b"v2"[..])
    );

    db.kv_put_many(b"ns", &[]).unwrap();
    assert_eq!(db.kv_count(b"ns").unwrap(), 1);

    db.kv_delete_many(b"ns", &[]).unwrap();
    assert_eq!(db.kv_count(b"ns").unwrap(), 1);

    std::fs::remove_file(&path).unwrap();
}

#[test]
fn database_kv_partitions_by_namespace() {
    let path = temp_path("partition");
    let mut db = Database::create(&path).unwrap();

    db.kv_put(b"a", b"key", b"1").unwrap();
    db.kv_put(b"b", b"key", b"2").unwrap();

    assert_eq!(db.kv_get(b"a", b"key").unwrap().as_deref(), Some(&b"1"[..]));
    assert_eq!(db.kv_get(b"b", b"key").unwrap().as_deref(), Some(&b"2"[..]));
    assert_eq!(db.kv_count(b"a").unwrap(), 1);
    assert_eq!(db.kv_count(b"b").unwrap(), 1);

    db.kv_clear_namespace(b"a").unwrap();
    assert_eq!(db.kv_count(b"a").unwrap(), 0);
    assert_eq!(db.kv_count(b"b").unwrap(), 1);

    std::fs::remove_file(&path).unwrap();
}

#[test]
fn shared_database_kv_crud_and_many() {
    let path = temp_path("shared");
    let db = SharedDatabase::create(&path).unwrap();

    db.kv_put(b"cfg", b"mode", b"fast").unwrap();
    db.kv_put(b"cfg", b"limit", b"10").unwrap();
    assert_eq!(
        db.kv_get(b"cfg", b"mode").unwrap().as_deref(),
        Some(&b"fast"[..])
    );
    assert_eq!(db.kv_get(b"cfg", b"nope").unwrap(), None);
    assert_eq!(db.kv_count(b"cfg").unwrap(), 2);

    let results = db
        .kv_get_many(b"cfg", &[b"mode", b"nope", b"limit"])
        .unwrap();
    assert_eq!(results.len(), 3);
    assert_eq!(results[0].as_deref(), Some(&b"fast"[..]));
    assert_eq!(results[1], None);
    assert_eq!(results[2].as_deref(), Some(&b"10"[..]));

    db.kv_put_many(
        b"cfg",
        &[KvEntry::new(b"x", b"1"), KvEntry::new(b"y", b"2")],
    )
    .unwrap();
    assert_eq!(db.kv_count(b"cfg").unwrap(), 4);

    db.kv_delete_many(b"cfg", &[b"x", b"nope", b"y"]).unwrap();
    assert_eq!(db.kv_count(b"cfg").unwrap(), 2);

    db.kv_clear_namespace(b"cfg").unwrap();
    assert_eq!(db.kv_count(b"cfg").unwrap(), 0);

    std::fs::remove_file(&path).unwrap();
}

#[test]
fn shared_database_guard_kv_joins_transaction() {
    let path = temp_path("guard");
    let db = SharedDatabase::create(&path).unwrap();

    db.kv_put(b"ns", b"a", b"1").unwrap();
    db.kv_put(b"ns", b"b", b"2").unwrap();

    db.transaction(|guard| {
        guard.kv_delete(b"ns", b"a").unwrap();
        guard.kv_put(b"ns", b"c", b"3").unwrap();
        assert_eq!(guard.kv_count(b"ns").unwrap(), 2);
        assert_eq!(
            guard.kv_get(b"ns", b"c").unwrap().as_deref(),
            Some(&b"3"[..])
        );
        let results = guard.kv_get_many(b"ns", &[b"b", b"ghost", b"c"]).unwrap();
        assert_eq!(results[0].as_deref(), Some(&b"2"[..]));
        assert_eq!(results[1], None);
        assert_eq!(results[2].as_deref(), Some(&b"3"[..]));
        Ok(())
    })
    .unwrap();

    assert_eq!(db.kv_count(b"ns").unwrap(), 2);
    assert_eq!(db.kv_get(b"ns", b"a").unwrap(), None);
    assert_eq!(db.kv_get(b"ns", b"b").unwrap().as_deref(), Some(&b"2"[..]));
    assert_eq!(db.kv_get(b"ns", b"c").unwrap().as_deref(), Some(&b"3"[..]));

    db.transaction(|guard| {
        guard.kv_put(b"ns", b"d", b"4").unwrap();
        guard.exec("select * from missing_table")?;
        Ok(())
    })
    .unwrap_err();

    assert_eq!(db.kv_count(b"ns").unwrap(), 2);
    assert_eq!(db.kv_get(b"ns", b"d").unwrap(), None);

    std::fs::remove_file(&path).unwrap();
}
