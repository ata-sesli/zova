//! Raw layouts for include/zova_plugin.h. These are unsafe authoring primitives,
//! not safe callbacks or a loader. Never retain a hook's host/connection or row
//! buffers, reenter its connection, unwind across C, or cross allocator owners.
use std::os::raw::{c_char, c_void};

pub const ZOVA_PLUGIN_ABI_V1: u32 = 1;
pub const ZOVA_PLUGIN_OK: i32 = 0;
pub const ZOVA_PLUGIN_ERROR: i32 = 1;
pub const ZOVA_PLUGIN_OUT_OF_MEMORY: i32 = 2;
pub const ZOVA_PLUGIN_INVALID_ARGUMENT: i32 = 3;
pub const ZOVA_PLUGIN_UNSUPPORTED: i32 = 4;
pub const ZOVA_PLUGIN_LIMIT: i32 = 5;
pub const ZOVA_PLUGIN_CANCELED: i32 = 6;
pub const ZOVA_PLUGIN_HAS_UPGRADE_V1: u64 = 1;
pub const ZOVA_PLUGIN_REQUIRES_QUERY_V1: u64 = 2;
pub const ZOVA_PLUGIN_REQUIRES_DIAGNOSTICS_V1: u64 = 4;
pub const ZOVA_PLUGIN_SERVICE_QUERY: u32 = 1;
pub const ZOVA_PLUGIN_SERVICE_DIAGNOSTICS: u32 = 2;
pub const ZOVA_PLUGIN_VALUE_NULL: u32 = 0;
pub const ZOVA_PLUGIN_VALUE_INTEGER: u32 = 1;
pub const ZOVA_PLUGIN_VALUE_FLOAT: u32 = 2;
pub const ZOVA_PLUGIN_VALUE_TEXT: u32 = 3;
pub const ZOVA_PLUGIN_VALUE_BLOB: u32 = 4;

pub type zova_plugin_hook_v1 =
    Option<unsafe extern "C" fn(*const zova_plugin_host_v1, *mut c_void) -> i32>;
pub type zova_plugin_row_v1 =
    Option<unsafe extern "C" fn(*mut c_void, *const zova_plugin_value_v1, u64) -> i32>;

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct zova_plugin_host_v1 {
    pub struct_size: u32,
    pub abi_version: u32,
    pub exec_sql: Option<unsafe extern "C" fn(*mut c_void, *const c_char, u64) -> i32>,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct zova_plugin_service_host_v1 {
    pub base: zova_plugin_host_v1,
    pub get_service:
        Option<unsafe extern "C" fn(*mut c_void, u32, u32, u32, *mut *const c_void) -> i32>,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct zova_plugin_descriptor_v1 {
    pub struct_size: u32,
    pub abi_version: u32,
    pub flags: u64,
    pub name: *const c_char,
    pub version: *const c_char,
    pub storage_prefix: *const c_char,
    pub zova_abi_min: *const c_char,
    pub capabilities: *const c_char,
    pub install: zova_plugin_hook_v1,
    pub check: zova_plugin_hook_v1,
    pub drop: zova_plugin_hook_v1,
    pub register_sql: zova_plugin_hook_v1,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct zova_plugin_upgrade_descriptor_v1 {
    pub base: zova_plugin_descriptor_v1,
    pub from_version: *const c_char,
    pub upgrade: zova_plugin_hook_v1,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct zova_plugin_value_v1 {
    pub kind: u32,
    pub reserved: u32,
    pub integer: i64,
    pub real: f64,
    pub bytes: *const u8,
    pub bytes_len: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct zova_plugin_query_request_v1 {
    pub struct_size: u32,
    pub flags: u32,
    pub sql: *const c_char,
    pub sql_len: u64,
    pub parameters: *const zova_plugin_value_v1,
    pub parameter_count: u64,
    pub row_limit: u64,
    pub byte_limit: u64,
    pub row: zova_plugin_row_v1,
    pub user_data: *mut c_void,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct zova_plugin_query_service_v1 {
    pub struct_size: u32,
    pub version: u32,
    pub query:
        Option<unsafe extern "C" fn(*mut c_void, *const zova_plugin_query_request_v1) -> i32>,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct zova_plugin_diagnostics_service_v1 {
    pub struct_size: u32,
    pub version: u32,
    pub copy_sqlite_error: Option<unsafe extern "C" fn(*mut c_void, *mut u8, u64, *mut u64) -> i32>,
}

pub type zova_plugin_entry_v1 = unsafe extern "C" fn(u32) -> *const zova_plugin_descriptor_v1;
