use std::path::PathBuf;
use zova::{
    CheckpointMode, Database, JournalMode, OpenOptions, ProgressMember, SharedDatabase, Status,
};

fn temp_path(name: &str) -> PathBuf {
    let mut path = std::env::temp_dir();
    path.push(format!(
        "zova-rust-journal-{}-{}-{name}.zova",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let _ = std::fs::remove_file(&path);
    path
}

fn remove_set(path: &PathBuf) {
    for suffix in ["", "-wal", "-shm", "-journal"] {
        let mut name = path.clone().into_os_string();
        name.push(suffix);
        let _ = std::fs::remove_file(name);
    }
}

#[test]
fn set_journal_mode_switches_and_reports_the_set() {
    let path = temp_path("switch");
    {
        let mut db = Database::create(&path).unwrap();
        let modes = db.journal_modes().unwrap();
        assert_eq!(modes.len(), 1);
        assert_eq!(modes[0].member, ProgressMember::Main);
        assert_eq!(modes[0].journal_mode, JournalMode::Delete);

        let modes = db.set_journal_mode(JournalMode::Wal).unwrap();
        assert_eq!(modes[0].journal_mode, JournalMode::Wal);
        assert_eq!(JournalMode::Wal.name(), "wal");

        let err = db.set_journal_mode(JournalMode::Off).unwrap_err();
        assert_eq!(err.status(), Some(Status::InvalidArgument));

        db.begin().unwrap();
        let err = db.set_journal_mode(JournalMode::Delete).unwrap_err();
        assert_eq!(err.status(), Some(Status::ObjectTransactionActive));
        db.rollback().unwrap();
    }
    {
        // WAL is stored in the file.
        let shared = SharedDatabase::open(&path).unwrap();
        assert_eq!(
            shared.journal_modes().unwrap()[0].journal_mode,
            JournalMode::Wal
        );
        let modes = shared.set_journal_mode(JournalMode::Delete).unwrap();
        assert_eq!(modes[0].journal_mode, JournalMode::Delete);
    }
    {
        let mut reader = Database::open_with_options(
            &path,
            OpenOptions {
                read_only: true,
                ..OpenOptions::default()
            },
        )
        .unwrap();
        let err = reader.set_journal_mode(JournalMode::Wal).unwrap_err();
        assert_eq!(err.status(), Some(Status::ReadOnly));
    }
    remove_set(&path);
}

#[test]
fn checkpoint_reports_wal_frames() {
    let path = temp_path("checkpoint");
    let mut db = Database::create(&path).unwrap();
    let rollback = db.checkpoint(CheckpointMode::default()).unwrap();
    assert_eq!(rollback[0].journal_mode, JournalMode::Delete);
    assert_eq!(rollback[0].wal_frames, 0);

    db.set_journal_mode(JournalMode::Wal).unwrap();
    db.exec("create table rows(x); insert into rows values(1)")
        .unwrap();
    let passive = db.checkpoint(CheckpointMode::Passive).unwrap();
    assert_eq!(passive.len(), 1);
    assert!(!passive[0].busy);
    assert!(passive[0].wal_frames > 0);
    assert_eq!(passive[0].wal_frames, passive[0].checkpointed_frames);

    let truncated = db.checkpoint(CheckpointMode::Truncate).unwrap();
    assert_eq!(truncated[0].wal_frames, 0);
    drop(db);
    remove_set(&path);
}

#[test]
fn in_memory_databases_keep_memory_mode() {
    let mut db = Database::create_memory().unwrap();
    assert_eq!(
        db.journal_modes().unwrap()[0].journal_mode,
        JournalMode::Memory
    );
    let err = db.set_journal_mode(JournalMode::Wal).unwrap_err();
    assert_eq!(err.status(), Some(Status::InvalidArgument));
}
