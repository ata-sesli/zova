use crate::error::{closed_error, zova_error};
use pyo3::basic::CompareOp;
use pyo3::prelude::*;
use pyo3::types::{PyAny, PyBytes};
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

#[pyclass(name = "ObjectId", frozen, skip_from_py_object)]
#[derive(Clone, Copy)]
pub(crate) struct PyObjectId {
    bytes: [u8; 32],
}

#[pyclass(name = "ObjectChunkId", frozen, skip_from_py_object)]
#[derive(Clone, Copy)]
pub(crate) struct PyObjectChunkId {
    bytes: [u8; 32],
}

#[pyclass(name = "ObjectManifestChunk", frozen, skip_from_py_object)]
#[derive(Clone)]
pub(crate) struct PyObjectManifestChunk {
    index: u64,
    hash: PyObjectChunkId,
    offset: u64,
    size_bytes: u64,
}

#[pyclass(name = "ObjectManifest", frozen, skip_from_py_object)]
#[derive(Clone)]
pub(crate) struct PyObjectManifest {
    object_id: PyObjectId,
    size_bytes: u64,
    chunk_count: u64,
    chunker: String,
    chunks: Vec<PyObjectManifestChunk>,
}

#[pyclass(name = "ObjectWriter", unsendable)]
pub(crate) struct PyObjectWriter {
    pub(crate) inner: Option<zova_rust::OwnedObjectWriter>,
}

#[pyfunction]
pub(crate) fn object_id(data: Vec<u8>) -> PyResult<PyObjectId> {
    Ok(PyObjectId::from_rust(
        zova_rust::object_id(&data).map_err(zova_error)?,
    ))
}

#[pyfunction]
pub(crate) fn object_chunk_id(data: Vec<u8>) -> PyResult<PyObjectChunkId> {
    Ok(PyObjectChunkId::from_rust(
        zova_rust::object_chunk_id(&data).map_err(zova_error)?,
    ))
}

#[pymethods]
impl PyObjectId {
    #[new]
    pub(crate) fn new(bytes: Vec<u8>) -> PyResult<Self> {
        let bytes = exact_32(bytes, "ObjectId")?;
        Ok(Self { bytes })
    }

    #[getter]
    pub(crate) fn bytes<'py>(&self, py: Python<'py>) -> Bound<'py, PyBytes> {
        PyBytes::new(py, &self.bytes)
    }

    pub(crate) fn hex(&self) -> String {
        hex_lower(&self.bytes)
    }

    pub(crate) fn __bytes__<'py>(&self, py: Python<'py>) -> Bound<'py, PyBytes> {
        PyBytes::new(py, &self.bytes)
    }

    pub(crate) fn __repr__(&self) -> String {
        format!("ObjectId('{}')", self.hex())
    }

    pub(crate) fn __richcmp__(&self, other: PyRef<'_, Self>, op: CompareOp) -> PyResult<bool> {
        richcmp_bytes(&self.bytes, &other.bytes, op)
    }

    pub(crate) fn __hash__(&self) -> isize {
        hash_bytes(&self.bytes)
    }
}

#[pymethods]
impl PyObjectChunkId {
    #[new]
    pub(crate) fn new(bytes: Vec<u8>) -> PyResult<Self> {
        let bytes = exact_32(bytes, "ObjectChunkId")?;
        Ok(Self { bytes })
    }

    #[getter]
    pub(crate) fn bytes<'py>(&self, py: Python<'py>) -> Bound<'py, PyBytes> {
        PyBytes::new(py, &self.bytes)
    }

    pub(crate) fn hex(&self) -> String {
        hex_lower(&self.bytes)
    }

    pub(crate) fn __bytes__<'py>(&self, py: Python<'py>) -> Bound<'py, PyBytes> {
        PyBytes::new(py, &self.bytes)
    }

    pub(crate) fn __repr__(&self) -> String {
        format!("ObjectChunkId('{}')", self.hex())
    }

    pub(crate) fn __richcmp__(&self, other: PyRef<'_, Self>, op: CompareOp) -> PyResult<bool> {
        richcmp_bytes(&self.bytes, &other.bytes, op)
    }

    pub(crate) fn __hash__(&self) -> isize {
        hash_bytes(&self.bytes)
    }
}

