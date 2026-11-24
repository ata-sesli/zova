mod database;
mod error;
mod extension;
mod fresh_build;
mod graph;
mod graph_keyed;
mod notification;
mod object;
mod progress;
mod sql_function;
mod statement;
mod vector;

use database::{
    convert_sqlite_to_zova, migrate_database, probe_format, restore_backup,
    restore_backup_to_memory, PyCheckpointedMember, PyDatabase, PyFormatInfo, PyJournalModeMember,
    PyReclaimedMember, PySavepointContext,
};
use error::{ClosedHandleError, ZovaError};
use extension::{
    trust_extension_bundle, untrust_extension_bundle, verify_extension_bundle, PyExtensionInfo,
    PyLinkedPlugin,
};
use fresh_build::{PyFreshBuild, PyFreshBuildProfile, PyFreshBuildResult};
use graph::{
    PyGraphEdge, PyGraphEdgeInput, PyGraphInfo, PyGraphNeighbor, PyGraphNeighborsOptions,
    PyGraphNode, PyGraphNodeInput, PyGraphWalkItem, PyGraphWalkOptions,
};
use graph_keyed::{
    PyGraphFreshEdgeInput, PyGraphFreshNodeInput, PyGraphKeyedEdge, PyGraphKeyedNeighbor,
    PyGraphKeyedNode, PyGraphScanPage, PyGraphWalkDirectionOptions, PyGraphWalkProfile,
};
use notification::{PyNotification, PySubscription};
use object::{
    object_chunk_id, object_id, PyObjectChunkId, PyObjectId, PyObjectManifest,
    PyObjectManifestChunk, PyObjectPutOptions, PyObjectReader, PyObjectSeekableReader,
    PyObjectWriter,
};
use progress::PyProgress;
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
    m.add_class::<PyObjectPutOptions>()?;
    m.add_class::<PyObjectReader>()?;
    m.add_class::<PyObjectSeekableReader>()?;
    m.add_class::<PyObjectWriter>()?;
    m.add_class::<PyVectorCollectionOptions>()?;
    m.add_class::<PyVectorCollectionInfo>()?;
    m.add_class::<PyVector>()?;
    m.add_class::<PyVectorInput>()?;
    m.add_class::<PyVectorSearchResult>()?;
    m.add_class::<PyExtensionInfo>()?;
    m.add_class::<PyFormatInfo>()?;
    m.add_class::<PyProgress>()?;
    m.add_class::<PyReclaimedMember>()?;
    m.add_class::<PyJournalModeMember>()?;
    m.add_class::<PyCheckpointedMember>()?;
    m.add_class::<PyGraphInfo>()?;
    m.add_class::<PyGraphNodeInput>()?;
    m.add_class::<PyGraphNode>()?;
    m.add_class::<PyGraphEdgeInput>()?;
    m.add_class::<PyGraphEdge>()?;
    m.add_class::<PyGraphNeighborsOptions>()?;
    m.add_class::<PyGraphNeighbor>()?;
    m.add_class::<PyGraphWalkOptions>()?;
    m.add_class::<PyGraphWalkItem>()?;
    m.add_class::<PyGraphKeyedNode>()?;
    m.add_class::<PyGraphKeyedEdge>()?;
    m.add_class::<PyGraphKeyedNeighbor>()?;
    m.add_class::<PyGraphScanPage>()?;
    m.add_class::<PyGraphWalkDirectionOptions>()?;
    m.add_class::<PyGraphWalkProfile>()?;
    m.add_class::<PyGraphFreshNodeInput>()?;
    m.add_class::<PyGraphFreshEdgeInput>()?;
    m.add_class::<PyFreshBuild>()?;
    m.add_class::<PyFreshBuildProfile>()?;
    m.add_class::<PyFreshBuildResult>()?;
    m.add_class::<PyLinkedPlugin>()?;
    m.add_function(wrap_pyfunction!(convert_sqlite_to_zova, m)?)?;
    m.add_function(wrap_pyfunction!(restore_backup, m)?)?;
    m.add_function(wrap_pyfunction!(restore_backup_to_memory, m)?)?;
    m.add_function(wrap_pyfunction!(probe_format, m)?)?;
    m.add_function(wrap_pyfunction!(migrate_database, m)?)?;
    m.add_function(wrap_pyfunction!(object_id, m)?)?;
    m.add_function(wrap_pyfunction!(object_chunk_id, m)?)?;
    m.add_function(wrap_pyfunction!(encode_f32_le, m)?)?;
    m.add_function(wrap_pyfunction!(verify_extension_bundle, m)?)?;
    m.add_function(wrap_pyfunction!(trust_extension_bundle, m)?)?;
    m.add_function(wrap_pyfunction!(untrust_extension_bundle, m)?)?;
    m.add_function(wrap_pyfunction!(abi_version, m)?)?;
    m.add_function(wrap_pyfunction!(abi_version_string, m)?)?;
    Ok(())
}

/// The C ABI version as `(major, minor, patch)`.
#[pyfunction]
fn abi_version() -> (u32, u32, u32) {
    let version = zova_rust::abi_version();
    (version.major, version.minor, version.patch)
}

/// The C ABI version string.
#[pyfunction]
fn abi_version_string() -> &'static str {
    zova_rust::abi_version_string()
}
