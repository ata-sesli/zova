use std::ffi::{CStr, CString};
use std::os::raw::c_void;
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

fn f32_values(values: &[f32]) -> zova_sys::zova_vector_values {
    zova_sys::zova_vector_values {
        element_type: zova_sys::ZOVA_VECTOR_ELEMENT_TYPE_F32,
        f32_values: if values.is_empty() {
            ptr::null()
        } else {
            values.as_ptr()
        },
        f16_values: ptr::null(),
        i8_values: ptr::null(),
        values_len: values.len(),
    }
}

#[test]
fn abi_version_and_status_names_are_available() {
    unsafe {
        assert_eq!(zova_sys::zova_abi_version_major(), 0);
        assert_eq!(zova_sys::zova_abi_version_minor(), 22);
        assert_eq!(zova_sys::zova_abi_version_patch(), 0);
        assert_eq!(
            CStr::from_ptr(zova_sys::zova_abi_version_string())
                .to_str()
                .unwrap(),
            "0.22.0"
        );
        assert_eq!(
            CStr::from_ptr(zova_sys::zova_status_name(zova_sys::ZOVA_OK))
                .to_str()
                .unwrap(),
            "ZOVA_OK"
        );
        assert_eq!(zova_sys::ZOVA_GRAPH_EXISTS, 80);
        assert_eq!(zova_sys::ZOVA_GRAPH_INVALID, 84);
        assert_eq!(zova_sys::ZOVA_EXTENSION_UNAVAILABLE, 94);
        assert_eq!(
            CStr::from_ptr(zova_sys::zova_status_name(zova_sys::ZOVA_GRAPH_INVALID))
                .to_str()
                .unwrap(),
            "ZOVA_GRAPH_INVALID"
        );
        assert_eq!(
            CStr::from_ptr(zova_sys::zova_status_name(
                zova_sys::ZOVA_EXTENSION_UNAVAILABLE
            ))
            .to_str()
            .unwrap(),
            "ZOVA_EXTENSION_UNAVAILABLE"
        );
    }
}

#[test]
fn raw_extension_lifecycle_smoke() {
    let path = temp_path("extensions");
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

        let missing = CString::new("missing_ext").unwrap();
        let missing_request = zova_sys::zova_database_extension_request {
            db,
            name: missing.as_ptr(),
        };
        assert_eq!(
            zova_sys::zova_database_extension_install(&missing_request),
            zova_sys::ZOVA_EXTENSION_NOT_FOUND
        );

        let trgm = CString::new("trgm").unwrap();
        let request = zova_sys::zova_database_extension_request {
            db,
            name: trgm.as_ptr(),
        };
        assert_eq!(
            zova_sys::zova_database_extension_install(&request),
            zova_sys::ZOVA_OK
        );
        assert_eq!(
            zova_sys::zova_database_extension_install(&request),
            zova_sys::ZOVA_EXTENSION_EXISTS
        );

        let mut info = zova_sys::zova_extension_info {
            name: ptr::null_mut(),
            name_len: 0,
            version: ptr::null_mut(),
            version_len: 0,
            storage_prefix: ptr::null_mut(),
            storage_prefix_len: 0,
            zova_abi_min: ptr::null_mut(),
            zova_abi_min_len: 0,
            capabilities: ptr::null_mut(),
            capabilities_len: 0,
            required: 0,
            installed_at_unix: 0,
            manifest_json: ptr::null_mut(),
            manifest_json_len: 0,
        };
        let info_request = zova_sys::zova_database_extension_info_request {
            db,
            name: trgm.as_ptr(),
            out_info: &mut info,
        };
        assert_eq!(
            zova_sys::zova_database_extension_info(&info_request),
            zova_sys::ZOVA_OK
        );
        assert_eq!(CStr::from_ptr(info.name).to_str().unwrap(), "trgm");
        assert_eq!(
            CStr::from_ptr(info.storage_prefix).to_str().unwrap(),
            "_zova_ext_trgm_"
        );
        assert_eq!(info.required, 1);
        assert!(info.installed_at_unix > 0);
        zova_sys::zova_extension_info_free(&mut info);

        let mut list = zova_sys::zova_extension_list {
            items: ptr::null_mut(),
            len: 0,
        };
        let list_request = zova_sys::zova_database_extension_list_request {
            db,
            out_list: &mut list,
        };
        assert_eq!(
            zova_sys::zova_database_extension_list(&list_request),
            zova_sys::ZOVA_OK
        );
        assert_eq!(list.len, 1);
        zova_sys::zova_extension_list_free(&mut list);

        assert_eq!(
            zova_sys::zova_database_extension_check(&request),
            zova_sys::ZOVA_OK
        );
        let check_all = zova_sys::zova_database_simple_request { db };
        assert_eq!(
            zova_sys::zova_database_extension_check_all(&check_all),
            zova_sys::ZOVA_OK
        );
        assert_eq!(
            zova_sys::zova_database_extension_drop(&request),
            zova_sys::ZOVA_OK
        );
        assert_eq!(
            zova_sys::zova_database_extension_info(&info_request),
            zova_sys::ZOVA_EXTENSION_NOT_FOUND
        );
        zova_sys::zova_extension_info_free(ptr::null_mut());
        zova_sys::zova_extension_list_free(ptr::null_mut());
        assert_eq!(zova_sys::zova_database_close(db), zova_sys::ZOVA_OK);
    }

    let _ = std::fs::remove_file(path);
}