#[pymethods]
impl PyObjectManifestChunk {
    #[new]
    pub(crate) fn new(
        index: u64,
        hash: &Bound<'_, PyAny>,
        offset: u64,
        size_bytes: u64,
    ) -> PyResult<Self> {
        Ok(Self {
            index,
            hash: PyObjectChunkId::from_rust(chunk_id_from_py(hash)?),
            offset,
            size_bytes,
        })
    }

    #[getter]
    pub(crate) fn index(&self) -> u64 {
        self.index
    }

    #[getter]
    pub(crate) fn hash(&self) -> PyObjectChunkId {
        self.hash
    }

    #[getter]
    pub(crate) fn offset(&self) -> u64 {
        self.offset
    }

    #[getter]
    pub(crate) fn size_bytes(&self) -> u64 {
        self.size_bytes
    }

    pub(crate) fn __repr__(&self) -> String {
        format!(
            "ObjectManifestChunk(index={}, hash={}, offset={}, size_bytes={})",
            self.index,
            self.hash.hex(),
            self.offset,
            self.size_bytes
        )
    }
}

#[pymethods]
impl PyObjectManifest {
    #[getter]
    pub(crate) fn object_id(&self) -> PyObjectId {
        self.object_id
    }

    #[getter]
    pub(crate) fn size_bytes(&self) -> u64 {
        self.size_bytes
    }

    #[getter]
    pub(crate) fn chunk_count(&self) -> u64 {
        self.chunk_count
    }

    #[getter]
    pub(crate) fn chunker(&self) -> String {
        self.chunker.clone()
    }

    #[getter]
    pub(crate) fn chunks(&self) -> Vec<PyObjectManifestChunk> {
        self.chunks.clone()
    }

    pub(crate) fn __repr__(&self) -> String {
        format!(
            "ObjectManifest(object_id={}, size_bytes={}, chunk_count={}, chunker='{}')",
            self.object_id.hex(),
            self.size_bytes,
            self.chunk_count,
            self.chunker
        )
    }
}

#[pymethods]
impl PyObjectWriter {
    pub(crate) fn write(&mut self, data: Vec<u8>) -> PyResult<()> {
        self.writer_mut()?.write(&data).map_err(zova_error)
    }

    pub(crate) fn finish(&mut self) -> PyResult<PyObjectId> {
        let writer = self
            .inner
            .take()
            .ok_or_else(|| closed_error("object writer"))?;
        Ok(PyObjectId::from_rust(writer.finish().map_err(zova_error)?))
    }

    pub(crate) fn cancel(&mut self) -> PyResult<()> {
        let writer = self
            .inner
            .take()
            .ok_or_else(|| closed_error("object writer"))?;
        writer.cancel().map_err(zova_error)
    }

    pub(crate) fn close(&mut self) -> PyResult<()> {
        if let Some(writer) = self.inner.take() {
            writer.cancel().map_err(zova_error)?;
        }
        Ok(())
    }

    pub(crate) fn __enter__(slf: PyRefMut<'_, Self>) -> PyRefMut<'_, Self> {
        slf
    }

    pub(crate) fn __exit__(
        &mut self,
        _exc_type: Option<&Bound<'_, PyAny>>,
        _exc_value: Option<&Bound<'_, PyAny>>,
        _traceback: Option<&Bound<'_, PyAny>>,
    ) -> PyResult<bool> {
        self.close()?;
        Ok(false)
    }
}

impl PyObjectWriter {
    fn writer_mut(&mut self) -> PyResult<&mut zova_rust::OwnedObjectWriter> {
        self.inner
            .as_mut()
            .ok_or_else(|| closed_error("object writer"))
    }
}

impl PyObjectId {
    pub(crate) fn from_rust(id: zova_rust::ObjectId) -> Self {
        Self {
            bytes: id.into_bytes(),
        }
    }

