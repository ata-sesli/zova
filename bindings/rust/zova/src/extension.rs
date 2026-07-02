use crate::database::cstring;
use crate::error::{Error, Result};
use crate::Database;
use std::os::raw::c_char;
use std::ptr;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExtensionInfo {
    pub name: String,
    pub version: String,
    pub storage_prefix: String,
    pub zova_abi_min: String,
    pub capabilities: String,
    pub required: bool,
    pub installed_at_unix: i64,
    pub manifest_json: String,
}

impl Database {
    pub fn install_extension(&mut self, name: &str) -> Result<()> {
        let db = self.raw_ptr();
        install_extension_raw(db, |status| self.status(status), name)
    }

    pub fn list_extensions(&mut self) -> Result<Vec<ExtensionInfo>> {
        let db = self.raw_ptr();
        list_extensions_raw(db, |status| self.status(status))
    }

    pub fn extension_info(&mut self, name: &str) -> Result<ExtensionInfo> {
        let db = self.raw_ptr();
        extension_info_raw(db, |status| self.status(status), name)
    }

    pub fn check_extension(&mut self, name: &str) -> Result<()> {
        let db = self.raw_ptr();
        check_extension_raw(db, |status| self.status(status), name)
    }

    pub fn check_extensions(&mut self) -> Result<()> {
        let db = self.raw_ptr();
        check_extensions_raw(db, |status| self.status(status))
    }

    pub fn drop_extension(&mut self, name: &str) -> Result<()> {
        let db = self.raw_ptr();
        drop_extension_raw(db, |status| self.status(status), name)
    }
}

pub(crate) fn install_extension_raw(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
    name: &str,
) -> Result<()> {
    let name = cstring(name, "extension name")?;
    let request = zova_sys::zova_database_extension_request {
        db,
        name: name.as_ptr(),
    };
    status(unsafe { zova_sys::zova_database_extension_install(&request) })
}

pub(crate) fn list_extensions_raw(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
) -> Result<Vec<ExtensionInfo>> {
    let mut list = empty_extension_list();
    let request = zova_sys::zova_database_extension_list_request {
        db,
        out_list: &mut list,
    };
    status(unsafe { zova_sys::zova_database_extension_list(&request) })?;
    take_extension_list(&mut list)
}

pub(crate) fn extension_info_raw(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
    name: &str,
) -> Result<ExtensionInfo> {
    let name = cstring(name, "extension name")?;
    let mut info = empty_extension_info();
    let request = zova_sys::zova_database_extension_info_request {
        db,
        name: name.as_ptr(),
        out_info: &mut info,
    };
    status(unsafe { zova_sys::zova_database_extension_info(&request) })?;
    take_extension_info(&mut info)
}

pub(crate) fn check_extension_raw(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
    name: &str,
) -> Result<()> {
    let name = cstring(name, "extension name")?;
    let request = zova_sys::zova_database_extension_request {
        db,
        name: name.as_ptr(),
    };
    status(unsafe { zova_sys::zova_database_extension_check(&request) })
}

pub(crate) fn check_extensions_raw(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
) -> Result<()> {
    let request = zova_sys::zova_database_simple_request { db };
    status(unsafe { zova_sys::zova_database_extension_check_all(&request) })
}

pub(crate) fn drop_extension_raw(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
    name: &str,
) -> Result<()> {
    let name = cstring(name, "extension name")?;
    let request = zova_sys::zova_database_extension_request {
        db,
        name: name.as_ptr(),
    };
    status(unsafe { zova_sys::zova_database_extension_drop(&request) })
}

pub(crate) fn empty_extension_info() -> zova_sys::zova_extension_info {
    zova_sys::zova_extension_info {
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
    }
}

pub(crate) fn empty_extension_list() -> zova_sys::zova_extension_list {
    zova_sys::zova_extension_list {
        items: ptr::null_mut(),
        len: 0,
    }
}

pub(crate) fn take_extension_info(
    info: &mut zova_sys::zova_extension_info,
) -> Result<ExtensionInfo> {
    let out = (|| {
        Ok(ExtensionInfo {
            name: string_from_parts(info.name, info.name_len)?,
            version: string_from_parts(info.version, info.version_len)?,
            storage_prefix: string_from_parts(info.storage_prefix, info.storage_prefix_len)?,
            zova_abi_min: string_from_parts(info.zova_abi_min, info.zova_abi_min_len)?,
            capabilities: string_from_parts(info.capabilities, info.capabilities_len)?,
            required: info.required != 0,
            installed_at_unix: info.installed_at_unix,
            manifest_json: string_from_parts(info.manifest_json, info.manifest_json_len)?,
        })
    })();
    unsafe {
        zova_sys::zova_extension_info_free(info);
    }
    out
}

pub(crate) fn take_extension_list(
    list: &mut zova_sys::zova_extension_list,
) -> Result<Vec<ExtensionInfo>> {
    let out = (|| {
        if list.items.is_null() || list.len == 0 {
            Ok(Vec::new())
        } else {
            unsafe { std::slice::from_raw_parts(list.items, list.len) }
                .iter()
                .map(|item| {
                    Ok(ExtensionInfo {
                        name: string_from_parts(item.name, item.name_len)?,
                        version: string_from_parts(item.version, item.version_len)?,
                        storage_prefix: string_from_parts(
                            item.storage_prefix,
                            item.storage_prefix_len,
                        )?,
                        zova_abi_min: string_from_parts(item.zova_abi_min, item.zova_abi_min_len)?,
                        capabilities: string_from_parts(item.capabilities, item.capabilities_len)?,
                        required: item.required != 0,
                        installed_at_unix: item.installed_at_unix,
                        manifest_json: string_from_parts(
                            item.manifest_json,
                            item.manifest_json_len,
                        )?,
                    })
                })
                .collect::<Result<Vec<_>>>()
        }
    })();
    unsafe {
        zova_sys::zova_extension_list_free(list);
    }
    out
}

fn string_from_parts(data: *const c_char, len: usize) -> Result<String> {
    if data.is_null() {
        return Ok(String::new());
    }
    let bytes = unsafe { std::slice::from_raw_parts(data.cast::<u8>(), len) };
    String::from_utf8(bytes.to_vec()).map_err(|_| Error::InvalidUtf8Text)
}
