use std::path::PathBuf;
use zova::{AutoVacuum, Database, ProgressMember, ReclaimOptions, SharedDatabase, Status};

fn temp_path(name: &str) -> PathBuf {
    let mut path = std::env::temp_dir();
    path.push(format!(
        "zova-rust-reclaim-{}-{}-{name}.zova",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let _ = std::fs::remove_file(&path);
    path
}

/// Leaves about 300 free pages in the main database.
fn free_pages(db: &mut Database) {
    db.exec(
        "create table scratch(data blob); \
         with recursive n(i) as (select 1 union all select i + 1 from n where i < 300) \
         insert into scratch select zeroblob(4000) from n; \
         drop table scratch",
    )
    .unwrap();
}

#[test]
fn reclaim_space_releases_free_pages_in_bounded_steps() {
    let path = temp_path("bounded");
    let mut db = Database::create(&path).unwrap();
    free_pages(&mut db);

    let bounded = db
        .reclaim_space(ReclaimOptions {
            max_pages: 100,
            step_pages: 30,
        })
        .unwrap();
    assert_eq!(bounded.len(), 1);
    let first = bounded[0];
    assert_eq!(first.member, ProgressMember::Main);
    assert_eq!(first.auto_vacuum, AutoVacuum::Incremental);
    assert_eq!(first.page_size, 4096);
    assert_eq!(first.pages_released, 100);
    assert!(first.free_pages_left > 0);

    let rest = db.reclaim_space(ReclaimOptions::default()).unwrap();
    assert_eq!(rest[0].pages_released, first.free_pages_left);
    assert_eq!(rest[0].free_pages_left, 0);

    db.begin().unwrap();
    let err = db.reclaim_space(ReclaimOptions::default()).unwrap_err();
    assert_eq!(err.status(), Some(Status::ObjectTransactionActive));
    db.rollback().unwrap();
    drop(db);
    let _ = std::fs::remove_file(&path);
}

#[test]
fn reclaim_space_reports_none_mode_and_works_on_shared_handles() {
    let path = temp_path("none");
    {
        let mut db = Database::create(&path).unwrap();
        db.exec("pragma auto_vacuum = none; vacuum").unwrap();
        free_pages(&mut db);
    }
    let shared = SharedDatabase::open(&path).unwrap();
    let members = shared.reclaim_space(ReclaimOptions::default()).unwrap();
    assert_eq!(members.len(), 1);
    assert_eq!(members[0].auto_vacuum, AutoVacuum::None);
    assert_eq!(members[0].pages_released, 0);
    assert!(members[0].free_pages_left > 0);
    drop(shared);
    let _ = std::fs::remove_file(&path);
}