    fn to_rust(self) -> zova_rust::ObjectId {
        zova_rust::ObjectId::from(self.bytes)
    }
}

impl PyObjectChunkId {
    pub(crate) fn from_rust(id: zova_rust::ObjectChunkId) -> Self {
        Self {
            bytes: id.into_bytes(),
        }
    }

    fn to_rust(self) -> zova_rust::ObjectChunkId {
        zova_rust::ObjectChunkId::from(self.bytes)
    }
}

impl PyObjectManifestChunk {
    pub(crate) fn from_rust(chunk: zova_rust::ObjectManifestChunk) -> Self {
        Self {
            index: chunk.index,
            hash: PyObjectChunkId::from_rust(chunk.hash),
            offset: chunk.offset,
            size_bytes: chunk.size_bytes,
        }
    }

    fn to_rust(&self) -> zova_rust::ObjectManifestChunk {
        zova_rust::ObjectManifestChunk {
            index: self.index,
            hash: self.hash.to_rust(),
            offset: self.offset,
            size_bytes: self.size_bytes,
        }
    }
}

impl PyObjectManifest {
    pub(crate) fn from_rust(manifest: zova_rust::ObjectManifest) -> Self {
        Self {
            object_id: PyObjectId::from_rust(manifest.object_id),
            size_bytes: manifest.size_bytes,
            chunk_count: manifest.chunk_count,
            chunker: manifest.chunker,
            chunks: manifest
                .chunks
                .into_iter()
                .map(PyObjectManifestChunk::from_rust)
                .collect(),
        }
    }
}

fn exact_32(bytes: Vec<u8>, name: &str) -> PyResult<[u8; 32]> {
    bytes.try_into().map_err(|bytes: Vec<u8>| {
        pyo3::exceptions::PyValueError::new_err(format!(
            "{name} requires exactly 32 bytes, got {}",
            bytes.len()
        ))
    })
}

pub(crate) fn object_id_from_py(value: &Bound<'_, PyAny>) -> PyResult<zova_rust::ObjectId> {
    let id = value.extract::<PyRef<'_, PyObjectId>>()?;
    Ok(id.to_rust())
}

pub(crate) fn chunk_id_from_py(value: &Bound<'_, PyAny>) -> PyResult<zova_rust::ObjectChunkId> {
    let id = value.extract::<PyRef<'_, PyObjectChunkId>>()?;
    Ok(id.to_rust())
}

pub(crate) fn manifest_chunks_from_py(
    value: &Bound<'_, PyAny>,
) -> PyResult<Vec<zova_rust::ObjectManifestChunk>> {
    let mut chunks = Vec::new();
    for item in value.try_iter()? {
        let item = item?;
        let chunk = item.extract::<PyRef<'_, PyObjectManifestChunk>>()?;
        chunks.push(chunk.to_rust());
    }
    Ok(chunks)
}

fn richcmp_bytes(lhs: &[u8; 32], rhs: &[u8; 32], op: CompareOp) -> PyResult<bool> {
    match op {
        CompareOp::Eq => Ok(lhs == rhs),
        CompareOp::Ne => Ok(lhs != rhs),
        _ => Err(pyo3::exceptions::PyTypeError::new_err(
            "object ids only support equality comparisons",
        )),
    }
}

fn hash_bytes(bytes: &[u8; 32]) -> isize {
    let mut hasher = DefaultHasher::new();
    bytes.hash(&mut hasher);
    hasher.finish() as isize
}

fn hex_lower(bytes: &[u8; 32]) -> String {
    let mut out = String::with_capacity(64);
    for byte in bytes {
        use std::fmt::Write;
        let _ = write!(&mut out, "{byte:02x}");
    }
    out
}
