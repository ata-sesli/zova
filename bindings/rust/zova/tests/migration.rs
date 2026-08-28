use std::path::PathBuf;
use zova::{
    migrate_database, probe_format, Database, Error, FormatCompatibility, FormatInfo,
    MigrateOptions, Status,
};

fn fixture_path(name: &str) -> PathBuf {
    let mut path = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    path.push("../../../tests/fixtures");
    path.push(name);
    path
}

fn temp_path(name: &str) -> PathBuf {
    let mut path = std::env::temp_dir();
    path.push(format!(
        "zova-rust-migration-{}-{}-{name}.zova",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let _ = std::fs::remove_file(&path);
    path
}

fn read_bytes(path: &std::path::Path) -> Vec<u8> {
    std::fs::read(path).unwrap()
}

/// The format-9 fixture probes as migratable; a fresh database probes as
/// current. Probing never mutates the probed file.
#[test]
fn probe_format_classifies_formats() {
    let fixture = fixture_path("format-9.zova");
    let before = read_bytes(&fixture);

    let info = probe_format(&fixture).unwrap();
    assert_eq!(
        info,
        FormatInfo {
            format_version: 9,
            compatibility: FormatCompatibility::Migratable,
        }
    );
    assert_eq!(info.compatibility.name(), "migratable");

    let current_path = temp_path("probe-current");
    {
        let mut db = Database::create(&current_path).unwrap();
        db.exec("create table t(id integer)").unwrap();
    }
    let info = probe_format(&current_path).unwrap();
    assert_eq!(info.format_version, 11);
    assert_eq!(info.compatibility, FormatCompatibility::Current);
    assert_eq!(info.compatibility.name(), "current");

    assert_eq!(read_bytes(&fixture), before, "probe mutated the fixture");
    let _ = std::fs::remove_file(current_path);
}

/// Probing rejects non-Zova paths with a stable status.
#[test]
fn probe_format_rejects_non_zova_paths() {
    let mut path = std::env::temp_dir();
    path.push(format!(
        "zova-rust-migration-not-zova-{}.txt",
        std::process::id()
    ));
    std::fs::write(&path, b"not a zova file").unwrap();
    let error = probe_format(&path).unwrap_err();
    assert_eq!(error.status(), Some(Status::NotZovaPath));
    let _ = std::fs::remove_file(path);
}

/// Migration copies the fixture forward, preserves public data, reopens as
/// format 11, and leaves the source byte-identical.
#[test]
fn migrate_fixture_forward_and_reopen() {
    let fixture = fixture_path("format-9.zova");
    let source = temp_path("migrate-source");
    let destination = temp_path("migrate-destination");
    std::fs::copy(&fixture, &source).unwrap();
    let source_before = read_bytes(&source);

    migrate_database(&source, &destination, MigrateOptions::default()).unwrap();

    let info = probe_format(&destination).unwrap();
    assert_eq!(info.format_version, 11);
    assert_eq!(info.compatibility, FormatCompatibility::Current);
    assert_eq!(
        read_bytes(&source),
        source_before,
        "migration mutated the source"
    );

    // The migrated database reopens and serves public data unchanged.
    let mut db = Database::open(&destination).unwrap();
    let mut query = db.prepare("select count(*) from user_documents").unwrap();
    assert_eq!(query.step().unwrap(), zova::Step::Row);
    assert_eq!(query.column_i64(0).unwrap(), 3);
    assert_eq!(query.step().unwrap(), zova::Step::Done);
    let mut settings = db
        .prepare("select value from user_settings where key = 'theme'")
        .unwrap();
    assert_eq!(settings.step().unwrap(), zova::Step::Row);
    assert_eq!(
        settings.column_text(0).unwrap(),
        Some("dark;light\nwith\ndelimiter".to_string())
    );
    assert_eq!(settings.step().unwrap(), zova::Step::Done);

    // The migrated database stays fully usable through lifecycle operations.
    db.exec("create table post_migration(id integer primary key, note text)")
        .unwrap();
    db.exec("insert into post_migration(note) values ('hello')")
        .unwrap();

    let _ = std::fs::remove_file(source);
    let _ = std::fs::remove_file(destination);
}

/// The no-verify path migrates without post-copy verification.
#[test]
fn migrate_with_no_verify_flag() {
    let fixture = fixture_path("format-9.zova");
    let source = temp_path("migrate-nv-source");
    let destination = temp_path("migrate-nv-destination");
    std::fs::copy(&fixture, &source).unwrap();

    migrate_database(&source, &destination, MigrateOptions { verify: false }).unwrap();
    let info = probe_format(&destination).unwrap();
    assert_eq!(
        info,
        FormatInfo {
            format_version: 11,
            compatibility: FormatCompatibility::Current,
        }
    );

    let _ = std::fs::remove_file(source);
    let _ = std::fs::remove_file(destination);
}

/// Migration refuses existing destinations and unknown paths with stable
/// statuses, and migrating a current-format database reports that no
/// migration path exists.
#[test]
fn migrate_failure_statuses() {
    let fixture = fixture_path("format-9.zova");
    let source = temp_path("migrate-fail-source");
    let destination = temp_path("migrate-fail-destination");
    std::fs::copy(&fixture, &source).unwrap();
    std::fs::write(&destination, b"occupied").unwrap();

    let error = migrate_database(&source, &destination, MigrateOptions::default()).unwrap_err();
    assert_eq!(error.status(), Some(Status::DestinationExists));

    let missing = temp_path("migrate-fail-missing");
    let error = migrate_database(&missing, &destination, MigrateOptions::default()).unwrap_err();
    assert!(matches!(error, Error::Zova { .. }));

    let _ = std::fs::remove_file(source);
    let _ = std::fs::remove_file(destination);
}

/// Migrating an already-current database deterministically reports
/// `NoMigrationPath` instead of copying anything.
#[test]
fn migrate_current_format_reports_no_migration_path() {
    let current = temp_path("migrate-current-source");
    let destination = temp_path("migrate-current-destination");
    {
        let mut db = Database::create(&current).unwrap();
        db.exec("create table t(id integer)").unwrap();
    }

    let error = migrate_database(&current, &destination, MigrateOptions::default()).unwrap_err();
    assert_eq!(error.status(), Some(Status::NoMigrationPath));
    assert_eq!(error.status().unwrap().name(), "ZOVA_NO_MIGRATION_PATH");
    assert!(
        !destination.exists(),
        "current-format migration published output"
    );

    let _ = std::fs::remove_file(current);
}
