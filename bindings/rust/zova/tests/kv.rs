use zova::{Database, KvEntry, KvScanEntry, KvScanOptions, SharedDatabase};

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

    drop(db);
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

    drop(db);
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

    drop(db);
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

    drop(db);
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

    drop(db);
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

    drop(db);
    std::fs::remove_file(&path).unwrap();
}

#[test]
fn database_kv_scan_pages_in_key_byte_order() {
    let mut db = Database::create_memory().unwrap();
    for key in [&b"b"[..], b"", b"a\xff", b"a", b"ab", b"a\x00", b"c"] {
        db.kv_put(b"ns", key, key).unwrap();
    }
    db.kv_put(b"other", b"a", b"elsewhere").unwrap();

    let all = db.kv_scan(b"ns", &KvScanOptions::new(100)).unwrap();
    let keys: Vec<&[u8]> = all.entries.iter().map(|entry| &entry.key[..]).collect();
    assert_eq!(
        keys,
        [&b""[..], b"a", b"a\x00", b"ab", b"a\xff", b"b", b"c"]
    );
    assert!(all.entries.iter().all(|entry| entry.key == entry.value));
    assert!(!all.has_more);

    let prefixed = db
        .kv_scan(
            b"ns",
            &KvScanOptions {
                prefix: b"a",
                keys_only: true,
                ..KvScanOptions::new(2)
            },
        )
        .unwrap();
    assert_eq!(
        prefixed.entries,
        [
            KvScanEntry {
                key: b"a".to_vec(),
                value: Vec::new()
            },
            KvScanEntry {
                key: b"a\x00".to_vec(),
                value: Vec::new()
            },
        ]
    );
    assert!(prefixed.has_more);
    let next = db
        .kv_scan(
            b"ns",
            &KvScanOptions {
                prefix: b"a",
                after: Some(b"a\x00"),
                ..KvScanOptions::new(2)
            },
        )
        .unwrap();
    let keys: Vec<&[u8]> = next.entries.iter().map(|entry| &entry.key[..]).collect();
    assert_eq!(keys, [&b"ab"[..], b"a\xff"]);
    assert!(!next.has_more);

    let bounded = db
        .kv_scan(
            b"ns",
            &KvScanOptions {
                start: Some(b"a\x00"),
                end: Some(b"b"),
                ..KvScanOptions::new(10)
            },
        )
        .unwrap();
    assert_eq!(bounded.entries.len(), 3);
    let error = db.kv_scan(b"ns", &KvScanOptions::new(0)).unwrap_err();
    assert_eq!(error.status(), Some(zova::Status::InvalidArgument));
}

#[test]
fn database_kv_conditional_writes_report_whether_they_applied() {
    let mut db = Database::create_memory().unwrap();
    assert!(db.kv_put_if_absent(b"ns", b"k", b"v1").unwrap());
    assert!(!db.kv_put_if_absent(b"ns", b"k", b"other").unwrap());
    assert!(!db.kv_compare_and_put(b"ns", b"k", b"stale", b"v2").unwrap());
    assert!(!db
        .kv_compare_and_put(b"ns", b"missing", b"", b"v2")
        .unwrap());
    assert!(db.kv_compare_and_put(b"ns", b"k", b"v1", b"").unwrap());
    assert!(db.kv_compare_and_put(b"ns", b"k", b"", b"v2").unwrap());
    assert!(!db.kv_compare_and_delete(b"ns", b"k", b"v1").unwrap());
    assert!(db.kv_compare_and_delete(b"ns", b"k", b"v2").unwrap());
    assert_eq!(db.kv_get(b"ns", b"k").unwrap(), None);

    db.begin().unwrap();
    assert!(db.kv_put_if_absent(b"ns", b"k", b"v3").unwrap());
    db.rollback().unwrap();
    assert_eq!(db.kv_count(b"ns").unwrap(), 0);
}

#[test]
fn shared_database_kv_scan_and_conditional_writes() {
    let db = SharedDatabase::create(&temp_path("shared-scan")).unwrap();
    assert!(db.kv_put_if_absent(b"ns", b"a", b"1").unwrap());
    assert!(db.kv_put_if_absent(b"ns", b"b", b"2").unwrap());
    assert!(db.kv_compare_and_put(b"ns", b"a", b"1", b"one").unwrap());
    let page = db.kv_scan(b"ns", &KvScanOptions::new(1)).unwrap();
    assert_eq!(
        page.entries,
        [KvScanEntry {
            key: b"a".to_vec(),
            value: b"one".to_vec()
        }]
    );
    assert!(page.has_more);
    assert!(db.kv_compare_and_delete(b"ns", b"b", b"2").unwrap());
    assert_eq!(db.kv_count(b"ns").unwrap(), 1);
}