#[test]
fn raw_extension_bundle_ffi_surface_smoke() {
    let path = temp_path("external-extension-zero-bundles");
    let c_path = CString::new(path.as_str()).unwrap();
    let mut db = ptr::null_mut();
    let mut message = zova_sys::zova_message {
        data: ptr::null_mut(),
        len: 0,
    };

    unsafe {
        assert_eq!(
            zova_sys::zova_extension_bundle_verify(ptr::null()),
            zova_sys::ZOVA_INVALID_ARGUMENT
        );
        assert_eq!(
            zova_sys::zova_extension_bundle_trust(ptr::null()),
            zova_sys::ZOVA_INVALID_ARGUMENT
        );
        assert_eq!(
            zova_sys::zova_extension_bundle_untrust(ptr::null()),
            zova_sys::ZOVA_INVALID_ARGUMENT
        );

        let create = zova_sys::zova_database_open_extensions_request {
            path: c_path.as_ptr(),
            flags: 0,
            busy_timeout_ms: 0,
            extension_bundle_paths: ptr::null(),
            extension_bundle_count: 0,
            trust_store_path: ptr::null(),
            out_db: &mut db,
            out_error_message: &mut message,
        };
        assert_eq!(
            zova_sys::zova_database_create_with_extensions(&create),
            zova_sys::ZOVA_OK
        );
        assert!(!db.is_null());
        assert_eq!(zova_sys::zova_database_close(db), zova_sys::ZOVA_OK);
        db = ptr::null_mut();

        let open = zova_sys::zova_database_open_extensions_request {
            path: c_path.as_ptr(),
            flags: 0,
            busy_timeout_ms: 0,
            extension_bundle_paths: ptr::null(),
            extension_bundle_count: 0,
            trust_store_path: ptr::null(),
            out_db: &mut db,
            out_error_message: &mut message,
        };
        assert_eq!(
            zova_sys::zova_database_open_with_extensions(&open),
            zova_sys::ZOVA_OK
        );
        assert!(!db.is_null());
        assert_eq!(zova_sys::zova_database_close(db), zova_sys::ZOVA_OK);
        zova_sys::zova_message_free(&mut message);
    }

    let _ = std::fs::remove_file(path);
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

#[repr(C)]
struct SqlCallbackState {
    offset: i64,
    destroyed: usize,
}

unsafe extern "C" fn sql_add_offset(
    user_data: *mut c_void,
    call: *const zova_sys::zova_sql_function_call,
    out_result: *mut zova_sys::zova_sql_result,
) {
    let state = &*(user_data as *const SqlCallbackState);
    let call = &*call;
    assert_eq!(call.argc, 1);
    let arg = &*call.argv;
    assert_eq!(arg.value_type, zova_sys::ZOVA_SQL_VALUE_INTEGER);
    (*out_result).result_type = zova_sys::ZOVA_SQL_RESULT_INTEGER;
    (*out_result).int64_value = arg.int64_value + state.offset;
    (*out_result).double_value = 0.0;
    (*out_result).data = ptr::null();
    (*out_result).data_len = 0;
    (*out_result).error_message = ptr::null();
    (*out_result).error_message_len = 0;
}

unsafe extern "C" fn sql_destroy(user_data: *mut c_void) {
    let state = &mut *(user_data as *mut SqlCallbackState);
    state.destroyed += 1;
}

unsafe extern "C" fn rust_sql_error(
    _user_data: *mut c_void,
    _call: *const zova_sys::zova_sql_function_call,
    out_result: *mut zova_sys::zova_sql_result,
) {
    static MESSAGE: &[u8] = b"rust callback failed";
    (*out_result).result_type = zova_sys::ZOVA_SQL_RESULT_ERROR;
    (*out_result).int64_value = 0;
    (*out_result).double_value = 0.0;
    (*out_result).data = ptr::null();
    (*out_result).data_len = 0;
    (*out_result).error_message = MESSAGE.as_ptr().cast();
    (*out_result).error_message_len = MESSAGE.len();
}

#[test]
fn raw_scalar_sql_function_registration_smoke() {
    let path = temp_path("sql-fn");
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
    let mut state = SqlCallbackState {
        offset: 9,
        destroyed: 0,
    };

    unsafe {
        assert_eq!(zova_sys::zova_database_create(&create), zova_sys::ZOVA_OK);
        assert!(!db.is_null());

        let name = CString::new("rust_add_offset").unwrap();
        let register = zova_sys::zova_sql_function_register_request {
            db,
            name: name.as_ptr(),
            arity: 1,
            flags: zova_sys::ZOVA_SQL_FUNCTION_DETERMINISTIC
                | zova_sys::ZOVA_SQL_FUNCTION_DIRECT_ONLY
                | zova_sys::ZOVA_SQL_FUNCTION_INNOCUOUS,
            user_data: &mut state as *mut SqlCallbackState as *mut c_void,
            callback: Some(sql_add_offset),
            destroy: Some(sql_destroy),
        };
        assert_eq!(
            zova_sys::zova_database_register_function(&register),
            zova_sys::ZOVA_OK
        );

        let sql = CString::new("select rust_add_offset(33)").unwrap();
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
        assert_eq!(state.destroyed, 0);
        assert_eq!(zova_sys::zova_database_close(db), zova_sys::ZOVA_OK);
        assert_eq!(state.destroyed, 1);
    }

    let _ = std::fs::remove_file(path);
}

#[test]
fn raw_scalar_sql_function_callback_errors_propagate() {
    let path = temp_path("sql-fn-error");
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

        let name = CString::new("rust_fail").unwrap();
        let register = zova_sys::zova_sql_function_register_request {
            db,
            name: name.as_ptr(),
            arity: 0,
            flags: 0,
            user_data: ptr::null_mut(),
            callback: Some(rust_sql_error),
            destroy: None,
        };
        assert_eq!(
            zova_sys::zova_database_register_function(&register),
            zova_sys::ZOVA_OK
        );

        let sql = CString::new("select rust_fail()").unwrap();
        let exec = zova_sys::zova_database_exec_request {
            db,
            sql: sql.as_ptr(),
        };
        assert_eq!(
            zova_sys::zova_database_exec(&exec),
            zova_sys::ZOVA_SQLITE_ERROR
        );
        let last_error = CStr::from_ptr(zova_sys::zova_database_last_error_message(db))
            .to_str()
            .unwrap();
        assert!(last_error.contains("rust callback failed"));

        assert_eq!(zova_sys::zova_database_close(db), zova_sys::ZOVA_OK);
    }

    let _ = std::fs::remove_file(path);
}

