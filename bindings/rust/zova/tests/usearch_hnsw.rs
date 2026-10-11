use std::path::PathBuf;
use zova::{Database, ExtensionOptions, OpenOptions, Step};

#[test]
#[ignore = "requires the isolated USearch reference fixture"]
fn usearch_persistent_search_works_in_safe_rust() {
    let options = ExtensionOptions {
        bundle_paths: vec![PathBuf::from(
            std::env::var_os("ZOVA_USEARCH_BUNDLE").unwrap(),
        )],
        trust_store_path: Some(PathBuf::from(
            std::env::var_os("ZOVA_USEARCH_TRUST").unwrap(),
        )),
    };
    let mut db = Database::open_with_extensions(
        PathBuf::from(std::env::var_os("ZOVA_USEARCH_DATABASE").unwrap()),
        OpenOptions {
            read_only: true,
            busy_timeout_ms: 0,
        },
        &options,
    )
    .unwrap();
    let mut statement = db
        .prepare_owned(
            "SELECT vector_id,distance FROM zova_usearch_search('points',x'0000000000000000',2,64)",
        )
        .unwrap();
    drop(db);
    let mut count = 0;
    while statement.step().unwrap() == Step::Row {
        assert_eq!(
            statement.column_text(0).unwrap().unwrap(),
            if count == 0 { "one" } else { "two" }
        );
        assert_eq!(statement.column_f64(1).unwrap(), f64::from(count + 1));
        count += 1;
    }
    assert_eq!(count, 2);
}
