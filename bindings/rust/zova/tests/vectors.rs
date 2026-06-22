use zova::{Database, Status, Step, VectorCollectionOptions, VectorInput, VectorMetric};

fn temp_path(name: &str) -> String {
    let mut path = std::env::temp_dir();
    path.push(format!(
        "zova-rust-vectors-{}-{}-{name}.zova",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let _ = std::fs::remove_file(&path);
    path.to_str().unwrap().to_owned()
}

fn f32_blob(values: &[f32]) -> Vec<u8> {
    values
        .iter()
        .flat_map(|value| value.to_le_bytes())
        .collect()
}

fn assert_close(actual: f64, expected: f64) {
    assert!(
        (actual - expected).abs() < 1e-6,
        "expected {expected}, got {actual}"
    );
}

#[test]
fn vector_collection_lifecycle_crud_batch_and_delete() {
    let path = temp_path("lifecycle");
    let mut db = Database::create(&path).unwrap();
    db.exec("create table chunks(id text primary key, vector_id text not null)")
        .unwrap();

    db.create_vector_collection(
        "chunks",
        VectorCollectionOptions {
            dimensions: 2,
            metric: VectorMetric::L2,
        },
    )
    .unwrap();
    db.create_vector_collection(
        "docs",
        VectorCollectionOptions {
            dimensions: 3,
            metric: VectorMetric::Dot,
        },
    )
    .unwrap();

    assert!(db.has_vector_collection("chunks").unwrap());
    let info = db.vector_collection_info("chunks").unwrap();
    assert_eq!(info.name, "chunks");
    assert_eq!(info.dimensions, 2);
    assert_eq!(info.metric, VectorMetric::L2);
    assert_eq!(info.vector_count, 0);

    let list = db.list_vector_collections().unwrap();
    assert_eq!(
        list.iter()
            .map(|item| item.name.as_str())
            .collect::<Vec<_>>(),
        ["chunks", "docs"]
    );

    db.put_vectors(
        "chunks",
        &[
            VectorInput {
                id: "a",
                values: &[2.0, 0.0],
            },
            VectorInput {
                id: "b",
                values: &[5.0, 0.0],
            },
            VectorInput {
                id: "a",
                values: &[1.0, 0.0],
            },
        ],
    )
    .unwrap();
    db.put_vectors("chunks", &[]).unwrap();

    assert!(db.has_vector("chunks", "a").unwrap());
    let vector = db.get_vector("chunks", "a").unwrap();
    assert_eq!(vector.id, "a");
    assert_eq!(vector.values, vec![1.0, 0.0]);

    db.exec("insert into chunks(id, vector_id) values ('row-a', 'a')")
        .unwrap();
    db.delete_vector("chunks", "a").unwrap();
    assert!(!db.has_vector("chunks", "a").unwrap());
    assert_eq!(
        db.delete_vector("chunks", "a").unwrap_err().status(),
        Some(Status::VectorNotFound)
    );

    let mut row = db
        .prepare("select vector_id from chunks where id = 'row-a'")
        .unwrap();
    assert_eq!(row.step().unwrap(), Step::Row);
    assert_eq!(row.column_text(0).unwrap(), Some("a".to_string()));
    drop(row);

    db.delete_vector_collection("chunks").unwrap();
    assert_eq!(
        db.has_vector("chunks", "b").unwrap_err().status(),
        Some(Status::VectorCollectionNotFound)
    );
    assert_eq!(
        db.delete_vector_collection("chunks").unwrap_err().status(),
        Some(Status::VectorCollectionNotFound)
    );

    let _ = std::fs::remove_file(path);
}

#[test]
fn vector_search_variants_preserve_c_abi_semantics() {
    let path = temp_path("search");
    let mut db = Database::create(&path).unwrap();
    db.create_vector_collection(
        "l2",
        VectorCollectionOptions {
            dimensions: 2,
            metric: VectorMetric::L2,
        },
    )
    .unwrap();
    db.put_vectors(
        "l2",
        &[
            VectorInput {
                id: "source",
                values: &[0.0, 0.0],
            },
            VectorInput {
                id: "near",
                values: &[1.0, 0.0],
            },
            VectorInput {
                id: "tie-a",
                values: &[0.0, 1.0],
            },
            VectorInput {
                id: "far",
                values: &[3.0, 4.0],
            },
        ],
    )
    .unwrap();

    let results = db.search_vectors("l2", &[0.0, 0.0], 3).unwrap();
    assert_eq!(
        results
            .iter()
            .map(|item| item.id.as_str())
            .collect::<Vec<_>>(),
        ["source", "near", "tie-a"]
    );
    assert_close(results[1].distance, 1.0);

    let candidate_results = db
        .search_vectors_in("l2", &[0.0, 0.0], &["far", "near", "near", "missing"], 10)
        .unwrap();
    assert_eq!(
        candidate_results
            .iter()
            .map(|item| item.id.as_str())
            .collect::<Vec<_>>(),
        ["near", "far"]
    );

    let by_id = db.search_vectors_by_id("l2", "source", 10).unwrap();
    assert!(!by_id.iter().any(|item| item.id == "source"));
    assert_eq!(by_id[0].id, "near");

    let by_id_in = db
        .search_vectors_by_id_in("l2", "source", &["source", "far", "near"], 10)
        .unwrap();
    assert_eq!(
        by_id_in
            .iter()
            .map(|item| item.id.as_str())
            .collect::<Vec<_>>(),
        ["near", "far"]
    );

    let within = db
        .search_vectors_within("l2", &[0.0, 0.0], 1.0, 10)
        .unwrap();
    assert_eq!(
        within
            .iter()
            .map(|item| item.id.as_str())
            .collect::<Vec<_>>(),
        ["source", "near", "tie-a"]
    );

    let in_within = db
        .search_vectors_in_within("l2", &[0.0, 0.0], &["near", "far"], 1.0, 10)
        .unwrap();
    assert_eq!(
        in_within
            .iter()
            .map(|item| item.id.as_str())
            .collect::<Vec<_>>(),
        ["near"]
    );

    let by_id_within = db
        .search_vectors_by_id_within("l2", "source", 1.0, 10)
        .unwrap();
    assert_eq!(
        by_id_within
            .iter()
            .map(|item| item.id.as_str())
            .collect::<Vec<_>>(),
        ["near", "tie-a"]
    );

    let by_id_in_within = db
        .search_vectors_by_id_in_within("l2", "source", &["near", "far"], 1.0, 10)
        .unwrap();
    assert_eq!(
        by_id_in_within
            .iter()
            .map(|item| item.id.as_str())
            .collect::<Vec<_>>(),
        ["near"]
    );

    db.create_vector_collection(
        "cosine",
        VectorCollectionOptions {
            dimensions: 2,
            metric: VectorMetric::Cosine,
        },
    )
    .unwrap();
    db.put_vector("cosine", "x", &[1.0, 0.0]).unwrap();
    db.put_vector("cosine", "diag", &[1.0, 1.0]).unwrap();
    let cosine = db.search_vectors("cosine", &[1.0, 0.0], 2).unwrap();
    assert_eq!(
        cosine
            .iter()
            .map(|item| item.id.as_str())
            .collect::<Vec<_>>(),
        ["x", "diag"]
    );
    assert_close(cosine[0].distance, 0.0);

    db.create_vector_collection(
        "dot",
        VectorCollectionOptions {
            dimensions: 2,
            metric: VectorMetric::Dot,
        },
    )
    .unwrap();
    db.put_vector("dot", "low", &[1.0, 0.0]).unwrap();
    db.put_vector("dot", "high", &[3.0, 0.0]).unwrap();
    let dot = db
        .search_vectors_within("dot", &[1.0, 0.0], -2.0, 10)
        .unwrap();
    assert_eq!(
        dot.iter().map(|item| item.id.as_str()).collect::<Vec<_>>(),
        ["high"]
    );
    assert_close(dot[0].distance, -3.0);

    assert_eq!(
        db.search_vectors("l2", &[0.0], 1).unwrap_err().status(),
        Some(Status::VectorDimensionMismatch)
    );
    assert!(matches!(
        db.put_vector("l2", "bad\0id", &[1.0, 2.0]).unwrap_err(),
        zova::Error::InteriorNul { .. }
    ));

    let _ = std::fs::remove_file(path);
}

#[test]
fn vectors_survive_reopen_conversion_and_sql_native_queries() {
    let path = temp_path("sql-native");
    {
        let mut db = Database::create(&path).unwrap();
        db.exec(
            "create table chunks(
                id text primary key,
                vector_id text not null,
                document_id text not null
            )",
        )
        .unwrap();
        db.create_vector_collection(
            "chunks",
            VectorCollectionOptions {
                dimensions: 2,
                metric: VectorMetric::L2,
            },
        )
        .unwrap();
        db.put_vectors(
            "chunks",
            &[
                VectorInput {
                    id: "v1",
                    values: &[0.0, 0.0],
                },
                VectorInput {
                    id: "v2",
                    values: &[1.0, 0.0],
                },
            ],
        )
        .unwrap();
        db.exec(
            "insert into chunks(id, vector_id, document_id) values
             ('c1', 'v1', 'doc-a'),
             ('c2', 'v2', 'doc-a')",
        )
        .unwrap();
    }

    let mut db = Database::open(&path).unwrap();
    assert_eq!(db.vector_collection_info("chunks").unwrap().vector_count, 2);

    let query_blob = f32_blob(&[0.0, 0.0]);
    let mut distance = db
        .prepare(
            "select c.id, zova_vector_distance('chunks', c.vector_id, ?1) as distance
             from chunks as c
             where c.document_id = 'doc-a'
             order by distance, c.id
             limit 1",
        )
        .unwrap();
    distance.bind_blob(1, &query_blob).unwrap();
    assert_eq!(distance.step().unwrap(), Step::Row);
    assert_eq!(distance.column_text(0).unwrap(), Some("c1".to_string()));
    assert_close(distance.column_f64(1).unwrap(), 0.0);
    drop(distance);

    let mut by_id = db
        .prepare("select zova_vector_distance_by_id('chunks', 'v2', 'v1')")
        .unwrap();
    assert_eq!(by_id.step().unwrap(), Step::Row);
    assert_close(by_id.column_f64(0).unwrap(), 1.0);
    drop(by_id);

    let mut search = db
        .prepare(
            "select c.id, s.distance
             from zova_vector_search as s
             join chunks as c on c.vector_id = s.vector_id
             where s.collection = 'chunks'
               and s.query_vector = ?1
               and s.top_k = 2
             order by s.rank",
        )
        .unwrap();
    search.bind_blob(1, &query_blob).unwrap();
    assert_eq!(search.step().unwrap(), Step::Row);
    assert_eq!(search.column_text(0).unwrap(), Some("c1".to_string()));
    assert_eq!(search.step().unwrap(), Step::Row);
    assert_eq!(search.column_text(0).unwrap(), Some("c2".to_string()));
    drop(search);

    let source_db = temp_path("source").replace(".zova", ".db");
    let dest = temp_path("converted");
    let _ = std::fs::remove_file(&source_db);
    let mut sqlite = rusqlite_like_plain_sqlite::create(&source_db);
    sqlite.exec(
        "create table rows(id integer primary key, value text);
         insert into rows(value) values ('converted');",
    );
    drop(sqlite);
    Database::convert_sqlite_to_zova(&source_db, &dest).unwrap();
    let mut converted = Database::open(&dest).unwrap();
    converted
        .create_vector_collection(
            "converted_vectors",
            VectorCollectionOptions {
                dimensions: 2,
                metric: VectorMetric::L2,
            },
        )
        .unwrap();
    converted
        .put_vector("converted_vectors", "v", &[1.0, 2.0])
        .unwrap();
    assert!(converted.has_vector("converted_vectors", "v").unwrap());

    let _ = std::fs::remove_file(path);
    let _ = std::fs::remove_file(source_db);
    let _ = std::fs::remove_file(dest);
}

mod rusqlite_like_plain_sqlite {
    use std::ffi::{CStr, CString};
    use std::os::raw::{c_char, c_int, c_void};
    use std::ptr;

    #[repr(C)]
    struct sqlite3 {
        _private: [u8; 0],
    }

    extern "C" {
        fn sqlite3_open(filename: *const c_char, db: *mut *mut sqlite3) -> c_int;
        fn sqlite3_exec(
            db: *mut sqlite3,
            sql: *const c_char,
            callback: Option<
                extern "C" fn(*mut c_void, c_int, *mut *mut c_char, *mut *mut c_char) -> c_int,
            >,
            first_arg: *mut c_void,
            errmsg: *mut *mut c_char,
        ) -> c_int;
        fn sqlite3_close(db: *mut sqlite3) -> c_int;
        fn sqlite3_free(ptr: *mut c_void);
    }

    pub struct PlainSqlite {
        db: *mut sqlite3,
    }

    pub fn create(path: &str) -> PlainSqlite {
        let c_path = CString::new(path).unwrap();
        let mut db = ptr::null_mut();
        unsafe {
            assert_eq!(sqlite3_open(c_path.as_ptr(), &mut db), 0);
        }
        PlainSqlite { db }
    }

    impl PlainSqlite {
        pub fn exec(&mut self, sql: &str) {
            let sql = CString::new(sql).unwrap();
            unsafe {
                let mut errmsg = ptr::null_mut();
                let rc = sqlite3_exec(self.db, sql.as_ptr(), None, ptr::null_mut(), &mut errmsg);
                if rc != 0 {
                    let message = if errmsg.is_null() {
                        format!("sqlite3_exec failed with rc {rc}")
                    } else {
                        let message = CStr::from_ptr(errmsg).to_string_lossy().into_owned();
                        sqlite3_free(errmsg.cast());
                        message
                    };
                    panic!("{message}");
                }
            }
        }
    }

    impl Drop for PlainSqlite {
        fn drop(&mut self) {
            unsafe {
                assert_eq!(sqlite3_close(self.db), 0);
            }
        }
    }
}
