use std::ffi::{CStr, CString};
use std::ptr;

fn temp_path(name: &str) -> String {
    let mut path = std::env::temp_dir();
    path.push(format!(
        "zova-rust-sys-{}-{}-{name}.zova",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let _ = std::fs::remove_file(&path);
    path.to_str().unwrap().to_owned()
}

#[test]
fn abi_version_and_status_names_are_available() {
    unsafe {
        assert_eq!(zova_sys::zova_abi_version_major(), 0);
        assert_eq!(zova_sys::zova_abi_version_minor(), 12);
        assert_eq!(zova_sys::zova_abi_version_patch(), 1);
        assert_eq!(
            CStr::from_ptr(zova_sys::zova_abi_version_string())
                .to_str()
                .unwrap(),
            "0.12.1"
        );
        assert_eq!(
            CStr::from_ptr(zova_sys::zova_status_name(zova_sys::ZOVA_OK))
                .to_str()
                .unwrap(),
            "ZOVA_OK"
        );
    }
}

#[test]
fn raw_create_exec_prepare_step_close_smoke() {
    let path = temp_path("raw");
    let c_path = CString::new(path.as_str()).unwrap();
    let mut db = ptr::null_mut();
    let mut message = zova_sys::zova_message {
        data: ptr::null_mut(),
        len: 0,
    };
    let create = zova_sys::zova_database_open_request {
        path: c_path.as_ptr(),
        out_db: &mut db,
        out_error_message: &mut message,
    };

    unsafe {
        assert_eq!(zova_sys::zova_database_create(&create), zova_sys::ZOVA_OK);
        assert!(!db.is_null());

        let sql = CString::new("select 42").unwrap();
        let mut statement = ptr::null_mut();
        let prepare = zova_sys::zova_database_prepare_request {
            db,
            sql: sql.as_ptr(),
            out_statement: &mut statement,
        };
        assert_eq!(zova_sys::zova_database_prepare(&prepare), zova_sys::ZOVA_OK);
        assert!(!statement.is_null());

        let mut step_result = 0;
        let step = zova_sys::zova_statement_step_request {
            statement,
            out_result: &mut step_result,
        };
        assert_eq!(zova_sys::zova_statement_step(&step), zova_sys::ZOVA_OK);
        assert_eq!(step_result, zova_sys::ZOVA_STEP_ROW);

        let mut value = 0_i64;
        let column = zova_sys::zova_statement_column_int64_request {
            statement,
            index: 0,
            out_value: &mut value,
        };
        assert_eq!(
            zova_sys::zova_statement_column_int64(&column),
            zova_sys::ZOVA_OK
        );
        assert_eq!(value, 42);

        assert_eq!(
            zova_sys::zova_statement_finalize(statement),
            zova_sys::ZOVA_OK
        );
        assert_eq!(zova_sys::zova_database_close(db), zova_sys::ZOVA_OK);
    }

    let _ = std::fs::remove_file(path);
}
