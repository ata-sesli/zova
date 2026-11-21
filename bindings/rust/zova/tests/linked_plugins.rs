use std::ops::ControlFlow;
use std::path::PathBuf;
use std::ptr;
use zova::{
    migrate_database_with_plugins, migrate_database_with_plugins_and_progress,
    untrust_extension_bundle, verify_extension_bundle, CreateOptions, Database, ExtensionOptions,
    LinkedPlugin, MigrateOptions, OpenOptions, SharedDatabase, Status, Step,
};
use zova_sys::plugin::zova_plugin_descriptor_v1;

struct StaticDescriptor(zova_plugin_descriptor_v1);

// Safety: the descriptor is immutable and points only at static strings.
unsafe impl Sync for StaticDescriptor {}

static LINKED_DESCRIPTOR: StaticDescriptor = StaticDescriptor(zova_plugin_descriptor_v1 {
    struct_size: std::mem::size_of::<zova_plugin_descriptor_v1>() as u32,
    abi_version: zova_sys::plugin::ZOVA_PLUGIN_ABI_V1,
    flags: 0,
    name: c"linked_test".as_ptr(),
    version: c"1.0.0".as_ptr(),
    storage_prefix: c"_zova_ext_linked_test_".as_ptr(),
    zova_abi_min: c"1.0.0".as_ptr(),
    capabilities: ptr::null(),
    install: None,
    check: None,
    drop: None,
    register_sql: None,
});

fn linked() -> LinkedPlugin {
    // Safety: the descriptor has static metadata strings and no hooks.
    unsafe { LinkedPlugin::new(&LINKED_DESCRIPTOR.0) }
}

struct TempDir(PathBuf);

impl TempDir {
    fn new(name: &str) -> Self {
        let path = std::env::temp_dir().join(format!(
            "zova-rust-linked-{}-{}-{name}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn create_with_options_sets_the_page_size() {
    let dir = TempDir::new("page-size");
    let path = dir.0.join("pages.zova");
    let mut db = Database::create_with_options(&path, CreateOptions { page_size: 8192 }).unwrap();
    let mut statement = db.prepare("pragma page_size").unwrap();
    assert_eq!(statement.step().unwrap(), Step::Row);
    assert_eq!(statement.column_i64(0).unwrap(), 8192);
    drop(statement);
    drop(db);

    let error = SharedDatabase::create_with_options(&path, CreateOptions::default()).unwrap_err();
    assert!(error.status().is_some());
}

#[test]
fn linked_plugins_open_upgrade_and_migrate_through_safe_handles() {
    let dir = TempDir::new("plugins");
    let path = dir.0.join("linked.zova");
    let none = ExtensionOptions::default();
    {
        let mut db = Database::create_with_plugins(&path, &none, &[linked()]).unwrap();
        db.install_extension("linked_test").unwrap();
    }
    assert_eq!(
        Database::open(&path).unwrap_err().status(),
        Some(Status::ExtensionUnavailable)
    );
    assert_eq!(
        Database::open_with_plugins(&path, OpenOptions::default(), &none, &[])
            .unwrap_err()
            .status(),
        Some(Status::ExtensionUnavailable)
    );
    {
        let mut db =
            Database::open_with_plugins(&path, OpenOptions::default(), &none, &[linked()]).unwrap();
        assert_eq!(db.extension_info("linked_test").unwrap().version, "1.0.0");
    }
    {
        let db =
            SharedDatabase::open_with_plugins(&path, OpenOptions::default(), &none, &[linked()])
                .unwrap();
        assert_eq!(db.list_extensions().unwrap().len(), 1);
    }
    {
        let mut db = Database::open_for_extension_upgrade_with_plugins(
            &path,
            OpenOptions::default(),
            &none,
            &[linked()],
        )
        .unwrap();
        // The descriptor declares no newer version and no recovery hook.
        assert_eq!(
            db.extension_upgrade("linked_test").unwrap_err().status(),
            Some(Status::ExtensionIncompatible)
        );
        assert_eq!(
            db.extension_rebuild("linked_test").unwrap_err().status(),
            Some(Status::ExtensionUnavailable)
        );
    }
    {
        // The maintenance open skips hooks, so it succeeds without the code;
        // the upgrade itself then reports the missing code.
        let mut db =
            Database::open_for_extension_upgrade(&path, OpenOptions::default(), &none).unwrap();
        assert_eq!(
            db.extension_upgrade("linked_test").unwrap_err().status(),
            Some(Status::ExtensionUnavailable)
        );
    }
    let shared = SharedDatabase::open_for_extension_upgrade_with_plugins(
        &path,
        OpenOptions::default(),
        &none,
        &[linked()],
    )
    .unwrap();
    assert!(shared.extension_rebuild("linked_test").is_err());
    drop(shared);

    // A current-format file has no forward migration path; plugins do not
    // change that.
    assert_eq!(
        migrate_database_with_plugins(
            &path,
            dir.0.join("not-migrated.zova"),
            MigrateOptions::default(),
            &none,
            &[linked()],
        )
        .unwrap_err()
        .status(),
        Some(Status::NoMigrationPath)
    );
}

#[test]
fn migration_accepts_linked_plugins() {
    let dir = TempDir::new("migrate");
    let mut fixture =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/format-9.zova");
    if !fixture.is_file() {
        fixture =
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../tests/fixtures/format-9.zova");
    }
    let none = ExtensionOptions::default();
    let destination = dir.0.join("migrated.zova");
    migrate_database_with_plugins(
        &fixture,
        &destination,
        MigrateOptions::default(),
        &none,
        &[linked()],
    )
    .unwrap();
    Database::open_with_plugins(&destination, OpenOptions::default(), &none, &[linked()]).unwrap();

    let mut events = 0;
    migrate_database_with_plugins_and_progress(
        &fixture,
        dir.0.join("progress.zova"),
        MigrateOptions::default(),
        &none,
        &[linked()],
        |_| {
            events += 1;
            ControlFlow::Continue(())
        },
    )
    .unwrap();
    assert!(events > 0);
}

#[test]
fn bundle_trust_functions_report_native_errors() {
    let dir = TempDir::new("trust");
    let trust = dir.0.join("trust.json");
    assert!(verify_extension_bundle(dir.0.join("missing.zovaext"), Some(&trust)).is_err());
    assert!(zova::trust_extension_bundle(dir.0.join("missing.zovaext"), Some(&trust)).is_err());
    assert!(!untrust_extension_bundle("never_trusted", Some(&trust)).unwrap());
    assert_eq!(
        untrust_extension_bundle("bad\0name", Some(&trust))
            .unwrap_err()
            .status(),
        None
    );
}
