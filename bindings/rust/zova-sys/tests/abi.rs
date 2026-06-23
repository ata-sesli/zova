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
        assert_eq!(zova_sys::zova_abi_version_minor(), 14);
        assert_eq!(zova_sys::zova_abi_version_patch(), 0);
        assert_eq!(
            CStr::from_ptr(zova_sys::zova_abi_version_string())
                .to_str()
                .unwrap(),
            "0.14.0"
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
                values: source_values.as_ptr(),
                values_len: source_values.len(),
            },
            zova_sys::zova_vector_input {
                id: near_id.as_ptr(),
                values: near_values.as_ptr(),
                values_len: near_values.len(),
            },
            zova_sys::zova_vector_input {
                id: far_id.as_ptr(),
                values: far_values.as_ptr(),
                values_len: far_values.len(),
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
            values: ptr::null_mut(),
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
            std::slice::from_raw_parts(vector.values, vector.values_len),
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
            query: query.as_ptr(),
            query_len: query.len(),
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
