//! Atomic fresh-build sessions.

use pyo3::exceptions::{PyTypeError, PyValueError};
use pyo3::prelude::*;
use pyo3::types::{PyAny, PyBool, PyByteArray, PyBytes, PyFloat, PyInt, PyMemoryView, PyString};

use crate::error::{closed_error, zova_error};
use crate::graph_keyed::{
    fresh_edge_payload_refs, fresh_edges_from_py, fresh_node_refs, fresh_nodes_from_py,
};
use crate::vector::{vector_input_refs, vector_inputs_from_py};

/// Loads predeclared, initially empty targets and publishes them with one
/// commit. While the session is active, every other call on its database
/// fails. A failed step rolls the whole session back; later steps raise
/// `ZovaError` with status `MISUSE`. Leaving a `with` block without
/// `finish()` rolls the session back.
#[pyclass(name = "FreshBuild", unsendable)]
pub(crate) struct PyFreshBuild {
    inner: Option<zova_rust::OwnedFreshBuild>,
}

#[pyclass(name = "FreshBuildProfile", frozen, get_all, skip_from_py_object)]
#[derive(Clone)]
pub(crate) struct PyFreshBuildProfile {
    validation_ms: f64,
    table_load_ms: f64,
    fts_load_ms: f64,
    graph_load_ms: f64,
    graph_validation_ms: f64,
    graph_key_generation_ms: f64,
    graph_node_load_ms: f64,
    graph_edge_load_ms: f64,
    vector_load_ms: f64,
    index_build_ms: f64,
    commit_ms: f64,
    table_rows: u64,
    fts_rows: u64,
    vector_rows: u64,
    payload_bytes: u64,
}

/// Graph keys assigned by the session's graph step, aligned with its inputs,
/// and the build profile.
#[pyclass(name = "FreshBuildResult", frozen, get_all, skip_from_py_object)]
pub(crate) struct PyFreshBuildResult {
    node_keys: Vec<i64>,
    edge_keys: Vec<i64>,
    profile: PyFreshBuildProfile,
}

impl PyFreshBuild {
    pub(crate) fn new(inner: zova_rust::OwnedFreshBuild) -> Self {
        Self { inner: Some(inner) }
    }

    fn build(&mut self) -> PyResult<&mut zova_rust::OwnedFreshBuild> {
        self.inner
            .as_mut()
            .ok_or_else(|| closed_error("fresh build"))
    }

    fn rows(
        &mut self,
        table_name: &str,
        columns: Vec<String>,
        rows: &Bound<'_, PyAny>,
        fts: bool,
    ) -> PyResult<()> {
        let build = self.build()?;
        let values = match fresh_values_from_rows(rows, columns.len()) {
            Ok(values) => values,
            Err(err) => {
                // A step that fails before the native call still ends the
                // session, as native step failures do.
                let _ = build.abort();
                return Err(err);
            }
        };
        let column_refs = columns.iter().map(String::as_str).collect::<Vec<_>>();
        let value_refs = values
            .iter()
            .map(OwnedFreshValue::as_rust)
            .collect::<Vec<_>>();
        if fts {
            build.fts_rows(table_name, &column_refs, &value_refs)
        } else {
            build.table_rows(table_name, &column_refs, &value_refs)
        }
        .map_err(zova_error)
    }
}

#[pymethods]
impl PyFreshBuild {
    /// Append rows to an initially empty table. Each row is a sequence with
    /// one value per column: None, int, float, str, or bytes.
    fn table_rows(
        &mut self,
        table_name: &str,
        columns: Vec<String>,
        rows: &Bound<'_, PyAny>,
    ) -> PyResult<()> {
        self.rows(table_name, columns, rows, false)
    }

    /// Append rows to an initially empty FTS5 table. Rows follow `table_rows`.
    fn fts_rows(
        &mut self,
        table_name: &str,
        columns: Vec<String>,
        rows: &Bound<'_, PyAny>,
    ) -> PyResult<()> {
        self.rows(table_name, columns, rows, true)
    }

    /// Load the session's one graph from trusted final-order input:
    /// `GraphFreshNodeInput` values and `GraphFreshEdgeInput` values, whose
    /// payloads are optional.
    fn graph(
        &mut self,
        graph_name: &str,
        nodes: &Bound<'_, PyAny>,
        edges: &Bound<'_, PyAny>,
    ) -> PyResult<()> {
        let build = self.build()?;
        let converted = fresh_nodes_from_py(nodes).and_then(|nodes| {
            let edges = fresh_edges_from_py(edges)?;
            Ok((nodes, edges))
        });
        let (nodes, edges) = match converted {
            Ok(converted) => converted,
            Err(err) => {
                let _ = build.abort();
                return Err(err);
            }
        };
        let node_refs = match fresh_node_refs(&nodes) {
            Ok(node_refs) => node_refs,
            Err(err) => {
                let _ = build.abort();
                return Err(err);
            }
        };
        let edge_refs = fresh_edge_payload_refs(&edges);
        build
            .graph(graph_name, &node_refs, &edge_refs)
            .map_err(zova_error)
    }

