use std::path::PathBuf;
use zova::{Database, ExtensionOptions, OpenOptions, SharedDatabase, Status, Step};

#[test]
fn plugin_selection_rejects_nul_paths_before_creating_a_database() {
    let path =
        std::env::temp_dir().join(format!("zova-plugin-invalid-{}.zova", std::process::id()));
    let options = ExtensionOptions {
        bundle_paths: vec![PathBuf::from("invalid\0.zovaext")],
        trust_store_path: None,
    };
    assert!(Database::create_with_extensions(&path, &options).is_err());
    assert!(SharedDatabase::create_with_extensions(&path, &options).is_err());
    assert!(!path.exists());
}

#[test]
#[ignore = "requires the isolated portable plugin package fixture"]
fn trusted_plugins_work_through_safe_and_shared_handles() {
    let bundle = PathBuf::from(std::env::var_os("ZOVA_TEST_PLUGIN_BUNDLE").unwrap());
    let trust = PathBuf::from(std::env::var_os("ZOVA_TEST_PLUGIN_TRUST_STORE").unwrap());
    let options = ExtensionOptions {
        bundle_paths: vec![bundle],
        trust_store_path: Some(trust),
    };
    let path = std::env::temp_dir().join(format!("zova-plugin-safe-{}.zova", std::process::id()));
    {
        let mut db = Database::create_with_extensions(&path, &options).unwrap();
        db.install_extension("c_test").unwrap();
        let mut stmt = db.prepare_owned("SELECT zova_c_test_cached()").unwrap();
        drop(db); // The child retains the handle, registry and native library.
        assert_eq!(stmt.step().unwrap(), Step::Row);
        assert_eq!(stmt.column_i64(0).unwrap(), 42);
    }
    assert_eq!(
        Database::open(&path).unwrap_err().status(),
        Some(Status::ExtensionUnavailable)
    );
    let db = SharedDatabase::open_with_extensions(
        &path,
        OpenOptions {
            read_only: true,
            busy_timeout_ms: 10,
        },
        &options,
    )
    .unwrap();
    db.check_extension("c_test").unwrap();
    let mut stmt = db.prepare("SELECT zova_c_test_cached()").unwrap();
    drop(db);
    assert_eq!(stmt.step().unwrap(), Step::Row);
    assert_eq!(stmt.column_i64(0).unwrap(), 42);
    drop(stmt);
    std::fs::remove_file(path).unwrap();
}
