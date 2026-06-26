use crate::error::{closed_error, zova_error};
use crate::object::{
    chunk_id_from_py, manifest_chunks_from_py, object_id_from_py, PyObjectId, PyObjectManifest,
    PyObjectWriter,
};
use crate::statement::PyStatement;
use crate::vector::{
    candidate_refs, options_from_py, py_collection_info, py_search_results, py_vector,
    vector_input_refs, vector_inputs_from_py, PyVector, PyVectorCollectionInfo,
    PyVectorSearchResult,
};
use pyo3::prelude::*;
use pyo3::types::{PyAny, PyBytes};

#[pyclass(name = "Database", unsendable)]
pub(crate) struct PyDatabase {
    inner: Option<zova_rust::Database>,
}

#[pyclass(name = "SavepointContext", unsendable)]
pub(crate) struct PySavepointContext {
    database: Py<PyDatabase>,
    name: String,
    active: bool,
}

#[pymethods]
impl PyDatabase {
    #[staticmethod]
    pub(crate) fn create(path: &str) -> PyResult<Self> {
        Ok(Self {
            inner: Some(zova_rust::Database::create(path).map_err(zova_error)?),
        })
    }

    #[staticmethod]
    #[pyo3(signature = (path, *, read_only = false, busy_timeout_ms = 0))]
    pub(crate) fn open(path: &str, read_only: bool, busy_timeout_ms: u32) -> PyResult<Self> {
        Ok(Self {
            inner: Some(
                zova_rust::Database::open_with_options(
                    path,
                    zova_rust::OpenOptions {
                        read_only,
                        busy_timeout_ms,
                    },
                )
                .map_err(zova_error)?,
            ),
        })
    }

    pub(crate) fn close(&mut self) {
        self.inner.take();
    }

    pub(crate) fn exec(&mut self, sql: &str) -> PyResult<()> {
        self.db_mut()?.exec(sql).map_err(zova_error)
    }

    pub(crate) fn prepare(&mut self, sql: &str) -> PyResult<PyStatement> {
        let statement = self.db_mut()?.prepare_owned(sql).map_err(zova_error)?;
        Ok(PyStatement::new(statement))
    }

    pub(crate) fn begin(&mut self) -> PyResult<()> {
        self.db_mut()?.begin().map_err(zova_error)
    }

    pub(crate) fn begin_immediate(&mut self) -> PyResult<()> {
        self.db_mut()?.begin_immediate().map_err(zova_error)
    }

    pub(crate) fn commit(&mut self) -> PyResult<()> {
        self.db_mut()?.commit().map_err(zova_error)
    }

    pub(crate) fn rollback(&mut self) -> PyResult<()> {
        self.db_mut()?.rollback().map_err(zova_error)
    }

    pub(crate) fn savepoint(&mut self, name: &str) -> PyResult<()> {
        self.db_mut()?.savepoint(name).map_err(zova_error)
    }

    pub(crate) fn rollback_to_savepoint(&mut self, name: &str) -> PyResult<()> {
        self.db_mut()?
            .rollback_to_savepoint(name)
            .map_err(zova_error)
    }

    pub(crate) fn release_savepoint(&mut self, name: &str) -> PyResult<()> {
        self.db_mut()?.release_savepoint(name).map_err(zova_error)
    }

    pub(crate) fn savepoint_context(slf: Py<Self>, name: &str) -> PySavepointContext {
        PySavepointContext {
            database: slf,
            name: name.to_owned(),
            active: false,
        }
    }

    pub(crate) fn vacuum(&mut self) -> PyResult<()> {
        self.db_mut()?.vacuum().map_err(zova_error)
    }

    #[pyo3(signature = (destination, *, verify = true))]
    pub(crate) fn backup_to(&mut self, destination: &str, verify: bool) -> PyResult<()> {
        self.db_mut()?
            .backup_to(destination, zova_rust::BackupOptions { verify })
            .map_err(zova_error)
    }

    #[pyo3(signature = (destination, *, verify = true))]
    pub(crate) fn compact_to(&mut self, destination: &str, verify: bool) -> PyResult<()> {
        self.db_mut()?
            .compact_to(destination, zova_rust::CompactOptions { verify })
            .map_err(zova_error)
    }

    pub(crate) fn set_busy_timeout(&mut self, milliseconds: u32) -> PyResult<()> {
        self.db_mut()?
            .set_busy_timeout(milliseconds)
            .map_err(zova_error)
    }

