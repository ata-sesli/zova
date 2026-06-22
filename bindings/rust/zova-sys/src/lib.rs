#![allow(non_camel_case_types)]
#![allow(non_snake_case)]
#![allow(non_upper_case_globals)]

use std::os::raw::{c_char, c_int};

pub type zova_status = c_int;
pub type zova_step_result = c_int;
pub type zova_column_type = c_int;

pub const ZOVA_OK: zova_status = 0;
pub const ZOVA_INVALID_ARGUMENT: zova_status = 1;
pub const ZOVA_OUT_OF_MEMORY: zova_status = 2;
pub const ZOVA_BUSY: zova_status = 10;
pub const ZOVA_LOCKED: zova_status = 11;
pub const ZOVA_CONSTRAINT: zova_status = 12;
pub const ZOVA_CANT_OPEN: zova_status = 13;
pub const ZOVA_READ_ONLY: zova_status = 14;
pub const ZOVA_CORRUPT: zova_status = 15;
pub const ZOVA_MISUSE: zova_status = 16;
pub const ZOVA_SQLITE_ERROR: zova_status = 17;
pub const ZOVA_NOT_ZOVA_PATH: zova_status = 30;
pub const ZOVA_NOT_ZOVA_DATABASE: zova_status = 31;
pub const ZOVA_UNSUPPORTED_ZOVA_VERSION: zova_status = 32;
pub const ZOVA_DESTINATION_EXISTS: zova_status = 33;
pub const ZOVA_ZOVA_NAME_CONFLICT: zova_status = 34;
pub const ZOVA_OBJECT_NOT_FOUND: zova_status = 50;
pub const ZOVA_OBJECT_ALREADY_EXISTS: zova_status = 51;
pub const ZOVA_OBJECT_CHUNK_NOT_FOUND: zova_status = 52;
pub const ZOVA_OBJECT_CHUNK_HASH_MISMATCH: zova_status = 53;
pub const ZOVA_OBJECT_CORRUPT: zova_status = 54;
pub const ZOVA_OBJECT_MANIFEST_INVALID: zova_status = 55;
pub const ZOVA_OBJECT_RANGE_INVALID: zova_status = 56;
pub const ZOVA_OBJECT_TOO_LARGE: zova_status = 57;
pub const ZOVA_OBJECT_TRANSACTION_ACTIVE: zova_status = 58;
pub const ZOVA_OBJECT_WRITER_CLOSED: zova_status = 59;
pub const ZOVA_VECTOR_COLLECTION_EXISTS: zova_status = 70;
pub const ZOVA_VECTOR_COLLECTION_NOT_FOUND: zova_status = 71;
pub const ZOVA_VECTOR_NOT_FOUND: zova_status = 72;
pub const ZOVA_VECTOR_DIMENSION_MISMATCH: zova_status = 73;
pub const ZOVA_VECTOR_CORRUPT: zova_status = 74;
pub const ZOVA_VECTOR_INVALID: zova_status = 75;

pub const ZOVA_STEP_ROW: zova_step_result = 1;
pub const ZOVA_STEP_DONE: zova_step_result = 2;

pub const ZOVA_COLUMN_INTEGER: zova_column_type = 1;
pub const ZOVA_COLUMN_FLOAT: zova_column_type = 2;
pub const ZOVA_COLUMN_TEXT: zova_column_type = 3;
pub const ZOVA_COLUMN_BLOB: zova_column_type = 4;
pub const ZOVA_COLUMN_NULL: zova_column_type = 5;

#[repr(C)]
pub struct zova_database {
    _private: [u8; 0],
}

#[repr(C)]
pub struct zova_statement {
    _private: [u8; 0],
}

#[repr(C)]
#[derive(Debug, Copy, Clone)]
pub struct zova_buffer {
    pub data: *mut u8,
    pub len: usize,
}

#[repr(C)]
#[derive(Debug, Copy, Clone)]
pub struct zova_message {
    pub data: *mut c_char,
    pub len: usize,
}

#[repr(C)]
#[derive(Debug, Copy, Clone)]
pub struct zova_text {
    pub data: *mut c_char,
    pub len: usize,
}

#[repr(C)]
pub struct zova_database_open_request {
    pub path: *const c_char,
    pub out_db: *mut *mut zova_database,
    pub out_error_message: *mut zova_message,
}

#[repr(C)]
pub struct zova_convert_sqlite_to_zova_request {
    pub source_path: *const c_char,
    pub dest_path: *const c_char,
    pub out_error_message: *mut zova_message,
}

#[repr(C)]
pub struct zova_database_exec_request {
    pub db: *mut zova_database,
    pub sql: *const c_char,
}

#[repr(C)]
pub struct zova_database_simple_request {
    pub db: *mut zova_database,
}

#[repr(C)]
pub struct zova_database_prepare_request {
    pub db: *mut zova_database,
    pub sql: *const c_char,
    pub out_statement: *mut *mut zova_statement,
}

#[repr(C)]
pub struct zova_statement_step_request {
    pub statement: *mut zova_statement,
    pub out_result: *mut zova_step_result,
}

#[repr(C)]
pub struct zova_statement_bind_null_request {
    pub statement: *mut zova_statement,
    pub index: c_int,
}

#[repr(C)]
pub struct zova_statement_bind_int64_request {
    pub statement: *mut zova_statement,
    pub index: c_int,
    pub value: i64,
}

