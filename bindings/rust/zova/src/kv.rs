use crate::error::Result;
use std::ptr;

/// Borrowed key-value pair for a batch key-value put.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KvEntry<'a> {
    pub key: &'a [u8],
    pub value: &'a [u8],
}

impl<'a> KvEntry<'a> {
    pub fn new(key: &'a [u8], value: &'a [u8]) -> Self {
        Self { key, value }
    }
}

fn raw_bytes(data: &[u8]) -> zova_sys::zova_kv_bytes {
    zova_sys::zova_kv_bytes {
        data: data.as_ptr(),
        len: data.len(),
    }
}

pub(crate) fn kv_get_raw(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
    namespace: &[u8],
    key: &[u8],
) -> Result<Option<Vec<u8>>> {
    let mut result = zova_sys::zova_kv_get_result {
        found: 0,
        value: zova_sys::zova_buffer {
            data: ptr::null_mut(),
            len: 0,
        },
    };
    let request = zova_sys::zova_kv_get_request {
        db,
        ns: raw_bytes(namespace),
        key: raw_bytes(key),
        out_result: &mut result,
    };
    status(unsafe { zova_sys::zova_kv_get(&request) })?;
    let found = result.found != 0;
    let value = read_owned_buffer(result.value);
    unsafe { zova_sys::zova_kv_get_result_free(&mut result) };
    if found {
        Ok(Some(value))
    } else {
        Ok(None)
    }
}

pub(crate) fn kv_get_many_raw(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
    namespace: &[u8],
    keys: &[&[u8]],
) -> Result<Vec<Option<Vec<u8>>>> {
    let raw_keys: Vec<zova_sys::zova_kv_bytes> =
        keys.iter().map(|key| raw_bytes(key)).collect();
    let mut results = zova_sys::zova_kv_get_many_results {
        items: ptr::null_mut(),
        len: 0,
    };
    let request = zova_sys::zova_kv_get_many_request {
        db,
        ns: raw_bytes(namespace),
        keys: raw_keys.as_ptr(),
        keys_len: raw_keys.len(),
        out_results: &mut results,
    };
    status(unsafe { zova_sys::zova_kv_get_many(&request) })?;
    let mut out = Vec::with_capacity(results.len);
    for index in 0..results.len {
        let item = unsafe { &*results.items.add(index) };
        let value = read_owned_buffer(item.value);
        if item.found != 0 {
            out.push(Some(value));
        } else {
            out.push(None);
        }
    }
    unsafe { zova_sys::zova_kv_get_many_results_free(&mut results) };
    Ok(out)
}

pub(crate) fn kv_put_raw(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
    namespace: &[u8],
    key: &[u8],
    value: &[u8],
) -> Result<()> {
    let request = zova_sys::zova_kv_put_request {
        db,
        ns: raw_bytes(namespace),
        key: raw_bytes(key),
        value: raw_bytes(value),
    };
    status(unsafe { zova_sys::zova_kv_put(&request) })
}

pub(crate) fn kv_put_many_raw(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
    namespace: &[u8],
    entries: &[KvEntry<'_>],
) -> Result<()> {
    let raw: Vec<zova_sys::zova_kv_put_entry> = entries
        .iter()
        .map(|entry| zova_sys::zova_kv_put_entry {
            key: raw_bytes(entry.key),
            value: raw_bytes(entry.value),
        })
        .collect();
    let request = zova_sys::zova_kv_put_many_request {
        db,
        ns: raw_bytes(namespace),
        entries: raw.as_ptr(),
        entries_len: raw.len(),
    };
    status(unsafe { zova_sys::zova_kv_put_many(&request) })
}

pub(crate) fn kv_delete_raw(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
    namespace: &[u8],
    key: &[u8],
) -> Result<()> {
    let request = zova_sys::zova_kv_delete_request {
        db,
        ns: raw_bytes(namespace),
        key: raw_bytes(key),
    };
    status(unsafe { zova_sys::zova_kv_delete(&request) })
}

pub(crate) fn kv_delete_many_raw(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
    namespace: &[u8],
    keys: &[&[u8]],
) -> Result<()> {
    let raw_keys: Vec<zova_sys::zova_kv_bytes> =
        keys.iter().map(|key| raw_bytes(key)).collect();
    let request = zova_sys::zova_kv_delete_many_request {
        db,
        ns: raw_bytes(namespace),
        keys: raw_keys.as_ptr(),
        keys_len: raw_keys.len(),
    };
    status(unsafe { zova_sys::zova_kv_delete_many(&request) })
}

pub(crate) fn kv_count_raw(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
    namespace: &[u8],
) -> Result<u64> {
    let mut count = 0;
    let request = zova_sys::zova_kv_count_request {
        db,
        ns: raw_bytes(namespace),
        out_count: &mut count,
    };
    status(unsafe { zova_sys::zova_kv_count(&request) })?;
    Ok(count)
}

pub(crate) fn kv_clear_namespace_raw(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
    namespace: &[u8],
) -> Result<()> {
    let request = zova_sys::zova_kv_clear_namespace_request {
        db,
        ns: raw_bytes(namespace),
    };
    status(unsafe { zova_sys::zova_kv_clear_namespace(&request) })
}

fn read_owned_buffer(buffer: zova_sys::zova_buffer) -> Vec<u8> {
    if buffer.data.is_null() || buffer.len == 0 {
        return Vec::new();
    }
    unsafe { std::slice::from_raw_parts(buffer.data, buffer.len) }.to_vec()
}
