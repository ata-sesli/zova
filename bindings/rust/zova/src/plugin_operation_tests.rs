//! Native-loader smoke: no new safe binding surface. The runner supplies a
//! trusted C fixture bundle and links the canonical native archive (not the
//! currently loader-disabled generated-C distribution).
use super::*;
use crate::Step;

#[test]
#[ignore = "requires ZOVA_SQL_PLUGIN_BUNDLE and a loader-enabled native archive"]
fn plugin_operations_use_existing_safe_statements_after_reopen() {
    let bundle = CString::new(std::env::var("ZOVA_SQL_PLUGIN_BUNDLE").unwrap()).unwrap();
    let dir = std::env::temp_dir().join(format!("zova-plugin-sql-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let trust = path_to_cstring(&dir.join("trust.json")).unwrap();
    let path = path_to_cstring(&dir.join("operations.zova")).unwrap();
    let mut message = empty_message();
    let trust_request = zova_sys::zova_extension_bundle_request {
        bundle_path: bundle.as_ptr(),
        trust_store_path: trust.as_ptr(),
        out_error_message: &mut message,
    };
    // SAFETY: C strings and the output remain live through this synchronous call.
    assert_eq!(
        unsafe { zova_sys::zova_extension_bundle_trust(&trust_request) },
        zova_sys::ZOVA_OK
    );
    let paths = [bundle.as_ptr()];
    for create in [true, false] {
        let mut handle = ptr::null_mut();
        let request = zova_sys::zova_database_open_extensions_request {
            path: path.as_ptr(),
            flags: if create {
                0
            } else {
                zova_sys::ZOVA_OPEN_READ_ONLY
            },
            busy_timeout_ms: 0,
            extension_bundle_paths: paths.as_ptr(),
            extension_bundle_count: paths.len(),
            trust_store_path: trust.as_ptr(),
            out_db: &mut handle,
            out_error_message: &mut message,
        };
        // SAFETY: all borrowed request inputs outlive open; successful handle
        // ownership is transferred to the ordinary DatabaseInner below.
        let status = unsafe {
            if create {
                zova_sys::zova_database_create_with_extensions(&request)
            } else {
                zova_sys::zova_database_open_with_extensions(&request)
            }
        };
        assert_eq!(
            status,
            zova_sys::ZOVA_OK,
            "{:?}",
            take_message(&mut message)
        );
        let mut db = Database {
            inner: Rc::new(DatabaseInner {
                raw: NonNull::new(handle).unwrap(),
                _not_send_sync: PhantomData,
            }),
        };
        if create {
            db.install_extension("c_test").unwrap();
        }
        let mut scalar = db.prepare("select zova_c_test_echo(?1)").unwrap();
        scalar.bind_i64(1, 42).unwrap();
        assert_eq!(scalar.step().unwrap(), Step::Row);
        assert_eq!(scalar.column_i64(0).unwrap(), 42);
        drop(scalar);
        let mut rows = db
            .prepare("select value from zova_c_test_series(?1) limit 3")
            .unwrap();
        rows.bind_i64(1, 100_000).unwrap();
        for value in 0..3 {
            assert_eq!(rows.step().unwrap(), Step::Row);
            assert_eq!(rows.column_i64(0).unwrap(), value);
        }
        assert_eq!(rows.step().unwrap(), Step::Done);
        drop(rows);
        drop(db);
    }
    std::fs::remove_dir_all(dir).unwrap();
}
