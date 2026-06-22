use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int, c_void};
use std::ptr;
use zova::{object_chunk_id, object_id, Database, ObjectChunkId, ObjectId, Status, Step};

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

fn temp_path(name: &str) -> String {
    let mut path = std::env::temp_dir();
    path.push(format!(
        "zova-rust-objects-{}-{}-{name}.zova",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let _ = std::fs::remove_file(&path);
    path.to_str().unwrap().to_owned()
}

fn fixture_bytes(len: usize) -> Vec<u8> {
    (0..len)
        .map(|index| ((index * 31 + index / 7) % 251) as u8)
        .collect()
}

fn create_plain_sqlite(path: &str) {
    let c_path = CString::new(path).unwrap();
    let mut db = ptr::null_mut();
    unsafe {
        assert_eq!(sqlite3_open(c_path.as_ptr(), &mut db), 0);
        let sql = CString::new(
            "create table rows(id integer primary key, value text);
             insert into rows(value) values ('before conversion');",
        )
        .unwrap();
        let mut errmsg = ptr::null_mut();
        let rc = sqlite3_exec(db, sql.as_ptr(), None, ptr::null_mut(), &mut errmsg);
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
        assert_eq!(sqlite3_close(db), 0);
    }
}

#[test]
fn object_id_helpers_are_sha256_identities() {
    let empty = object_id(b"").unwrap();
    assert_eq!(
        empty.as_ref(),
        &[
            0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14, 0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f,
            0xb9, 0x24, 0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c, 0xa4, 0x95, 0x99, 0x1b,
            0x78, 0x52, 0xb8, 0x55,
        ]
    );

    let chunk = object_chunk_id(b"abc").unwrap();
    assert_eq!(
        chunk.as_ref(),
        &[
            0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea, 0x41, 0x41, 0x40, 0xde, 0x5d, 0xae,
            0x22, 0x23, 0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c, 0xb4, 0x10, 0xff, 0x61,
            0xf2, 0x00, 0x15, 0xad,
        ]
    );
}

#[test]
fn put_get_range_manifest_chunks_and_delete_round_trip() {
    let path = temp_path("round-trip");
    let mut db = Database::create(&path).unwrap();

    let cases = [
        Vec::new(),
        b"hello object".to_vec(),
        b"binary\0with\0nul".to_vec(),
        fixture_bytes(140_000),
    ];

    for bytes in cases {
        let expected_id = object_id(&bytes).unwrap();
        let id = db.put_object(&bytes).unwrap();
        assert_eq!(id, expected_id);
        assert!(db.has_object(id).unwrap());
        assert_eq!(db.object_size(id).unwrap(), bytes.len() as u64);
        assert_eq!(db.get_object(id).unwrap(), bytes);

        let mut full = vec![0; bytes.len()];
        assert_eq!(db.read_object_range(id, 0, &mut full).unwrap(), bytes.len());
        assert_eq!(full, bytes);

        let mut empty = [];
        assert_eq!(
            db.read_object_range(id, bytes.len() as u64, &mut empty)
                .unwrap(),
            0
        );

        if !bytes.is_empty() {
            let start = bytes.len().min(7);
            let mut partial = vec![0; bytes.len().saturating_sub(start).min(41)];
            let copied = db
                .read_object_range(id, start as u64, &mut partial)
                .unwrap();
            assert_eq!(copied, partial.len());
            assert_eq!(&partial, &bytes[start..start + partial.len()]);
        }

        let manifest = db.object_manifest(id).unwrap();
        assert_eq!(manifest.object_id, id);
        assert_eq!(manifest.size_bytes, bytes.len() as u64);
        assert_eq!(manifest.chunk_count, manifest.chunks.len() as u64);
        assert_eq!(manifest.chunker, "fastcdc-v1");
        assert_eq!(db.object_chunk_count(id).unwrap(), manifest.chunk_count);
        for chunk in &manifest.chunks {
            let chunk_bytes = db.get_object_chunk(chunk.hash).unwrap();
            assert_eq!(chunk_bytes.len() as u64, chunk.size_bytes);
            assert!(db.has_object_chunk(chunk.hash).unwrap());
        }

        db.delete_object(id).unwrap();
        assert!(!db.has_object(id).unwrap());
        assert_eq!(
            db.get_object(id).unwrap_err().status(),
            Some(Status::ObjectNotFound)
        );
    }

    let _ = std::fs::remove_file(path);
}

#[test]
fn loose_chunks_can_be_assembled_into_objects() {
    let path = temp_path("assembly");
    let mut db = Database::create(&path).unwrap();
    let bytes = fixture_bytes(96_000);
    let source_id = db.put_object(&bytes).unwrap();
    let manifest = db.object_manifest(source_id).unwrap();
    let mut chunks = manifest.chunks.clone();

    for chunk in &chunks {
        let data = db.get_object_chunk(chunk.hash).unwrap();
        db.put_object_chunk(chunk.hash, &data).unwrap();
    }

    db.delete_object(source_id).unwrap();
    assert_eq!(
        db.assemble_object_from_chunks(source_id, bytes.len() as u64, &chunks)
            .unwrap_err()
            .status(),
        Some(Status::ObjectChunkNotFound)
    );

    for chunk in &chunks {
        let start = chunk.offset as usize;
        let end = start + chunk.size_bytes as usize;
        db.put_object_chunk(chunk.hash, &bytes[start..end]).unwrap();
    }

    chunks.reverse();
    db.assemble_object_from_chunks(source_id, bytes.len() as u64, &chunks)
        .unwrap();
    assert_eq!(db.get_object(source_id).unwrap(), bytes);

    let first = chunks[0].hash;
    assert!(!db.delete_object_chunk(first).unwrap());
    db.delete_object(source_id).unwrap();
    assert!(!db.has_object_chunk(first).unwrap());

    let loose = b"loose chunk";
    let loose_hash = object_chunk_id(loose).unwrap();
    db.put_object_chunk(loose_hash, loose).unwrap();
    assert!(db.delete_object_chunk(loose_hash).unwrap());
    let _ = std::fs::remove_file(path);
}

#[test]
fn object_writer_streams_finishes_cancels_and_drops() {
    let path = temp_path("writer");
    let mut db = Database::create(&path).unwrap();

    let bytes = fixture_bytes(180_000);
    let mut writer = db.object_writer().unwrap();
    for chunk in bytes.chunks(333) {
        writer.write(chunk).unwrap();
    }
    let id = writer.finish().unwrap();
    assert_eq!(id, object_id(&bytes).unwrap());
    assert_eq!(db.get_object(id).unwrap(), bytes);

    let mut cancel_writer = db.object_writer().unwrap();
    cancel_writer.write(b"temporary").unwrap();
    cancel_writer.cancel().unwrap();
    let temporary_id = object_id(b"temporary").unwrap();
    assert!(!db.has_object(temporary_id).unwrap());

    let drop_id = object_id(b"drop cleanup").unwrap();
    {
        let mut drop_writer = db.object_writer().unwrap();
        drop_writer.write(b"drop cleanup").unwrap();
    }
    assert!(!db.has_object(drop_id).unwrap());
    let _ = std::fs::remove_file(path);
}

#[test]
fn object_ids_can_live_in_user_sql_rows() {
    let path = temp_path("records");
    let mut db = Database::create(&path).unwrap();
    db.exec("create table attachments(id integer primary key, object_id blob not null)")
        .unwrap();
    let id = db.put_object(b"stored through Rust").unwrap();

    let mut insert = db
        .prepare("insert into attachments(object_id) values (?1)")
        .unwrap();
    insert.bind_blob(1, id.as_ref()).unwrap();
    assert_eq!(insert.step().unwrap(), Step::Done);
    drop(insert);

    let mut select = db
        .prepare("select object_id from attachments where id = 1")
        .unwrap();
    assert_eq!(select.step().unwrap(), Step::Row);
    let stored = select.column_blob(0).unwrap().unwrap();
    let stored_id = ObjectId::try_from(stored.as_slice()).unwrap();
    drop(select);
    assert_eq!(db.get_object(stored_id).unwrap(), b"stored through Rust");
    let _ = std::fs::remove_file(path);
}

#[test]
fn objects_work_after_sqlite_conversion() {
    let source_db = temp_path("source").replace(".zova", ".db");
    let dest = temp_path("converted");
    let _ = std::fs::remove_file(&source_db);
    create_plain_sqlite(&source_db);
    Database::convert_sqlite_to_zova(&source_db, &dest).unwrap();

    let mut db = Database::open(&dest).unwrap();
    let id = db.put_object(b"after conversion").unwrap();
    assert_eq!(db.get_object(id).unwrap(), b"after conversion");
    let mut rows = db.prepare("select count(*) from rows").unwrap();
    assert_eq!(rows.step().unwrap(), Step::Row);
    assert_eq!(rows.column_i64(0).unwrap(), 1);

    let _ = std::fs::remove_file(source_db);
    let _ = std::fs::remove_file(dest);
}

#[test]
fn object_id_types_are_copy_hashable_and_from_arrays() {
    use std::collections::HashSet;

    let id = ObjectId::from([1_u8; 32]);
    let chunk = ObjectChunkId::from([2_u8; 32]);
    assert_eq!(id.as_ref(), &[1_u8; 32]);
    assert_eq!(chunk.as_ref(), &[2_u8; 32]);

    let mut ids = HashSet::new();
    ids.insert(id);
    assert!(ids.contains(&id));
}
