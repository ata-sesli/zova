use std::ops::ControlFlow;
use std::path::PathBuf;
use zova::{
    migrate_database_with_progress, BackupOptions, CompactOptions, Database, ExtensionOptions,
    KvEntry, MigrateOptions, Progress, ProgressMember, ProgressPhase, SharedDatabase, Status,
};

fn fixture_path(name: &str) -> PathBuf {
    let mut path = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let packaged = path.join("tests/fixtures").join(name);
    if packaged.is_file() {
        return packaged;
    }
    path.push("../../../tests/fixtures");
    path.push(name);
    path
}

fn temp_path(name: &str) -> PathBuf {
    let mut path = std::env::temp_dir();
    path.push(format!(
        "zova-rust-progress-{}-{}-{name}.zova",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let _ = std::fs::remove_file(&path);
    path
}

/// A database whose verify pass covers far more items than the 101
/// whole-percent steps Zova forwards.
fn database_with_entries(path: &std::path::Path) -> Database {
    let mut db = Database::create(path).unwrap();
    let keys: Vec<[u8; 8]> = (0u64..1000).map(u64::to_be_bytes).collect();
    let entries: Vec<KvEntry<'_>> = keys
        .iter()
        .map(|key| KvEntry {
            key,
            value: b"progress",
        })
        .collect();
    db.kv_put_many(b"progress", &entries).unwrap();
    db
}

/// Each phase/member group keeps its total, never decreases, and ends at total.
fn assert_well_formed(events: &[Progress]) {
    assert!(!events.is_empty());
    for (index, event) in events.iter().enumerate() {
        assert!(event.done <= event.total, "{event:?}");
        match events.get(index + 1) {
            Some(next) if next.phase == event.phase && next.member == event.member => {
                assert_eq!(next.total, event.total);
                assert!(next.done >= event.done);
            }
            _ => assert_eq!(
                event.done, event.total,
                "group must end complete: {event:?}"
            ),
        }
    }
}

#[test]
fn backup_and_compact_report_progress_and_cancel() {
    let source = temp_path("source");
    let backup = temp_path("backup");
    let compact = temp_path("compact");
    let mut db = database_with_entries(&source);

    let mut cancelled = 0;
    let err = db
        .backup_to_with_progress(&backup, BackupOptions::default(), |_| {
            cancelled += 1;
            ControlFlow::Break(())
        })
        .unwrap_err();
    assert_eq!(err.status(), Some(Status::Interrupted));
    assert_eq!(cancelled, 1);
    assert!(!backup.exists());

    let mut events = Vec::new();
    db.backup_to_with_progress(&backup, BackupOptions::default(), |event| {
        events.push(event);
        ControlFlow::Continue(())
    })
    .unwrap();
    assert_well_formed(&events);
    assert_eq!(events[0].phase, ProgressPhase::Copy);
    assert_eq!(events[0].member, Some(ProgressMember::Main));
    let verify: Vec<_> = events
        .iter()
        .filter(|event| event.phase == ProgressPhase::Verify)
        .collect();
    assert!(verify.len() > 1 && verify.len() <= 102, "{}", verify.len());
    assert!(verify
        .iter()
        .all(|event| event.member.is_none() && event.total >= 1000));

    let mut events = Vec::new();
    db.compact_to_with_progress(&compact, CompactOptions::default(), |event| {
        events.push(event);
        ControlFlow::Continue(())
    })
    .unwrap();
    assert_well_formed(&events);
    assert!(compact.exists());

    for path in [source, backup, compact] {
        let _ = std::fs::remove_file(path);
    }
}

#[test]
fn shared_database_cancels_compact_during_verify() {
    let source = temp_path("shared-source");
    let compact = temp_path("shared-compact");
    drop(database_with_entries(&source));
    let shared = SharedDatabase::open(&source).unwrap();

    let err = shared
        .compact_to_with_progress(&compact, CompactOptions::default(), |event| {
            if event.phase == ProgressPhase::Verify && event.done > 0 {
                ControlFlow::Break(())
            } else {
                ControlFlow::Continue(())
            }
        })
        .unwrap_err();
    assert_eq!(err.status(), Some(Status::Interrupted));
    assert!(!compact.exists());
    shared.exec("select 1").unwrap();

    let mut count = 0;
    shared
        .backup_to_with_progress(&compact, BackupOptions::default(), |_| {
            count += 1;
            ControlFlow::Continue(())
        })
        .unwrap();
    assert!(count > 1);

    drop(shared);
    for path in [source, compact] {
        let _ = std::fs::remove_file(path);
    }
}

#[test]
fn progress_callback_panic_cancels_and_resumes_after_the_call() {
    let source = temp_path("panic-source");
    let backup = temp_path("panic-backup");
    let mut db = database_with_entries(&source);

    let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let _ = db.backup_to_with_progress(&backup, BackupOptions::default(), |_| {
            panic!("progress callback panic")
        });
    }));
    let payload = outcome.unwrap_err();
    assert_eq!(
        payload.downcast_ref::<&str>(),
        Some(&"progress callback panic")
    );
    assert!(!backup.exists());
    db.exec("select 1").unwrap();
    let _ = std::fs::remove_file(source);
}

#[test]
fn migrate_reports_progress_and_cancel_leaves_source_unchanged() {
    let source = temp_path("migrate-source");
    std::fs::copy(fixture_path("format-9.zova"), &source).unwrap();
    let before = std::fs::read(&source).unwrap();
    let destination = temp_path("migrate-destination");

    let err = migrate_database_with_progress(
        &source,
        &destination,
        MigrateOptions::default(),
        &ExtensionOptions::default(),
        |event| {
            if event.phase == ProgressPhase::Migrate {
                ControlFlow::Break(())
            } else {
                ControlFlow::Continue(())
            }
        },
    )
    .unwrap_err();
    assert_eq!(err.status(), Some(Status::Interrupted));
    assert!(!destination.exists());
    assert_eq!(std::fs::read(&source).unwrap(), before);

    let mut events = Vec::new();
    migrate_database_with_progress(
        &source,
        &destination,
        MigrateOptions::default(),
        &ExtensionOptions::default(),
        |event| {
            events.push(event);
            ControlFlow::Continue(())
        },
    )
    .unwrap();
    assert_well_formed(&events);
    for phase in [
        ProgressPhase::Copy,
        ProgressPhase::Migrate,
        ProgressPhase::Verify,
    ] {
        assert!(events.iter().any(|event| event.phase == phase), "{phase:?}");
    }
    let last = events.last().unwrap();
    assert_eq!(last.phase, ProgressPhase::Publish);
    assert_eq!(last.member, None);
    assert!(Database::open(&destination).is_ok());

    for path in [source, destination] {
        let _ = std::fs::remove_file(path);
    }
}
