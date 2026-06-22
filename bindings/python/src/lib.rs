mod database;
mod error;
mod object;
mod statement;
mod vector;

use database::{convert_sqlite_to_zova, PyDatabase};
use error::{ClosedHandleError, ZovaError};
use object::{
    object_chunk_id, object_id, PyObjectChunkId, PyObjectId, PyObjectManifest,
    PyObjectManifestChunk, PyObjectWriter,
};
use pyo3::prelude::*;
use statement::PyStatement;
use vector::{
    encode_f32_le, PyVector, PyVectorCollectionInfo, PyVectorCollectionOptions, PyVectorInput,
    PyVectorSearchResult,
};

#[pymodule]
fn _native(py: Python<'_>, m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add("ZovaError", py.get_type::<ZovaError>())?;
    m.add("ClosedHandleError", py.get_type::<ClosedHandleError>())?;
    m.add_class::<PyDatabase>()?;
    m.add_class::<PyStatement>()?;
    m.add_class::<PyObjectId>()?;
    m.add_class::<PyObjectChunkId>()?;
    m.add_class::<PyObjectManifestChunk>()?;
    m.add_class::<PyObjectManifest>()?;
    m.add_class::<PyObjectWriter>()?;
    m.add_class::<PyVectorCollectionOptions>()?;
    m.add_class::<PyVectorCollectionInfo>()?;
    m.add_class::<PyVector>()?;
    m.add_class::<PyVectorInput>()?;
    m.add_class::<PyVectorSearchResult>()?;
    m.add_function(wrap_pyfunction!(convert_sqlite_to_zova, m)?)?;
    m.add_function(wrap_pyfunction!(object_id, m)?)?;
    m.add_function(wrap_pyfunction!(object_chunk_id, m)?)?;
    m.add_function(wrap_pyfunction!(encode_f32_le, m)?)?;
    Ok(())
}