    /// Append `VectorInput` values to an existing, empty collection.
    fn vectors(&mut self, collection_name: &str, vectors: &Bound<'_, PyAny>) -> PyResult<()> {
        let build = self.build()?;
        let owned = match vector_inputs_from_py(vectors) {
            Ok(owned) => owned,
            Err(err) => {
                let _ = build.abort();
                return Err(err);
            }
        };
        let refs = vector_input_refs(&owned);
        build.vectors(collection_name, &refs).map_err(zova_error)
    }

    /// Build deferred indexes, validate foreign keys, and commit.
    fn finish(&mut self) -> PyResult<PyFreshBuildResult> {
        let result = self.build()?.finish().map_err(zova_error)?;
        let profile = result.profile;
        Ok(PyFreshBuildResult {
            node_keys: result.node_keys,
            edge_keys: result.edge_keys,
            profile: PyFreshBuildProfile {
                validation_ms: profile.validation_ms,
                table_load_ms: profile.table_load_ms,
                fts_load_ms: profile.fts_load_ms,
                graph_load_ms: profile.graph_load_ms,
                graph_validation_ms: profile.graph_validation_ms,
                graph_key_generation_ms: profile.graph_key_generation_ms,
                graph_node_load_ms: profile.graph_node_load_ms,
                graph_edge_load_ms: profile.graph_edge_load_ms,
                vector_load_ms: profile.vector_load_ms,
                index_build_ms: profile.index_build_ms,
                commit_ms: profile.commit_ms,
                table_rows: profile.table_rows,
                fts_rows: profile.fts_rows,
                vector_rows: profile.vector_rows,
                payload_bytes: profile.payload_bytes,
            },
        })
    }

    /// Roll the session back.
    fn abort(&mut self) -> PyResult<()> {
        self.build()?.abort().map_err(zova_error)
    }

    /// Release the session, rolling it back if it is still active.
    fn close(&mut self) {
        self.inner.take();
    }

    fn __enter__(slf: PyRefMut<'_, Self>) -> PyRefMut<'_, Self> {
        slf
    }

    fn __exit__(
        &mut self,
        _exc_type: Option<&Bound<'_, PyAny>>,
        _exc_value: Option<&Bound<'_, PyAny>>,
        _traceback: Option<&Bound<'_, PyAny>>,
    ) -> bool {
        self.close();
        false
    }
}

#[pymethods]
impl PyFreshBuildProfile {
    fn __repr__(&self) -> String {
        format!(
            "FreshBuildProfile(table_rows={}, fts_rows={}, vector_rows={}, payload_bytes={}, commit_ms={})",
            self.table_rows, self.fts_rows, self.vector_rows, self.payload_bytes, self.commit_ms
        )
    }
}

#[pymethods]
impl PyFreshBuildResult {
    fn __repr__(&self) -> String {
        format!(
            "FreshBuildResult(node_keys={}, edge_keys={})",
            self.node_keys.len(),
            self.edge_keys.len()
        )
    }
}

enum OwnedFreshValue {
    Null,
    Int64(i64),
    Float64(f64),
    Text(String),
    Blob(Vec<u8>),
}

impl OwnedFreshValue {
    fn as_rust(&self) -> zova_rust::FreshValue<'_> {
        match self {
            Self::Null => zova_rust::FreshValue::Null,
            Self::Int64(value) => zova_rust::FreshValue::Int64(*value),
            Self::Float64(value) => zova_rust::FreshValue::Float64(*value),
            Self::Text(value) => zova_rust::FreshValue::Text(value),
            Self::Blob(value) => zova_rust::FreshValue::Blob(value),
        }
    }
}

fn fresh_values_from_rows(
    rows: &Bound<'_, PyAny>,
    column_count: usize,
) -> PyResult<Vec<OwnedFreshValue>> {
    let mut values = Vec::new();
    for (row_index, row) in rows.try_iter()?.enumerate() {
        let row = row?;
        let before = values.len();
        for value in row.try_iter()? {
            values.push(fresh_value(&value?)?);
        }
        if values.len() - before != column_count {
            return Err(PyValueError::new_err(format!(
                "fresh build row {row_index} has {} values; expected {column_count}",
                values.len() - before
            )));
        }
    }
    Ok(values)
}

fn fresh_value(value: &Bound<'_, PyAny>) -> PyResult<OwnedFreshValue> {
    if value.is_none() {
        Ok(OwnedFreshValue::Null)
    } else if value.is_instance_of::<PyBool>() || value.is_instance_of::<PyInt>() {
        Ok(OwnedFreshValue::Int64(value.extract()?))
    } else if value.is_instance_of::<PyFloat>() {
        Ok(OwnedFreshValue::Float64(value.extract()?))
    } else if value.is_instance_of::<PyString>() {
        Ok(OwnedFreshValue::Text(value.extract()?))
    } else if value.is_instance_of::<PyBytes>()
        || value.is_instance_of::<PyByteArray>()
        || value.is_instance_of::<PyMemoryView>()
    {
        Ok(OwnedFreshValue::Blob(value.extract()?))
    } else {
        Err(PyTypeError::new_err(format!(
            "unsupported fresh build value type {}",
            value.get_type().name()?
        )))
    }
}
