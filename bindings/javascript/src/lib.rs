use std::ffi::CStr;

use napi_derive::napi;

mod async_ops;
mod database;
mod error;
mod graph;
mod object;
mod statement;
mod subscription;
mod vector;

#[napi]
pub fn package_version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

#[napi]
pub fn abi_version() -> String {
    // SAFETY: Zova returns a process-lifetime, NUL-terminated version string.
    unsafe { CStr::from_ptr(zova_sys::zova_abi_version_string()) }
        .to_string_lossy()
        .into_owned()
}

#[napi]
pub fn format_version() -> &'static str {
    env!("ZOVA_FORMAT_VERSION")
}

#[napi]
pub fn sqlite_version() -> &'static str {
    env!("ZOVA_SQLITE_VERSION")
}
