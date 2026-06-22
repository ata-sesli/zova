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
pub struct VectorCollectionOptions {
    pub dimensions: u32,
    pub metric: VectorMetric,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Vector {
    pub id: String,
    pub values: Vec<f32>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VectorCollectionInfo {
    pub name: String,
    pub dimensions: u32,
    pub metric: VectorMetric,
    pub vector_count: u64,
}

#[derive(Debug, Clone, Copy)]
pub struct VectorInput<'a> {
    pub id: &'a str,
    pub values: &'a [f32],
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
        values: &[f32],
    ) -> Result<()> {
        let collection_name = cstring(collection_name, "vector collection name")?;
        let vector_id = cstring(vector_id, "vector id")?;
        let request = zova_sys::zova_vector_put_request {
            db: self.raw_ptr(),
            collection_name: collection_name.as_ptr(),
            vector_id: vector_id.as_ptr(),
            values: values_ptr(values),
            values_len: values.len(),
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
        query: &[f32],
        limit: usize,
    ) -> Result<Vec<VectorSearchResult>> {
        let collection_name = cstring(collection_name, "vector collection name")?;
        let mut results = empty_search_results();
        let request = zova_sys::zova_vector_search_request {
            db: self.raw_ptr(),
            collection_name: collection_name.as_ptr(),
            query: values_ptr(query),
            query_len: query.len(),
            limit,
            out_results: &mut results,
        };
        self.status(unsafe { zova_sys::zova_vector_search(&request) })?;
        take_search_results(&mut results)
    }

    pub fn search_vectors_in(
        &mut self,
        collection_name: &str,
        query: &[f32],
        candidate_ids: &[&str],
        limit: usize,
    ) -> Result<Vec<VectorSearchResult>> {
        let collection_name = cstring(collection_name, "vector collection name")?;
        let (candidates, candidate_ptrs) = candidate_ptrs(candidate_ids)?;
        let mut results = empty_search_results();
        let request = zova_sys::zova_vector_search_in_request {
            db: self.raw_ptr(),
            collection_name: collection_name.as_ptr(),
            query: values_ptr(query),
            query_len: query.len(),
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
        query: &[f32],
        max_distance: f64,
        limit: usize,
    ) -> Result<Vec<VectorSearchResult>> {
        let collection_name = cstring(collection_name, "vector collection name")?;
        let mut results = empty_search_results();
        let request = zova_sys::zova_vector_search_within_request {
            db: self.raw_ptr(),
            collection_name: collection_name.as_ptr(),
            query: values_ptr(query),
            query_len: query.len(),
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
        query: &[f32],
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
            query: values_ptr(query),
            query_len: query.len(),
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
    fn to_c(self) -> i32 {
        match self {
            Self::Cosine => zova_sys::ZOVA_VECTOR_METRIC_COSINE,
            Self::L2 => zova_sys::ZOVA_VECTOR_METRIC_L2,
            Self::Dot => zova_sys::ZOVA_VECTOR_METRIC_DOT,
        }
    }

    fn from_c(metric: i32) -> Result<Self> {
        match metric {
            zova_sys::ZOVA_VECTOR_METRIC_COSINE => Ok(Self::Cosine),
            zova_sys::ZOVA_VECTOR_METRIC_L2 => Ok(Self::L2),
            zova_sys::ZOVA_VECTOR_METRIC_DOT => Ok(Self::Dot),
            _ => Err(Error::from_status(zova_sys::ZOVA_INVALID_ARGUMENT, None)),
        }
    }
}

fn values_ptr(values: &[f32]) -> *const f32 {
    if values.is_empty() {
        ptr::null()
    } else {
        values.as_ptr()
    }
}

fn candidate_ptrs(candidate_ids: &[&str]) -> Result<(Vec<std::ffi::CString>, Vec<*const c_char>)> {
    let candidates = candidate_ids
        .iter()
        .map(|id| cstring(id, "vector id"))
        .collect::<Result<Vec<_>>>()?;
    let pointers = candidates.iter().map(|id| id.as_ptr()).collect();
    Ok((candidates, pointers))
}

fn vector_inputs(
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
            values: values_ptr(vector.values),
            values_len: vector.values.len(),
        })
        .collect();
    Ok((ids, inputs))
}

fn empty_vector() -> zova_sys::zova_vector {
    zova_sys::zova_vector {
        id: ptr::null_mut(),
        id_len: 0,
        values: ptr::null_mut(),
        values_len: 0,
    }
}

fn empty_search_results() -> zova_sys::zova_vector_search_results {
    zova_sys::zova_vector_search_results {
        items: ptr::null_mut(),
        len: 0,
    }
}

fn empty_collection_info() -> zova_sys::zova_vector_collection_info {
    zova_sys::zova_vector_collection_info {
        name: ptr::null_mut(),
        name_len: 0,
        dimensions: 0,
        metric: 0,
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

fn take_vector(vector: &mut zova_sys::zova_vector) -> Result<Vector> {
    let id = string_from_parts(vector.id, vector.id_len);
    let values = if vector.values.is_null() || vector.values_len == 0 {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(vector.values, vector.values_len) }.to_vec()
    };
    unsafe {
        zova_sys::zova_vector_free(vector);
    }
    Ok(Vector { id: id?, values })
}

fn take_search_results(
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

fn take_collection_info(
    info: &mut zova_sys::zova_vector_collection_info,
) -> Result<VectorCollectionInfo> {
    let name = string_from_parts(info.name, info.name_len);
    let metric = VectorMetric::from_c(info.metric);
    let out = Ok(VectorCollectionInfo {
        name: name?,
        dimensions: info.dimensions,
        metric: metric?,
        vector_count: info.vector_count,
    });
    unsafe {
        zova_sys::zova_vector_collection_info_free(info);
    }
    out
}

fn take_collection_list(
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
