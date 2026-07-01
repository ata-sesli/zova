mod database;
mod error;
mod graph;
mod notification;
mod object;
mod statement;
mod vector;

use database::{convert_sqlite_to_zova, restore_backup, PyDatabase, PySavepointContext};
use error::{ClosedHandleError, ZovaError};
use graph::{
    PyGraphEdge, PyGraphEdgeInput, PyGraphInfo, PyGraphNeighbor, PyGraphNeighborsOptions,
    PyGraphNode, PyGraphNodeInput, PyGraphWalkItem, PyGraphWalkOptions,
};
use notification::{PyNotification, PySubscription};
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
    m.add_class::<PySavepointContext>()?;
    m.add_class::<PyNotification>()?;
    m.add_class::<PySubscription>()?;
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
    m.add_class::<PyGraphInfo>()?;
    m.add_class::<PyGraphNodeInput>()?;
    m.add_class::<PyGraphNode>()?;
    m.add_class::<PyGraphEdgeInput>()?;
    m.add_class::<PyGraphEdge>()?;
    m.add_class::<PyGraphNeighborsOptions>()?;
    m.add_class::<PyGraphNeighbor>()?;
    m.add_class::<PyGraphWalkOptions>()?;
    m.add_class::<PyGraphWalkItem>()?;
    m.add_function(wrap_pyfunction!(convert_sqlite_to_zova, m)?)?;
    m.add_function(wrap_pyfunction!(restore_backup, m)?)?;
    m.add_function(wrap_pyfunction!(object_id, m)?)?;
    m.add_function(wrap_pyfunction!(object_chunk_id, m)?)?;
    m.add_function(wrap_pyfunction!(encode_f32_le, m)?)?;
    Ok(())
}