    pub(crate) fn last_insert_rowid(&mut self) -> PyResult<i64> {
        self.db_mut()?.last_insert_rowid().map_err(zova_error)
    }

    pub(crate) fn changes(&mut self) -> PyResult<i64> {
        self.db_mut()?.changes().map_err(zova_error)
    }

    pub(crate) fn total_changes(&mut self) -> PyResult<i64> {
        self.db_mut()?.total_changes().map_err(zova_error)
    }

    pub(crate) fn put_object(&mut self, data: Vec<u8>) -> PyResult<PyObjectId> {
        Ok(PyObjectId::from_rust(
            self.db_mut()?.put_object(&data).map_err(zova_error)?,
        ))
    }

    pub(crate) fn get_object<'py>(
        &mut self,
        py: Python<'py>,
        id: &Bound<'_, PyAny>,
    ) -> PyResult<Bound<'py, PyBytes>> {
        let id = object_id_from_py(id)?;
        let data = self.db_mut()?.get_object(id).map_err(zova_error)?;
        Ok(PyBytes::new(py, &data))
    }

    pub(crate) fn read_object_range<'py>(
        &mut self,
        py: Python<'py>,
        id: &Bound<'_, PyAny>,
        offset: u64,
        size: usize,
    ) -> PyResult<Bound<'py, PyBytes>> {
        let id = object_id_from_py(id)?;
        let mut buffer = vec![0; size];
        let copied = self
            .db_mut()?
            .read_object_range(id, offset, &mut buffer)
            .map_err(zova_error)?;
        buffer.truncate(copied);
        Ok(PyBytes::new(py, &buffer))
    }

    pub(crate) fn has_object(&mut self, id: &Bound<'_, PyAny>) -> PyResult<bool> {
        let id = object_id_from_py(id)?;
        self.db_mut()?.has_object(id).map_err(zova_error)
    }

    pub(crate) fn object_size(&mut self, id: &Bound<'_, PyAny>) -> PyResult<u64> {
        let id = object_id_from_py(id)?;
        self.db_mut()?.object_size(id).map_err(zova_error)
    }

    pub(crate) fn object_chunk_count(&mut self, id: &Bound<'_, PyAny>) -> PyResult<u64> {
        let id = object_id_from_py(id)?;
        self.db_mut()?.object_chunk_count(id).map_err(zova_error)
    }

    pub(crate) fn delete_object(&mut self, id: &Bound<'_, PyAny>) -> PyResult<()> {
        let id = object_id_from_py(id)?;
        self.db_mut()?.delete_object(id).map_err(zova_error)
    }

    pub(crate) fn object_manifest(&mut self, id: &Bound<'_, PyAny>) -> PyResult<PyObjectManifest> {
        let id = object_id_from_py(id)?;
        let manifest = self.db_mut()?.object_manifest(id).map_err(zova_error)?;
        Ok(PyObjectManifest::from_rust(manifest))
    }

    pub(crate) fn get_object_chunk<'py>(
        &mut self,
        py: Python<'py>,
        hash: &Bound<'_, PyAny>,
    ) -> PyResult<Bound<'py, PyBytes>> {
        let hash = chunk_id_from_py(hash)?;
        let data = self.db_mut()?.get_object_chunk(hash).map_err(zova_error)?;
        Ok(PyBytes::new(py, &data))
    }

    pub(crate) fn has_object_chunk(&mut self, hash: &Bound<'_, PyAny>) -> PyResult<bool> {
        let hash = chunk_id_from_py(hash)?;
        self.db_mut()?.has_object_chunk(hash).map_err(zova_error)
    }

    pub(crate) fn put_object_chunk(
        &mut self,
        expected_hash: &Bound<'_, PyAny>,
        data: Vec<u8>,
    ) -> PyResult<()> {
        let expected_hash = chunk_id_from_py(expected_hash)?;
        self.db_mut()?
            .put_object_chunk(expected_hash, &data)
            .map_err(zova_error)
    }

    pub(crate) fn delete_object_chunk(&mut self, hash: &Bound<'_, PyAny>) -> PyResult<bool> {
        let hash = chunk_id_from_py(hash)?;
        self.db_mut()?.delete_object_chunk(hash).map_err(zova_error)
    }

    pub(crate) fn assemble_object_from_chunks(
        &mut self,
        id: &Bound<'_, PyAny>,
        size_bytes: u64,
        chunks: &Bound<'_, PyAny>,
    ) -> PyResult<()> {
        let id = object_id_from_py(id)?;
        let chunks = manifest_chunks_from_py(chunks)?;
        self.db_mut()?
            .assemble_object_from_chunks(id, size_bytes, &chunks)
            .map_err(zova_error)
    }

    pub(crate) fn object_writer(&mut self) -> PyResult<PyObjectWriter> {
        Ok(PyObjectWriter {
            inner: Some(self.db_mut()?.object_writer_owned().map_err(zova_error)?),
        })
    }

    pub(crate) fn create_vector_collection(
        &mut self,
        name: &str,
        options: &Bound<'_, PyAny>,
    ) -> PyResult<()> {
        let options = options_from_py(options)?;
        self.db_mut()?
            .create_vector_collection(name, options)
            .map_err(zova_error)
    }

    pub(crate) fn has_vector_collection(&mut self, name: &str) -> PyResult<bool> {
        self.db_mut()?
            .has_vector_collection(name)
            .map_err(zova_error)
    }

    pub(crate) fn vector_collection_info(
        &mut self,
        name: &str,
    ) -> PyResult<PyVectorCollectionInfo> {
        let info = self
            .db_mut()?
            .vector_collection_info(name)
            .map_err(zova_error)?;
        Ok(py_collection_info(info))
    }

    pub(crate) fn list_vector_collections(&mut self) -> PyResult<Vec<PyVectorCollectionInfo>> {
        let collections = self
            .db_mut()?
            .list_vector_collections()
            .map_err(zova_error)?;
        Ok(collections.into_iter().map(py_collection_info).collect())
    }

    pub(crate) fn delete_vector_collection(&mut self, name: &str) -> PyResult<()> {
        self.db_mut()?
            .delete_vector_collection(name)
            .map_err(zova_error)
    }

    pub(crate) fn put_vector(
        &mut self,
        collection_name: &str,
        vector_id: &str,
        values: Vec<f32>,
    ) -> PyResult<()> {
        self.db_mut()?
            .put_vector(collection_name, vector_id, &values)
            .map_err(zova_error)
    }

    pub(crate) fn put_vectors(
        &mut self,
        collection_name: &str,
        vectors: &Bound<'_, PyAny>,
    ) -> PyResult<()> {
        let owned = vector_inputs_from_py(vectors)?;
        let refs = vector_input_refs(&owned);
        self.db_mut()?
            .put_vectors(collection_name, &refs)
            .map_err(zova_error)
    }

    pub(crate) fn get_vector(
        &mut self,
        collection_name: &str,
        vector_id: &str,
    ) -> PyResult<PyVector> {
        let vector = self
            .db_mut()?
            .get_vector(collection_name, vector_id)
            .map_err(zova_error)?;
        Ok(py_vector(vector))
    }

    pub(crate) fn has_vector(&mut self, collection_name: &str, vector_id: &str) -> PyResult<bool> {
        self.db_mut()?
            .has_vector(collection_name, vector_id)
            .map_err(zova_error)
    }

    pub(crate) fn delete_vector(&mut self, collection_name: &str, vector_id: &str) -> PyResult<()> {
        self.db_mut()?
            .delete_vector(collection_name, vector_id)
            .map_err(zova_error)
    }

    pub(crate) fn search_vectors(
        &mut self,
        collection_name: &str,
        query: Vec<f32>,
        limit: usize,
    ) -> PyResult<Vec<PyVectorSearchResult>> {
        let results = self
            .db_mut()?
            .search_vectors(collection_name, &query, limit)
            .map_err(zova_error)?;
        Ok(py_search_results(results))
    }

    pub(crate) fn search_vectors_in(
        &mut self,
        collection_name: &str,
        query: Vec<f32>,
        candidate_ids: Vec<String>,
        limit: usize,
    ) -> PyResult<Vec<PyVectorSearchResult>> {
        let candidates = candidate_refs(&candidate_ids);
        let results = self
            .db_mut()?
            .search_vectors_in(collection_name, &query, &candidates, limit)
            .map_err(zova_error)?;
        Ok(py_search_results(results))
    }

    pub(crate) fn search_vectors_within(
        &mut self,
        collection_name: &str,
        query: Vec<f32>,
        max_distance: f64,
        limit: usize,
    ) -> PyResult<Vec<PyVectorSearchResult>> {
        let results = self
            .db_mut()?
            .search_vectors_within(collection_name, &query, max_distance, limit)
            .map_err(zova_error)?;
        Ok(py_search_results(results))
    }

    pub(crate) fn search_vectors_in_within(
        &mut self,
        collection_name: &str,
        query: Vec<f32>,
        candidate_ids: Vec<String>,
        max_distance: f64,
        limit: usize,
    ) -> PyResult<Vec<PyVectorSearchResult>> {
        let candidates = candidate_refs(&candidate_ids);
        let results = self
            .db_mut()?
            .search_vectors_in_within(collection_name, &query, &candidates, max_distance, limit)
            .map_err(zova_error)?;
        Ok(py_search_results(results))
    }

    pub(crate) fn search_vectors_by_id(
        &mut self,
        collection_name: &str,
        source_vector_id: &str,
        limit: usize,
    ) -> PyResult<Vec<PyVectorSearchResult>> {
        let results = self
            .db_mut()?
            .search_vectors_by_id(collection_name, source_vector_id, limit)
            .map_err(zova_error)?;
        Ok(py_search_results(results))
    }

    pub(crate) fn search_vectors_by_id_in(
        &mut self,
        collection_name: &str,
        source_vector_id: &str,
        candidate_ids: Vec<String>,
        limit: usize,
    ) -> PyResult<Vec<PyVectorSearchResult>> {
        let candidates = candidate_refs(&candidate_ids);
        let results = self
            .db_mut()?
            .search_vectors_by_id_in(collection_name, source_vector_id, &candidates, limit)
            .map_err(zova_error)?;
        Ok(py_search_results(results))
    }

    pub(crate) fn search_vectors_by_id_within(
        &mut self,
        collection_name: &str,
        source_vector_id: &str,
        max_distance: f64,
        limit: usize,
    ) -> PyResult<Vec<PyVectorSearchResult>> {
        let results = self
            .db_mut()?
            .search_vectors_by_id_within(collection_name, source_vector_id, max_distance, limit)
            .map_err(zova_error)?;
        Ok(py_search_results(results))
    }

    pub(crate) fn search_vectors_by_id_in_within(
        &mut self,
        collection_name: &str,
        source_vector_id: &str,
        candidate_ids: Vec<String>,
        max_distance: f64,
        limit: usize,
    ) -> PyResult<Vec<PyVectorSearchResult>> {
        let candidates = candidate_refs(&candidate_ids);
        let results = self
            .db_mut()?
            .search_vectors_by_id_in_within(
                collection_name,
                source_vector_id,
                &candidates,
                max_distance,
                limit,
            )
            .map_err(zova_error)?;
        Ok(py_search_results(results))
    }

    pub(crate) fn __enter__(slf: PyRefMut<'_, Self>) -> PyRefMut<'_, Self> {
        slf
    }

    pub(crate) fn __exit__(
        &mut self,
        _exc_type: Option<&Bound<'_, PyAny>>,
        _exc_value: Option<&Bound<'_, PyAny>>,
        _traceback: Option<&Bound<'_, PyAny>>,
    ) -> bool {
        self.close();
        false
    }
}