#[test]
fn raw_savepoint_smoke() {
    let path = temp_path("savepoints");
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
        let create_table =
            CString::new("create table records(id integer primary key, body text)").unwrap();
        let exec = zova_sys::zova_database_exec_request {
            db,
            sql: create_table.as_ptr(),
        };
        assert_eq!(zova_sys::zova_database_exec(&exec), zova_sys::ZOVA_OK);

        let simple = zova_sys::zova_database_simple_request { db };
        assert_eq!(
            zova_sys::zova_database_begin_immediate(&simple),
            zova_sys::ZOVA_OK
        );

        let sp_name = CString::new("sp_one").unwrap();
        let savepoint = zova_sys::zova_database_savepoint_request {
            db,
            name: sp_name.as_ptr(),
        };
        assert_eq!(
            zova_sys::zova_database_savepoint(&savepoint),
            zova_sys::ZOVA_OK
        );

        let insert = CString::new("insert into records(body) values ('rolled back')").unwrap();
        let exec = zova_sys::zova_database_exec_request {
            db,
            sql: insert.as_ptr(),
        };
        assert_eq!(zova_sys::zova_database_exec(&exec), zova_sys::ZOVA_OK);
        assert_eq!(
            zova_sys::zova_database_rollback_to_savepoint(&savepoint),
            zova_sys::ZOVA_OK
        );
        assert_eq!(
            zova_sys::zova_database_release_savepoint(&savepoint),
            zova_sys::ZOVA_OK
        );

        let bad_name = CString::new("bad name").unwrap();
        let bad = zova_sys::zova_database_savepoint_request {
            db,
            name: bad_name.as_ptr(),
        };
        assert_eq!(
            zova_sys::zova_database_savepoint(&bad),
            zova_sys::ZOVA_INVALID_ARGUMENT
        );

        let missing_name = CString::new("missing_sp").unwrap();
        let missing = zova_sys::zova_database_savepoint_request {
            db,
            name: missing_name.as_ptr(),
        };
        assert_eq!(
            zova_sys::zova_database_release_savepoint(&missing),
            zova_sys::ZOVA_SQLITE_ERROR
        );
        let last_error = CStr::from_ptr(zova_sys::zova_database_last_error_message(db))
            .to_string_lossy()
            .into_owned();
        assert!(last_error.contains("no such savepoint"));

        assert_eq!(zova_sys::zova_database_commit(&simple), zova_sys::ZOVA_OK);
        assert_eq!(zova_sys::zova_database_close(db), zova_sys::ZOVA_OK);
    }

    let _ = std::fs::remove_file(path);
}

