use std::path::PathBuf;
use zova::{
    CheckpointMode, CommitProtocol, Database, JournalMode, OpenOptions, ProgressMember,
    SharedDatabase, Status,
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

/// Runs against any native library: one built without `-Dexperimental-cwal`
/// refuses both protocols, and a CWAL build switches a WAL set and back.
#[test]
fn set_commit_protocol_switches_a_wal_set_or_reports_an_unsupported_library() {
    assert_eq!(CommitProtocol::default(), CommitProtocol::None);
    assert_eq!(CommitProtocol::None.name(), "none");
    assert_eq!(CommitProtocol::Cwal.name(), "cwal");
    assert_eq!(
        Status::from_raw(zova_sys::ZOVA_MEMBER_OWNED),
        Status::MemberOwned
    );
    for status in [
        Status::CommitSetBroken,
        Status::CommitSetNeedsRepair,
        Status::MemberOwned,
    ] {
        assert_eq!(Status::from_raw(status.raw()), status);
    }
    assert_eq!(Status::CommitSetBroken.name(), "ZOVA_COMMIT_SET_BROKEN");
    assert_eq!(
        Status::CommitSetNeedsRepair.name(),
        "ZOVA_COMMIT_SET_NEEDS_REPAIR"
    );

    let dir = temp_path("commit-protocol-dir");
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("set.zova");
    {
        let mut db = Database::create(&path).unwrap();
        match db.set_commit_protocol(CommitProtocol::Cwal) {
            Err(err) if err.status() == Some(Status::UnsupportedZovaVersion) => {
                let err = db.set_commit_protocol(CommitProtocol::None).unwrap_err();
                assert_eq!(err.status(), Some(Status::UnsupportedZovaVersion));
                drop(db);
                std::fs::remove_dir_all(&dir).unwrap();
                return;
            }
            // CWAL needs every member in WAL mode.
            Err(err) => assert_eq!(err.status(), Some(Status::Misuse)),
            Ok(()) => panic!("a rollback-journal set switched to CWAL"),
        }
        db.set_commit_protocol(CommitProtocol::None).unwrap();
        db.set_journal_mode(JournalMode::Wal).unwrap();
        db.exec("create table rows(x); insert into rows values (1)")
            .unwrap();

        db.begin().unwrap();
        let err = db.set_commit_protocol(CommitProtocol::Cwal).unwrap_err();
        assert_eq!(err.status(), Some(Status::ObjectTransactionActive));
        db.rollback().unwrap();

        db.set_commit_protocol(CommitProtocol::Cwal).unwrap();
        let err = Database::open(&path).unwrap_err();
        assert_eq!(err.status(), Some(Status::Busy));
        {
            let reader = Database::open_with_options(
                &path,
                OpenOptions {
                    read_only: true,
                    busy_timeout_ms: 0,
                },
            )
            .unwrap();
            drop(reader);
        }
        db.exec("insert into rows values (2)").unwrap();
        db.set_commit_protocol(CommitProtocol::None).unwrap();
    }
    {
        // A plain set again: two read-write handles open side by side.
        let shared = SharedDatabase::open(&path).unwrap();
        let mut second = Database::open(&path).unwrap();
        second.exec("insert into rows values (3)").unwrap();
        drop(second);
        shared.set_commit_protocol(CommitProtocol::Cwal).unwrap();
        shared.set_commit_protocol(CommitProtocol::None).unwrap();
    }
    std::fs::remove_dir_all(&dir).unwrap();
}