#[repr(C)]
pub struct zova_statement_bind_double_request {
    pub statement: *mut zova_statement,
    pub index: c_int,
    pub value: f64,
}

#[repr(C)]
pub struct zova_statement_bind_text_request {
    pub statement: *mut zova_statement,
    pub index: c_int,
    pub data: *const u8,
    pub len: usize,
}

#[repr(C)]
pub struct zova_statement_bind_blob_request {
    pub statement: *mut zova_statement,
    pub index: c_int,
    pub data: *const u8,
    pub len: usize,
}

#[repr(C)]
pub struct zova_statement_parameter_count_request {
    pub statement: *mut zova_statement,
    pub out_count: *mut c_int,
}

#[repr(C)]
pub struct zova_statement_parameter_index_request {
    pub statement: *mut zova_statement,
    pub name: *const c_char,
    pub out_index: *mut c_int,
}

#[repr(C)]
pub struct zova_statement_column_count_request {
    pub statement: *mut zova_statement,
    pub out_count: *mut c_int,
}

#[repr(C)]
pub struct zova_statement_column_type_request {
    pub statement: *mut zova_statement,
    pub index: c_int,
    pub out_type: *mut zova_column_type,
}

#[repr(C)]
pub struct zova_statement_column_int64_request {
    pub statement: *mut zova_statement,
    pub index: c_int,
    pub out_value: *mut i64,
}

#[repr(C)]
pub struct zova_statement_column_double_request {
    pub statement: *mut zova_statement,
    pub index: c_int,
    pub out_value: *mut f64,
}

#[repr(C)]
pub struct zova_statement_column_text_request {
    pub statement: *mut zova_statement,
    pub index: c_int,
    pub out_text: *mut zova_text,
}

#[repr(C)]
pub struct zova_statement_column_blob_request {
    pub statement: *mut zova_statement,
    pub index: c_int,
    pub out_buffer: *mut zova_buffer,
}

extern "C" {
    pub fn zova_abi_version_major() -> u32;
    pub fn zova_abi_version_minor() -> u32;
    pub fn zova_abi_version_patch() -> u32;
    pub fn zova_abi_version_string() -> *const c_char;
    pub fn zova_status_name(status: zova_status) -> *const c_char;

    pub fn zova_buffer_free(buffer: *mut zova_buffer);
    pub fn zova_message_free(message: *mut zova_message);
    pub fn zova_text_free(text: *mut zova_text);

    pub fn zova_database_create(request: *const zova_database_open_request) -> zova_status;
    pub fn zova_database_open(request: *const zova_database_open_request) -> zova_status;
    pub fn zova_database_close(db: *mut zova_database) -> zova_status;
    pub fn zova_database_exec(request: *const zova_database_exec_request) -> zova_status;
    pub fn zova_database_begin(request: *const zova_database_simple_request) -> zova_status;
    pub fn zova_database_begin_immediate(
        request: *const zova_database_simple_request,
    ) -> zova_status;
    pub fn zova_database_commit(request: *const zova_database_simple_request) -> zova_status;
    pub fn zova_database_rollback(request: *const zova_database_simple_request) -> zova_status;
    pub fn zova_database_vacuum(request: *const zova_database_simple_request) -> zova_status;
    pub fn zova_database_prepare(request: *const zova_database_prepare_request) -> zova_status;
    pub fn zova_database_last_error_message(db: *mut zova_database) -> *const c_char;
    pub fn zova_convert_sqlite_to_zova(
        request: *const zova_convert_sqlite_to_zova_request,
    ) -> zova_status;

    pub fn zova_statement_finalize(statement: *mut zova_statement) -> zova_status;
    pub fn zova_statement_step(request: *const zova_statement_step_request) -> zova_status;
    pub fn zova_statement_reset(statement: *mut zova_statement) -> zova_status;
    pub fn zova_statement_clear_bindings(statement: *mut zova_statement) -> zova_status;
    pub fn zova_statement_bind_null(
        request: *const zova_statement_bind_null_request,
    ) -> zova_status;
    pub fn zova_statement_bind_int64(
        request: *const zova_statement_bind_int64_request,
    ) -> zova_status;
    pub fn zova_statement_bind_double(
        request: *const zova_statement_bind_double_request,
    ) -> zova_status;
    pub fn zova_statement_bind_text(
        request: *const zova_statement_bind_text_request,
    ) -> zova_status;
    pub fn zova_statement_bind_blob(
        request: *const zova_statement_bind_blob_request,
    ) -> zova_status;
    pub fn zova_statement_parameter_count(
        request: *const zova_statement_parameter_count_request,
    ) -> zova_status;
    pub fn zova_statement_parameter_index(
        request: *const zova_statement_parameter_index_request,
    ) -> zova_status;
    pub fn zova_statement_column_count(
        request: *const zova_statement_column_count_request,
    ) -> zova_status;
    pub fn zova_statement_column_type(
        request: *const zova_statement_column_type_request,
    ) -> zova_status;
    pub fn zova_statement_column_int64(
        request: *const zova_statement_column_int64_request,
    ) -> zova_status;
    pub fn zova_statement_column_double(
        request: *const zova_statement_column_double_request,
    ) -> zova_status;
    pub fn zova_statement_column_text(
        request: *const zova_statement_column_text_request,
    ) -> zova_status;
    pub fn zova_statement_column_blob(
        request: *const zova_statement_column_blob_request,
    ) -> zova_status;
}