#[test]
fn raw_backup_compact_and_restore_smoke() {
    let path = temp_path("ops-source");
    let backup_path = temp_path("ops-backup");
    let compact_path = temp_path("ops-compact");
    let restored_path = temp_path("ops-restored");
    let c_path = CString::new(path.as_str()).unwrap();
    let c_backup = CString::new(backup_path.as_str()).unwrap();
    let c_compact = CString::new(compact_path.as_str()).unwrap();
    let c_restored = CString::new(restored_path.as_str()).unwrap();
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
        let sql = CString::new(
            "create table records(id integer primary key, body text not null);
             insert into records(body) values ('kept');",
        )
        .unwrap();
        let exec = zova_sys::zova_database_exec_request {
            db,
            sql: sql.as_ptr(),
        };
        assert_eq!(zova_sys::zova_database_exec(&exec), zova_sys::ZOVA_OK);

        let backup = zova_sys::zova_database_backup_request {
            db,
            destination_path: c_backup.as_ptr(),
            flags: zova_sys::ZOVA_BACKUP_NO_VERIFY,
        };
        assert_eq!(zova_sys::zova_database_backup(&backup), zova_sys::ZOVA_OK);

        let compact = zova_sys::zova_database_compact_request {
            db,
            destination_path: c_compact.as_ptr(),
            flags: zova_sys::ZOVA_COMPACT_NO_VERIFY,
        };
        assert_eq!(zova_sys::zova_database_compact(&compact), zova_sys::ZOVA_OK);

        let restore = zova_sys::zova_database_restore_request {
            source_path: c_backup.as_ptr(),
            destination_path: c_restored.as_ptr(),
            flags: zova_sys::ZOVA_RESTORE_NO_VERIFY,
            out_error_message: &mut message,
        };
        assert_eq!(zova_sys::zova_database_restore(&restore), zova_sys::ZOVA_OK);
        assert_eq!(zova_sys::zova_database_close(db), zova_sys::ZOVA_OK);
    }

    assert!(std::path::Path::new(&backup_path).exists());
    assert!(std::path::Path::new(&compact_path).exists());
    assert!(std::path::Path::new(&restored_path).exists());
    let _ = std::fs::remove_file(path);
    let _ = std::fs::remove_file(backup_path);
    let _ = std::fs::remove_file(compact_path);
    let _ = std::fs::remove_file(restored_path);
}

#[test]
fn raw_object_manifest_and_writer_smoke() {
    let path = temp_path("objects");
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

        let bytes = b"raw object";
        let mut expected = zova_sys::zova_object_id { bytes: [0; 32] };
        assert_eq!(
            zova_sys::zova_object_id_from_bytes(bytes.as_ptr(), bytes.len(), &mut expected),
            zova_sys::ZOVA_OK
        );

        let mut id = zova_sys::zova_object_id { bytes: [0; 32] };
        let put = zova_sys::zova_object_put_request {
            db,
            data: bytes.as_ptr(),
            len: bytes.len(),
            out_id: &mut id,
        };
        assert_eq!(zova_sys::zova_object_put(&put), zova_sys::ZOVA_OK);
        assert_eq!(id, expected);

        let mut buffer = zova_sys::zova_buffer {
            data: ptr::null_mut(),
            len: 0,
        };
        let get = zova_sys::zova_object_get_request {
            db,
            id,
            out_buffer: &mut buffer,
        };
        assert_eq!(zova_sys::zova_object_get(&get), zova_sys::ZOVA_OK);
        assert_eq!(std::slice::from_raw_parts(buffer.data, buffer.len), bytes);
        zova_sys::zova_buffer_free(&mut buffer);

        let mut manifest = zova_sys::zova_object_manifest {
            object_id: zova_sys::zova_object_id { bytes: [0; 32] },
            size_bytes: 0,
            chunk_count: 0,
            chunker: ptr::null(),
            chunks: ptr::null_mut(),
            chunks_len: 0,
        };
        let manifest_get = zova_sys::zova_object_manifest_get_request {
            db,
            id,
            out_manifest: &mut manifest,
        };
        assert_eq!(
            zova_sys::zova_object_manifest_get(&manifest_get),
            zova_sys::ZOVA_OK
        );
        assert_eq!(manifest.object_id, id);
        assert!(manifest.chunks_len > 0);
        zova_sys::zova_object_manifest_free(&mut manifest);

        let mut writer = ptr::null_mut();
        let create_writer = zova_sys::zova_object_writer_create_request {
            db,
            out_writer: &mut writer,
        };
        assert_eq!(
            zova_sys::zova_object_writer_create(&create_writer),
            zova_sys::ZOVA_OK
        );
        let part = b"streamed";
        let write = zova_sys::zova_object_writer_write_request {
            writer,
            data: part.as_ptr(),
            len: part.len(),
        };
        assert_eq!(
            zova_sys::zova_object_writer_write(&write),
            zova_sys::ZOVA_OK
        );
        let mut writer_id = zova_sys::zova_object_id { bytes: [0; 32] };
        let finish = zova_sys::zova_object_writer_finish_request {
            writer,
            out_id: &mut writer_id,
        };
        assert_eq!(
            zova_sys::zova_object_writer_finish(&finish),
            zova_sys::ZOVA_OK
        );
        assert_eq!(
            zova_sys::zova_object_writer_destroy(writer),
            zova_sys::ZOVA_OK
        );

        assert_eq!(zova_sys::zova_database_close(db), zova_sys::ZOVA_OK);
    }

    let _ = std::fs::remove_file(path);
}

