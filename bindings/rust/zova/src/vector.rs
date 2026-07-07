use crate::database::cstring;
use crate::error::{Error, Result};
use crate::Database;
use std::os::raw::c_char;
use std::ptr;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VectorMetric {
    Cosine,
    L2,
    Dot,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VectorElementType {
    F32,
    F16,
    I8,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VectorCollectionOptions {
    pub dimensions: u32,
    pub metric: VectorMetric,
    pub element_type: VectorElementType,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Vector {
    pub id: String,
    pub values: VectorValuesOwned,
}

#[derive(Debug, Clone, PartialEq)]
pub enum VectorValuesOwned {
    F32(Vec<f32>),
    F16(Vec<u16>),
    I8(Vec<i8>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VectorCollectionInfo {
    pub name: String,
    pub dimensions: u32,
    pub metric: VectorMetric,
    pub element_type: VectorElementType,
    pub vector_count: u64,
}

#[derive(Debug, Clone, Copy)]
pub struct VectorInput<'a> {
    pub id: &'a str,
    pub values: VectorValues<'a>,
}

#[derive(Debug, Clone, Copy)]
pub enum VectorValues<'a> {
    F32(&'a [f32]),
    F16(&'a [u16]),
    I8(&'a [i8]),
}

#[derive(Debug, Clone, PartialEq)]
pub struct VectorSearchResult {
    pub id: String,
    pub distance: f64,
}

impl Database {
    pub fn create_vector_collection(
        &mut self,
        name: &str,
        options: VectorCollectionOptions,
    ) -> Result<()> {
        let name = cstring(name, "vector collection name")?;
        let request = zova_sys::zova_vector_collection_create_request {
            db: self.raw_ptr(),
            name: name.as_ptr(),
            options: zova_sys::zova_vector_collection_options {
                dimensions: options.dimensions,
                metric: options.metric.to_c(),
                element_type: options.element_type.to_c(),
            },
        };
        self.status(unsafe { zova_sys::zova_vector_collection_create(&request) })
    }

    pub fn has_vector_collection(&mut self, name: &str) -> Result<bool> {
        let name = cstring(name, "vector collection name")?;
        let mut exists = 0;
        let request = zova_sys::zova_vector_collection_exists_request {
            db: self.raw_ptr(),
            name: name.as_ptr(),
            out_exists: &mut exists,
        };
        self.status(unsafe { zova_sys::zova_vector_collection_exists(&request) })?;
        Ok(exists != 0)
    }

    pub fn vector_collection_info(&mut self, name: &str) -> Result<VectorCollectionInfo> {
        let name = cstring(name, "vector collection name")?;
        let mut info = empty_collection_info();
        let request = zova_sys::zova_vector_collection_info_get_request {
            db: self.raw_ptr(),
            name: name.as_ptr(),
            out_info: &mut info,
        };
        self.status(unsafe { zova_sys::zova_vector_collection_info_get(&request) })?;
        take_collection_info(&mut info)
    }

    pub fn list_vector_collections(&mut self) -> Result<Vec<VectorCollectionInfo>> {
        let mut list = zova_sys::zova_vector_collection_list {
            items: ptr::null_mut(),
            len: 0,
        };
        let request = zova_sys::zova_vector_collections_list_request {
            db: self.raw_ptr(),
            out_list: &mut list,
        };
        self.status(unsafe { zova_sys::zova_vector_collections_list(&request) })?;
        take_collection_list(&mut list)
    }

    pub fn delete_vector_collection(&mut self, name: &str) -> Result<()> {
        let name = cstring(name, "vector collection name")?;
        let request = zova_sys::zova_vector_collection_delete_request {
            db: self.raw_ptr(),
            name: name.as_ptr(),
        };
        self.status(unsafe { zova_sys::zova_vector_collection_delete(&request) })
    }

    pub fn put_vector(
        &mut self,
        collection_name: &str,
        vector_id: &str,
        values: VectorValues<'_>,
    ) -> Result<()> {
        let collection_name = cstring(collection_name, "vector collection name")?;
        let vector_id = cstring(vector_id, "vector id")?;
        let request = zova_sys::zova_vector_put_request {
            db: self.raw_ptr(),
            collection_name: collection_name.as_ptr(),
            vector_id: vector_id.as_ptr(),
            values: values.to_c(),
        };
        self.status(unsafe { zova_sys::zova_vector_put(&request) })
    }

    pub fn put_vectors(
        &mut self,
        collection_name: &str,
        vectors: &[VectorInput<'_>],
    ) -> Result<()> {
        let collection_name = cstring(collection_name, "vector collection name")?;
        let (ids, inputs) = vector_inputs(vectors)?;
        let request = zova_sys::zova_vector_put_many_request {
            db: self.raw_ptr(),
            collection_name: collection_name.as_ptr(),
            vectors: if inputs.is_empty() {
                ptr::null()
            } else {
                inputs.as_ptr()
            },
            vectors_len: inputs.len(),
        };
        let result = self.status(unsafe { zova_sys::zova_vector_put_many(&request) });
        drop(ids);
        result
    }

    pub fn get_vector(&mut self, collection_name: &str, vector_id: &str) -> Result<Vector> {
        let collection_name = cstring(collection_name, "vector collection name")?;
        let vector_id = cstring(vector_id, "vector id")?;
        let mut vector = empty_vector();
        let request = zova_sys::zova_vector_get_request {
            db: self.raw_ptr(),
            collection_name: collection_name.as_ptr(),
            vector_id: vector_id.as_ptr(),
            out_vector: &mut vector,
        };
        self.status(unsafe { zova_sys::zova_vector_get(&request) })?;
        take_vector(&mut vector)
    }

    pub fn has_vector(&mut self, collection_name: &str, vector_id: &str) -> Result<bool> {
        let collection_name = cstring(collection_name, "vector collection name")?;
        let vector_id = cstring(vector_id, "vector id")?;
        let mut exists = 0;
        let request = zova_sys::zova_vector_exists_request {
            db: self.raw_ptr(),
            collection_name: collection_name.as_ptr(),
            vector_id: vector_id.as_ptr(),
            out_exists: &mut exists,
        };
        self.status(unsafe { zova_sys::zova_vector_exists(&request) })?;
        Ok(exists != 0)
    }

    pub fn delete_vector(&mut self, collection_name: &str, vector_id: &str) -> Result<()> {
        let collection_name = cstring(collection_name, "vector collection name")?;
        let vector_id = cstring(vector_id, "vector id")?;
        let request = zova_sys::zova_vector_delete_request {
            db: self.raw_ptr(),
            collection_name: collection_name.as_ptr(),
            vector_id: vector_id.as_ptr(),
        };
        self.status(unsafe { zova_sys::zova_vector_delete(&request) })
    }

    pub fn search_vectors(
        &mut self,
        collection_name: &str,
        query: VectorValues<'_>,
        limit: usize,
    ) -> Result<Vec<VectorSearchResult>> {
        let collection_name = cstring(collection_name, "vector collection name")?;
        let mut results = empty_search_results();
        let request = zova_sys::zova_vector_search_request {
            db: self.raw_ptr(),
            collection_name: collection_name.as_ptr(),
            query: query.to_c(),
            limit,
            out_results: &mut results,
        };
        self.status(unsafe { zova_sys::zova_vector_search(&request) })?;
        take_search_results(&mut results)
    }

    pub fn search_vectors_in(
        &mut self,
        collection_name: &str,
        query: VectorValues<'_>,
        candidate_ids: &[&str],
        limit: usize,
    ) -> Result<Vec<VectorSearchResult>> {
        let collection_name = cstring(collection_name, "vector collection name")?;
        let (candidates, candidate_ptrs) = candidate_ptrs(candidate_ids)?;
        let mut results = empty_search_results();
        let request = zova_sys::zova_vector_search_in_request {
            db: self.raw_ptr(),
            collection_name: collection_name.as_ptr(),
            query: query.to_c(),
            candidate_ids: if candidate_ptrs.is_empty() {
                ptr::null()
            } else {
                candidate_ptrs.as_ptr()
            },
            candidate_count: candidate_ptrs.len(),
            limit,
            out_results: &mut results,
        };
        let status = self.status(unsafe { zova_sys::zova_vector_search_in(&request) });
        drop(candidates);
        status?;
        take_search_results(&mut results)
    }

    pub fn search_vectors_within(
        &mut self,
        collection_name: &str,
        query: VectorValues<'_>,
        max_distance: f64,
        limit: usize,
    ) -> Result<Vec<VectorSearchResult>> {
        let collection_name = cstring(collection_name, "vector collection name")?;
        let mut results = empty_search_results();
        let request = zova_sys::zova_vector_search_within_request {
            db: self.raw_ptr(),
            collection_name: collection_name.as_ptr(),
            query: query.to_c(),
            max_distance,
            limit,
            out_results: &mut results,
        };
        self.status(unsafe { zova_sys::zova_vector_search_within(&request) })?;
        take_search_results(&mut results)
    }

    pub fn search_vectors_in_within(
        &mut self,
        collection_name: &str,
        query: VectorValues<'_>,
        candidate_ids: &[&str],
        max_distance: f64,
        limit: usize,
    ) -> Result<Vec<VectorSearchResult>> {
        let collection_name = cstring(collection_name, "vector collection name")?;
        let (candidates, candidate_ptrs) = candidate_ptrs(candidate_ids)?;
        let mut results = empty_search_results();
        let request = zova_sys::zova_vector_search_in_within_request {
            db: self.raw_ptr(),
            collection_name: collection_name.as_ptr(),
            query: query.to_c(),
            candidate_ids: if candidate_ptrs.is_empty() {
                ptr::null()
            } else {
                candidate_ptrs.as_ptr()
            },
            candidate_count: candidate_ptrs.len(),
            max_distance,
            limit,
            out_results: &mut results,
        };
        let status = self.status(unsafe { zova_sys::zova_vector_search_in_within(&request) });
        drop(candidates);
        status?;
        take_search_results(&mut results)
    }

    pub fn search_vectors_by_id(
        &mut self,
        collection_name: &str,
        source_vector_id: &str,
        limit: usize,
    ) -> Result<Vec<VectorSearchResult>> {
        let collection_name = cstring(collection_name, "vector collection name")?;
        let source_vector_id = cstring(source_vector_id, "source vector id")?;
        let mut results = empty_search_results();
        let request = zova_sys::zova_vector_search_by_id_request {
            db: self.raw_ptr(),
            collection_name: collection_name.as_ptr(),
            source_vector_id: source_vector_id.as_ptr(),
            limit,
            out_results: &mut results,
        };
        self.status(unsafe { zova_sys::zova_vector_search_by_id(&request) })?;
        take_search_results(&mut results)
    }

    pub fn search_vectors_by_id_in(
        &mut self,
        collection_name: &str,
        source_vector_id: &str,
        candidate_ids: &[&str],
        limit: usize,
    ) -> Result<Vec<VectorSearchResult>> {
        let collection_name = cstring(collection_name, "vector collection name")?;
        let source_vector_id = cstring(source_vector_id, "source vector id")?;
        let (candidates, candidate_ptrs) = candidate_ptrs(candidate_ids)?;
        let mut results = empty_search_results();
        let request = zova_sys::zova_vector_search_by_id_in_request {
            db: self.raw_ptr(),
            collection_name: collection_name.as_ptr(),
            source_vector_id: source_vector_id.as_ptr(),
            candidate_ids: if candidate_ptrs.is_empty() {
                ptr::null()
            } else {
                candidate_ptrs.as_ptr()
            },
            candidate_count: candidate_ptrs.len(),
            limit,
            out_results: &mut results,
        };
        let status = self.status(unsafe { zova_sys::zova_vector_search_by_id_in(&request) });
        drop(candidates);
        status?;
        take_search_results(&mut results)
    }

    pub fn search_vectors_by_id_within(
        &mut self,
        collection_name: &str,
        source_vector_id: &str,
        max_distance: f64,
        limit: usize,
    ) -> Result<Vec<VectorSearchResult>> {
        let collection_name = cstring(collection_name, "vector collection name")?;
        let source_vector_id = cstring(source_vector_id, "source vector id")?;
        let mut results = empty_search_results();
        let request = zova_sys::zova_vector_search_by_id_within_request {
            db: self.raw_ptr(),
            collection_name: collection_name.as_ptr(),
            source_vector_id: source_vector_id.as_ptr(),
            max_distance,
            limit,
            out_results: &mut results,
        };
        self.status(unsafe { zova_sys::zova_vector_search_by_id_within(&request) })?;
        take_search_results(&mut results)
    }

    pub fn search_vectors_by_id_in_within(
        &mut self,
        collection_name: &str,
        source_vector_id: &str,
        candidate_ids: &[&str],
        max_distance: f64,
        limit: usize,
    ) -> Result<Vec<VectorSearchResult>> {
        let collection_name = cstring(collection_name, "vector collection name")?;
        let source_vector_id = cstring(source_vector_id, "source vector id")?;
        let (candidates, candidate_ptrs) = candidate_ptrs(candidate_ids)?;
        let mut results = empty_search_results();
        let request = zova_sys::zova_vector_search_by_id_in_within_request {
            db: self.raw_ptr(),
            collection_name: collection_name.as_ptr(),
            source_vector_id: source_vector_id.as_ptr(),
            candidate_ids: if candidate_ptrs.is_empty() {
                ptr::null()
            } else {
                candidate_ptrs.as_ptr()
            },
            candidate_count: candidate_ptrs.len(),
            max_distance,
            limit,
            out_results: &mut results,
        };
        let status = self.status(unsafe { zova_sys::zova_vector_search_by_id_in_within(&request) });
        drop(candidates);
        status?;
        take_search_results(&mut results)
    }
}

impl VectorMetric {
    pub(crate) fn to_c(self) -> i32 {
        match self {
            Self::Cosine => zova_sys::ZOVA_VECTOR_METRIC_COSINE,
            Self::L2 => zova_sys::ZOVA_VECTOR_METRIC_L2,
            Self::Dot => zova_sys::ZOVA_VECTOR_METRIC_DOT,
        }
    }

    pub(crate) fn from_c(metric: i32) -> Result<Self> {
        match metric {
            zova_sys::ZOVA_VECTOR_METRIC_COSINE => Ok(Self::Cosine),
            zova_sys::ZOVA_VECTOR_METRIC_L2 => Ok(Self::L2),
            zova_sys::ZOVA_VECTOR_METRIC_DOT => Ok(Self::Dot),
            _ => Err(Error::from_status(zova_sys::ZOVA_INVALID_ARGUMENT, None)),
        }
    }
}

impl VectorElementType {
    pub(crate) fn to_c(self) -> i32 {
        match self {
            Self::F32 => zova_sys::ZOVA_VECTOR_ELEMENT_TYPE_F32,
            Self::F16 => zova_sys::ZOVA_VECTOR_ELEMENT_TYPE_F16,
            Self::I8 => zova_sys::ZOVA_VECTOR_ELEMENT_TYPE_I8,
        }
    }

    pub(crate) fn from_c(element_type: i32) -> Result<Self> {
        match element_type {
            zova_sys::ZOVA_VECTOR_ELEMENT_TYPE_F32 => Ok(Self::F32),
            zova_sys::ZOVA_VECTOR_ELEMENT_TYPE_F16 => Ok(Self::F16),
            zova_sys::ZOVA_VECTOR_ELEMENT_TYPE_I8 => Ok(Self::I8),
            _ => Err(Error::from_status(zova_sys::ZOVA_INVALID_ARGUMENT, None)),
        }
    }
}

impl VectorValues<'_> {
    pub(crate) fn to_c(self) -> zova_sys::zova_vector_values {
        match self {
            VectorValues::F32(values) => zova_sys::zova_vector_values {
                element_type: VectorElementType::F32.to_c(),
                f32_values: values_ptr(values),
                f16_values: ptr::null(),
                i8_values: ptr::null(),
                values_len: values.len(),
            },
            VectorValues::F16(values) => zova_sys::zova_vector_values {
                element_type: VectorElementType::F16.to_c(),
                f32_values: ptr::null(),
                f16_values: u16_values_ptr(values),
                i8_values: ptr::null(),
                values_len: values.len(),
            },
            VectorValues::I8(values) => zova_sys::zova_vector_values {
                element_type: VectorElementType::I8.to_c(),
                f32_values: ptr::null(),
                f16_values: ptr::null(),
                i8_values: i8_values_ptr(values),
                values_len: values.len(),
            },
        }
    }
}

pub(crate) fn values_ptr(values: &[f32]) -> *const f32 {
    if values.is_empty() {
        ptr::null()
    } else {
        values.as_ptr()
    }
}

pub(crate) fn u16_values_ptr(values: &[u16]) -> *const u16 {
    if values.is_empty() {
        ptr::null()
    } else {
        values.as_ptr()
    }
}

pub(crate) fn i8_values_ptr(values: &[i8]) -> *const i8 {
    if values.is_empty() {
        ptr::null()
    } else {
        values.as_ptr()
    }
}

pub(crate) fn candidate_ptrs(
    candidate_ids: &[&str],
) -> Result<(Vec<std::ffi::CString>, Vec<*const c_char>)> {
    let candidates = candidate_ids
        .iter()
        .map(|id| cstring(id, "vector id"))
        .collect::<Result<Vec<_>>>()?;
    let pointers = candidates.iter().map(|id| id.as_ptr()).collect();
    Ok((candidates, pointers))
}

pub(crate) fn vector_inputs(
    vectors: &[VectorInput<'_>],
) -> Result<(Vec<std::ffi::CString>, Vec<zova_sys::zova_vector_input>)> {
    let ids = vectors
        .iter()
        .map(|vector| cstring(vector.id, "vector id"))
        .collect::<Result<Vec<_>>>()?;
    let inputs = vectors
        .iter()
        .zip(ids.iter())
        .map(|(vector, id)| zova_sys::zova_vector_input {
            id: id.as_ptr(),
            values: vector.values.to_c(),
        })
        .collect();
    Ok((ids, inputs))
}

pub(crate) fn empty_vector() -> zova_sys::zova_vector {
    zova_sys::zova_vector {
        id: ptr::null_mut(),
        id_len: 0,
        element_type: zova_sys::ZOVA_VECTOR_ELEMENT_TYPE_F32,
        f32_values: ptr::null_mut(),
        f16_values: ptr::null_mut(),
        i8_values: ptr::null_mut(),
        values_len: 0,
    }
}

pub(crate) fn empty_search_results() -> zova_sys::zova_vector_search_results {
    zova_sys::zova_vector_search_results {
        items: ptr::null_mut(),
        len: 0,
    }
}

pub(crate) fn empty_collection_info() -> zova_sys::zova_vector_collection_info {
    zova_sys::zova_vector_collection_info {
        name: ptr::null_mut(),
        name_len: 0,
        dimensions: 0,
        metric: 0,
        element_type: zova_sys::ZOVA_VECTOR_ELEMENT_TYPE_F32,
        vector_count: 0,
    }
}

fn string_from_parts(data: *const c_char, len: usize) -> Result<String> {
    if data.is_null() {
        return Ok(String::new());
    }
    let bytes = unsafe { std::slice::from_raw_parts(data.cast::<u8>(), len) };
    String::from_utf8(bytes.to_vec()).map_err(|_| Error::InvalidUtf8Text)
}

pub(crate) fn take_vector(vector: &mut zova_sys::zova_vector) -> Result<Vector> {
    let id = string_from_parts(vector.id, vector.id_len);
    let values = match VectorElementType::from_c(vector.element_type)? {
        VectorElementType::F32 => {
            let values = if vector.f32_values.is_null() || vector.values_len == 0 {
                Vec::new()
            } else {
                unsafe { std::slice::from_raw_parts(vector.f32_values, vector.values_len) }.to_vec()
            };
            VectorValuesOwned::F32(values)
        }
        VectorElementType::F16 => {
            let values = if vector.f16_values.is_null() || vector.values_len == 0 {
                Vec::new()
            } else {
                unsafe { std::slice::from_raw_parts(vector.f16_values, vector.values_len) }.to_vec()
            };
            VectorValuesOwned::F16(values)
        }
        VectorElementType::I8 => {
            let values = if vector.i8_values.is_null() || vector.values_len == 0 {
                Vec::new()
            } else {
                unsafe { std::slice::from_raw_parts(vector.i8_values, vector.values_len) }.to_vec()
            };
            VectorValuesOwned::I8(values)
        }
    };
    unsafe {
        zova_sys::zova_vector_free(vector);
    }
    Ok(Vector { id: id?, values })
}

pub(crate) fn take_search_results(
    results: &mut zova_sys::zova_vector_search_results,
) -> Result<Vec<VectorSearchResult>> {
    let items = if results.items.is_null() || results.len == 0 {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(results.items, results.len) }
            .iter()
            .map(|item| {
                Ok(VectorSearchResult {
                    id: string_from_parts(item.id, item.id_len)?,
                    distance: item.distance,
                })
            })
            .collect::<Result<Vec<_>>>()?
    };
    unsafe {
        zova_sys::zova_vector_search_results_free(results);
    }
    Ok(items)
}

pub(crate) fn take_collection_info(
    info: &mut zova_sys::zova_vector_collection_info,
) -> Result<VectorCollectionInfo> {
    let name = string_from_parts(info.name, info.name_len);
    let metric = VectorMetric::from_c(info.metric);
    let element_type = VectorElementType::from_c(info.element_type);
    let out = Ok(VectorCollectionInfo {
        name: name?,
        dimensions: info.dimensions,
        metric: metric?,
        element_type: element_type?,
        vector_count: info.vector_count,
    });
    unsafe {
        zova_sys::zova_vector_collection_info_free(info);
    }
    out
}

pub(crate) fn take_collection_list(
    list: &mut zova_sys::zova_vector_collection_list,
) -> Result<Vec<VectorCollectionInfo>> {
    let items = if list.items.is_null() || list.len == 0 {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(list.items, list.len) }
            .iter()
            .map(|item| {
                Ok(VectorCollectionInfo {
                    name: string_from_parts(item.name, item.name_len)?,
                    dimensions: item.dimensions,
                    metric: VectorMetric::from_c(item.metric)?,
                    element_type: VectorElementType::from_c(item.element_type)?,
                    vector_count: item.vector_count,
                })
            })
            .collect::<Result<Vec<_>>>()?
    };
    unsafe {
        zova_sys::zova_vector_collection_list_free(list);
    }
    Ok(items)
}