impl PyDatabase {
    pub(crate) fn db_mut(&mut self) -> PyResult<&mut zova_rust::Database> {
        self.inner.as_mut().ok_or_else(|| closed_error("database"))
    }
}

#[pymethods]
impl PySavepointContext {
    pub(crate) fn __enter__(&mut self, py: Python<'_>) -> PyResult<Py<PyDatabase>> {
        self.database
            .borrow_mut(py)
            .savepoint(&self.name)
            .map_err(|err| err)?;
        self.active = true;
        Ok(self.database.clone_ref(py))
    }

    pub(crate) fn __exit__(
        &mut self,
        py: Python<'_>,
        exc_type: Option<&Bound<'_, PyAny>>,
        _exc_value: Option<&Bound<'_, PyAny>>,
        _traceback: Option<&Bound<'_, PyAny>>,
    ) -> PyResult<bool> {
        if !self.active {
            return Ok(false);
        }
        self.active = false;

        let mut database = self.database.borrow_mut(py);
        if exc_type.is_some() {
            database.rollback_to_savepoint(&self.name)?;
            database.release_savepoint(&self.name)?;
            return Ok(false);
        }
        database.release_savepoint(&self.name)?;
        Ok(false)
    }
}

#[pyfunction]
pub(crate) fn convert_sqlite_to_zova(source: &str, destination: &str) -> PyResult<()> {
    zova_rust::Database::convert_sqlite_to_zova(source, destination).map_err(zova_error)
}

#[pyfunction]
#[pyo3(signature = (source, destination, *, verify = true))]
pub(crate) fn restore_backup(source: &str, destination: &str, verify: bool) -> PyResult<()> {
    zova_rust::restore_backup(source, destination, zova_rust::RestoreOptions { verify })
        .map_err(zova_error)
}