#[test]
fn raw_vector_collection_crud_batch_and_search_smoke() {
    let path = temp_path("vectors");
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

        let collection = CString::new("chunks").unwrap();
        let create_collection = zova_sys::zova_vector_collection_create_request {
            db,
            name: collection.as_ptr(),
            options: zova_sys::zova_vector_collection_options {
                dimensions: 2,
                metric: zova_sys::ZOVA_VECTOR_METRIC_L2,
                element_type: zova_sys::ZOVA_VECTOR_ELEMENT_TYPE_F32,
            },
        };
        assert_eq!(
            zova_sys::zova_vector_collection_create(&create_collection),
            zova_sys::ZOVA_OK
        );

        let mut exists = 0;
        let exists_request = zova_sys::zova_vector_collection_exists_request {
            db,
            name: collection.as_ptr(),
            out_exists: &mut exists,
        };
        assert_eq!(
            zova_sys::zova_vector_collection_exists(&exists_request),
            zova_sys::ZOVA_OK
        );
        assert_eq!(exists, 1);

        let source_id = CString::new("source").unwrap();
        let near_id = CString::new("near").unwrap();
        let far_id = CString::new("far").unwrap();
        let near_values = [1.0_f32, 0.0];
        let far_values = [3.0_f32, 4.0];
        let source_values = [0.0_f32, 0.0];
        let batch = [
            zova_sys::zova_vector_input {
                id: source_id.as_ptr(),
                values: f32_values(&source_values),
            },
            zova_sys::zova_vector_input {
                id: near_id.as_ptr(),
                values: f32_values(&near_values),
            },
            zova_sys::zova_vector_input {
                id: far_id.as_ptr(),
                values: f32_values(&far_values),
            },
        ];
        let put_many = zova_sys::zova_vector_put_many_request {
            db,
            collection_name: collection.as_ptr(),
            vectors: batch.as_ptr(),
            vectors_len: batch.len(),
        };
        assert_eq!(zova_sys::zova_vector_put_many(&put_many), zova_sys::ZOVA_OK);

        let mut vector = zova_sys::zova_vector {
            id: ptr::null_mut(),
            id_len: 0,
            element_type: zova_sys::ZOVA_VECTOR_ELEMENT_TYPE_F32,
            f32_values: ptr::null_mut(),
            f16_values: ptr::null_mut(),
            i8_values: ptr::null_mut(),
            values_len: 0,
        };
        let get = zova_sys::zova_vector_get_request {
            db,
            collection_name: collection.as_ptr(),
            vector_id: near_id.as_ptr(),
            out_vector: &mut vector,
        };
        assert_eq!(zova_sys::zova_vector_get(&get), zova_sys::ZOVA_OK);
        assert_eq!(
            std::slice::from_raw_parts(vector.f32_values, vector.values_len),
            near_values
        );
        zova_sys::zova_vector_free(&mut vector);

        let query = [0.0_f32, 0.0];
        let mut results = zova_sys::zova_vector_search_results {
            items: ptr::null_mut(),
            len: 0,
        };
        let search = zova_sys::zova_vector_search_request {
            db,
            collection_name: collection.as_ptr(),
            query: f32_values(&query),
            limit: 2,
            out_results: &mut results,
        };
        assert_eq!(zova_sys::zova_vector_search(&search), zova_sys::ZOVA_OK);
        assert_eq!(results.len, 2);
        zova_sys::zova_vector_search_results_free(&mut results);

        let candidates = [near_id.as_ptr(), far_id.as_ptr()];
        let by_id_in = zova_sys::zova_vector_search_by_id_in_request {
            db,
            collection_name: collection.as_ptr(),
            source_vector_id: source_id.as_ptr(),
            candidate_ids: candidates.as_ptr(),
            candidate_count: candidates.len(),
            limit: 10,
            out_results: &mut results,
        };
        assert_eq!(
            zova_sys::zova_vector_search_by_id_in(&by_id_in),
            zova_sys::ZOVA_OK
        );
        assert_eq!(results.len, 2);
        zova_sys::zova_vector_search_results_free(&mut results);

        let mut info = zova_sys::zova_vector_collection_info {
            name: ptr::null_mut(),
            name_len: 0,
            dimensions: 0,
            metric: 0,
            element_type: zova_sys::ZOVA_VECTOR_ELEMENT_TYPE_F32,
            vector_count: 0,
        };
        let info_request = zova_sys::zova_vector_collection_info_get_request {
            db,
            name: collection.as_ptr(),
            out_info: &mut info,
        };
        assert_eq!(
            zova_sys::zova_vector_collection_info_get(&info_request),
            zova_sys::ZOVA_OK
        );
        assert_eq!(info.vector_count, 3);
        zova_sys::zova_vector_collection_info_free(&mut info);

        let mut typed_info = zova_sys::zova_vector_collection_info {
            name: ptr::null_mut(),
            name_len: 0,
            dimensions: 0,
            metric: 0,
            element_type: zova_sys::ZOVA_VECTOR_ELEMENT_TYPE_F32,
            vector_count: 0,
        };
        let typed_info_request = zova_sys::zova_vector_collection_info_get_request {
            db,
            name: collection.as_ptr(),
            out_info: &mut typed_info,
        };
        assert_eq!(
            zova_sys::zova_vector_collection_info_get(&typed_info_request),
            zova_sys::ZOVA_OK
        );
        assert_eq!(typed_info.vector_count, 3);
        assert_eq!(
            typed_info.element_type,
            zova_sys::ZOVA_VECTOR_ELEMENT_TYPE_F32
        );
        zova_sys::zova_vector_collection_info_free(&mut typed_info);

        let mut list = zova_sys::zova_vector_collection_list {
            items: ptr::null_mut(),
            len: 0,
        };
        let list_request = zova_sys::zova_vector_collections_list_request {
            db,
            out_list: &mut list,
        };
        assert_eq!(
            zova_sys::zova_vector_collections_list(&list_request),
            zova_sys::ZOVA_OK
        );
        assert_eq!(list.len, 1);
        zova_sys::zova_vector_collection_list_free(&mut list);

        let mut typed_list = zova_sys::zova_vector_collection_list {
            items: ptr::null_mut(),
            len: 0,
        };
        let typed_list_request = zova_sys::zova_vector_collections_list_request {
            db,
            out_list: &mut typed_list,
        };
        assert_eq!(
            zova_sys::zova_vector_collections_list(&typed_list_request),
            zova_sys::ZOVA_OK
        );
        assert_eq!(typed_list.len, 1);
        zova_sys::zova_vector_collection_list_free(&mut typed_list);

        let byte_collection = CString::new("byte_chunks").unwrap();
        let create_byte_collection = zova_sys::zova_vector_collection_create_request {
            db,
            name: byte_collection.as_ptr(),
            options: zova_sys::zova_vector_collection_options {
                dimensions: 2,
                metric: zova_sys::ZOVA_VECTOR_METRIC_L2,
                element_type: zova_sys::ZOVA_VECTOR_ELEMENT_TYPE_I8,
            },
        };
        assert_eq!(
            zova_sys::zova_vector_collection_create(&create_byte_collection),
            zova_sys::ZOVA_OK
        );
        let byte_near_values = [1_i8, 0];
        let byte_far_values = [5_i8, 0];
        let byte_query_values = [0_i8, 0];
        assert_eq!(
            zova_sys::zova_vector_put(&zova_sys::zova_vector_put_request {
                db,
                collection_name: byte_collection.as_ptr(),
                vector_id: near_id.as_ptr(),
                values: zova_sys::zova_vector_values {
                    element_type: zova_sys::ZOVA_VECTOR_ELEMENT_TYPE_I8,
                    f32_values: ptr::null(),
                    f16_values: ptr::null(),
                    i8_values: byte_near_values.as_ptr(),
                    values_len: byte_near_values.len(),
                },
            }),
            zova_sys::ZOVA_OK
        );
        assert_eq!(
            zova_sys::zova_vector_put(&zova_sys::zova_vector_put_request {
                db,
                collection_name: byte_collection.as_ptr(),
                vector_id: far_id.as_ptr(),
                values: zova_sys::zova_vector_values {
                    element_type: zova_sys::ZOVA_VECTOR_ELEMENT_TYPE_I8,
                    f32_values: ptr::null(),
                    f16_values: ptr::null(),
                    i8_values: byte_far_values.as_ptr(),
                    values_len: byte_far_values.len(),
                },
            }),
            zova_sys::ZOVA_OK
        );
        let typed_candidates = [far_id.as_ptr()];
        let typed_search_in = zova_sys::zova_vector_search_in_request {
            db,
            collection_name: byte_collection.as_ptr(),
            query: zova_sys::zova_vector_values {
                element_type: zova_sys::ZOVA_VECTOR_ELEMENT_TYPE_I8,
                f32_values: ptr::null(),
                f16_values: ptr::null(),
                i8_values: byte_query_values.as_ptr(),
                values_len: byte_query_values.len(),
            },
            candidate_ids: typed_candidates.as_ptr(),
            candidate_count: typed_candidates.len(),
            limit: 2,
            out_results: &mut results,
        };
        assert_eq!(
            zova_sys::zova_vector_search_in(&typed_search_in),
            zova_sys::ZOVA_OK
        );
        assert_eq!(results.len, 1);
        assert_eq!(CStr::from_ptr((*results.items).id).to_str().unwrap(), "far");
        zova_sys::zova_vector_search_results_free(&mut results);

        let delete_collection = zova_sys::zova_vector_collection_delete_request {
            db,
            name: collection.as_ptr(),
        };
        assert_eq!(
            zova_sys::zova_vector_collection_delete(&delete_collection),
            zova_sys::ZOVA_OK
        );
        assert_eq!(
            zova_sys::zova_vector_get(&get),
            zova_sys::ZOVA_VECTOR_COLLECTION_NOT_FOUND
        );

        assert_eq!(zova_sys::zova_database_close(db), zova_sys::ZOVA_OK);
    }

    let _ = std::fs::remove_file(path);
}

