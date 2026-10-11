use std::path::PathBuf;
use zova::{Database, ExtensionOptions, OpenOptions, Step};

#[test]
#[ignore = "requires the isolated NetworKit reference fixture"]
fn networkit_pagerank_sql_rows_work_in_safe_rust() {
    let options = ExtensionOptions {
        bundle_paths: vec![PathBuf::from(
            std::env::var_os("ZOVA_PAGERANK_BUNDLE").unwrap(),
        )],
        trust_store_path: Some(PathBuf::from(
            std::env::var_os("ZOVA_PAGERANK_TRUST").unwrap(),
        )),
    };
    let path = PathBuf::from(std::env::var_os("ZOVA_PAGERANK_DATABASE").unwrap());
    let mut db = Database::open_with_extensions(
        &path,
        OpenOptions {
            read_only: true,
            busy_timeout_ms: 0,
        },
        &options,
    )
    .unwrap();
    let mut statement = db.prepare_owned("SELECT node_key,node_id,score FROM zova_networkit_pagerank('cycle',0.85,1e-10,200,10,10)").unwrap();
    drop(db);
    let mut count = 0;
    let mut sum = 0.0;
    while statement.step().unwrap() == Step::Row {
        assert!(statement.column_i64(0).unwrap() > 0);
        assert!(!statement.column_text(1).unwrap().unwrap().is_empty());
        sum += statement.column_f64(2).unwrap();
        count += 1;
    }
    assert_eq!(count, 4);
    assert!((sum - 1.0).abs() < 1e-10);
}
