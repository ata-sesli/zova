use crate::error::{closed_error, zova_error};
use crate::object::{
    chunk_id_from_py, manifest_chunks_from_py, object_id_from_py, PyObjectId, PyObjectManifest,
    PyObjectWriter,
};
use crate::statement::PyStatement;
use pyo3::prelude::*;
use pyo3::types::{PyAny, PyBytes};

#[pyclass(name = "Database", unsendable)]
pub(crate) struct PyDatabase {
    inner: Option<zova_rust::Database>,
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
    pub(crate) fn open(path: &str) -> PyResult<Self> {
        Ok(Self {
            inner: Some(zova_rust::Database::open(path).map_err(zova_error)?),
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

    pub(crate) fn vacuum(&mut self) -> PyResult<()> {
        self.db_mut()?.vacuum().map_err(zova_error)
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

#[pyfunction]
pub(crate) fn convert_sqlite_to_zova(source: &str, destination: &str) -> PyResult<()> {
    zova_rust::Database::convert_sqlite_to_zova(source, destination).map_err(zova_error)
}