#[test]
fn raw_graph_crud_and_traversal_smoke() {
    let path = temp_path("graphs");
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
        assert_eq!(zova_sys::ZOVA_GRAPH_TARGET_VECTOR, 4);

        let graph = CString::new("app").unwrap();
        let create_graph = zova_sys::zova_graph_create_request {
            db,
            name: graph.as_ptr(),
        };
        assert_eq!(
            zova_sys::zova_graph_create(&create_graph),
            zova_sys::ZOVA_OK
        );
        assert_eq!(
            zova_sys::zova_graph_create(&create_graph),
            zova_sys::ZOVA_GRAPH_EXISTS
        );

        let mut exists = 0;
        let exists_request = zova_sys::zova_graph_exists_request {
            db,
            name: graph.as_ptr(),
            out_exists: &mut exists,
        };
        assert_eq!(
            zova_sys::zova_graph_exists(&exists_request),
            zova_sys::ZOVA_OK
        );
        assert_eq!(exists, 1);

        let message_1 = CString::new("message:1").unwrap();
        let message_2 = CString::new("message:2").unwrap();
        let attachment = CString::new("attachment:1").unwrap();
        let kind_message = CString::new("message").unwrap();
        let kind_attachment = CString::new("attachment").unwrap();
        let table = CString::new("messages").unwrap();
        let row_ref = CString::new("1").unwrap();
        let external_ref = CString::new("https://example.test/a").unwrap();

        let put_message_1 = zova_sys::zova_graph_node_put_request {
            db,
            graph_name: graph.as_ptr(),
            node_id: message_1.as_ptr(),
            kind: kind_message.as_ptr(),
            target_type: zova_sys::ZOVA_GRAPH_TARGET_RECORD,
            target_namespace: table.as_ptr(),
            target_ref: row_ref.as_ptr(),
        };
        assert_eq!(
            zova_sys::zova_graph_node_put(&put_message_1),
            zova_sys::ZOVA_OK
        );
        let put_message_2 = zova_sys::zova_graph_node_put_request {
            db,
            graph_name: graph.as_ptr(),
            node_id: message_2.as_ptr(),
            kind: kind_message.as_ptr(),
            target_type: zova_sys::ZOVA_GRAPH_TARGET_NONE,
            target_namespace: ptr::null(),
            target_ref: ptr::null(),
        };
        assert_eq!(
            zova_sys::zova_graph_node_put(&put_message_2),
            zova_sys::ZOVA_OK
        );
        let put_attachment = zova_sys::zova_graph_node_put_request {
            db,
            graph_name: graph.as_ptr(),
            node_id: attachment.as_ptr(),
            kind: kind_attachment.as_ptr(),
            target_type: zova_sys::ZOVA_GRAPH_TARGET_EXTERNAL,
            target_namespace: ptr::null(),
            target_ref: external_ref.as_ptr(),
        };
        assert_eq!(
            zova_sys::zova_graph_node_put(&put_attachment),
            zova_sys::ZOVA_OK
        );

        let mut node = zova_sys::zova_graph_node {
            graph_name: ptr::null_mut(),
            graph_name_len: 0,
            node_id: ptr::null_mut(),
            node_id_len: 0,
            kind: ptr::null_mut(),
            kind_len: 0,
            target_type: zova_sys::ZOVA_GRAPH_TARGET_NONE,
            target_namespace: ptr::null_mut(),
            target_namespace_len: 0,
            has_target_namespace: 0,
            target_ref: ptr::null_mut(),
            target_ref_len: 0,
            has_target_ref: 0,
        };
        let get_node = zova_sys::zova_graph_node_get_request {
            db,
            graph_name: graph.as_ptr(),
            node_id: message_1.as_ptr(),
            out_node: &mut node,
        };
        assert_eq!(zova_sys::zova_graph_node_get(&get_node), zova_sys::ZOVA_OK);
        assert_eq!(node.target_type, zova_sys::ZOVA_GRAPH_TARGET_RECORD);
        assert_eq!(node.has_target_namespace, 1);
        zova_sys::zova_graph_node_free(&mut node);

        let replies_to = CString::new("replies_to").unwrap();
        let has_attachment = CString::new("has_attachment").unwrap();
        let edge_1 = zova_sys::zova_graph_edge_put_request {
            db,
            graph_name: graph.as_ptr(),
            from_node_id: message_1.as_ptr(),
            edge_type: replies_to.as_ptr(),
            to_node_id: message_2.as_ptr(),
        };
        assert_eq!(zova_sys::zova_graph_edge_put(&edge_1), zova_sys::ZOVA_OK);
        let edge_2 = zova_sys::zova_graph_edge_put_request {
            db,
            graph_name: graph.as_ptr(),
            from_node_id: message_1.as_ptr(),
            edge_type: has_attachment.as_ptr(),
            to_node_id: attachment.as_ptr(),
        };
        assert_eq!(zova_sys::zova_graph_edge_put(&edge_2), zova_sys::ZOVA_OK);

        let mut edge = zova_sys::zova_graph_edge {
            graph_name: ptr::null_mut(),
            graph_name_len: 0,
            from_node_id: ptr::null_mut(),
            from_node_id_len: 0,
            edge_type: ptr::null_mut(),
            edge_type_len: 0,
            to_node_id: ptr::null_mut(),
            to_node_id_len: 0,
        };
        let get_edge = zova_sys::zova_graph_edge_get_request {
            db,
            graph_name: graph.as_ptr(),
            from_node_id: message_1.as_ptr(),
            edge_type: has_attachment.as_ptr(),
            to_node_id: attachment.as_ptr(),
            out_edge: &mut edge,
        };
        assert_eq!(zova_sys::zova_graph_edge_get(&get_edge), zova_sys::ZOVA_OK);
        zova_sys::zova_graph_edge_free(&mut edge);

        let mut neighbors = zova_sys::zova_graph_neighbor_results {
            items: ptr::null_mut(),
            len: 0,
        };
        let neighbor_request = zova_sys::zova_graph_neighbors_request {
            db,
            graph_name: graph.as_ptr(),
            node_id: message_1.as_ptr(),
            direction: zova_sys::ZOVA_GRAPH_NEIGHBOR_OUTGOING,
            edge_type: ptr::null(),
            limit: 10,
            out_results: &mut neighbors,
        };
        assert_eq!(
            zova_sys::zova_graph_neighbors(&neighbor_request),
            zova_sys::ZOVA_OK
        );
        assert_eq!(neighbors.len, 2);
        zova_sys::zova_graph_neighbor_results_free(&mut neighbors);

        let mut walk = zova_sys::zova_graph_walk_results {
            items: ptr::null_mut(),
            len: 0,
        };
        let walk_request = zova_sys::zova_graph_walk_request {
            db,
            graph_name: graph.as_ptr(),
            start_node_id: message_1.as_ptr(),
            edge_type: ptr::null(),
            max_depth: 2,
            limit: 10,
            out_results: &mut walk,
        };
        assert_eq!(zova_sys::zova_graph_walk(&walk_request), zova_sys::ZOVA_OK);
        assert_eq!(walk.len, 3);
        zova_sys::zova_graph_walk_results_free(&mut walk);

        let invalid_graph = CString::new("_zova_private").unwrap();
        let invalid = zova_sys::zova_graph_create_request {
            db,
            name: invalid_graph.as_ptr(),
        };
        assert_eq!(
            zova_sys::zova_graph_create(&invalid),
            zova_sys::ZOVA_GRAPH_INVALID
        );

        assert_eq!(zova_sys::zova_database_close(db), zova_sys::ZOVA_OK);
    }

    let _ = std::fs::remove_file(path);
}
