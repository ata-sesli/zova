//! Opaque-key graph topology, scans, directional walks, and fresh graph
//! builds.

use pyo3::exceptions::PyValueError;
use pyo3::prelude::*;
use pyo3::types::PyAny;

use crate::graph::{direction_from_i32, target_type_from_i32};

/// A node returned by key. `created_order` and `node_key` form a scan cursor.
#[pyclass(name = "GraphKeyedNode", frozen, get_all, skip_from_py_object)]
#[derive(Clone)]
pub(crate) struct PyGraphKeyedNode {
    node_key: i64,
    node_id: String,
    kind: String,
    created_order: i64,
}

/// An edge returned by key. `created_order` and `edge_key` form a scan cursor.
#[pyclass(name = "GraphKeyedEdge", frozen, get_all, skip_from_py_object)]
#[derive(Clone)]
pub(crate) struct PyGraphKeyedEdge {
    edge_key: i64,
    source_node_key: i64,
    edge_type: String,
    target_node_key: i64,
    created_order: i64,
}

#[pyclass(name = "GraphKeyedNeighbor", frozen, get_all, skip_from_py_object)]
#[derive(Clone)]
pub(crate) struct PyGraphKeyedNeighbor {
    edge_key: i64,
    neighbor_node_key: i64,
    node_id: String,
    kind: String,
    edge_type: String,
}

/// One page of `Database.graph_scan`.
#[pyclass(name = "GraphScanPage", frozen, get_all, skip_from_py_object)]
pub(crate) struct PyGraphScanPage {
    nodes: Vec<PyGraphKeyedNode>,
    edges: Vec<PyGraphKeyedEdge>,
    has_more_nodes: bool,
    has_more_edges: bool,
}

#[pyclass(
    name = "GraphWalkDirectionOptions",
    frozen,
    get_all,
    skip_from_py_object
)]
#[derive(Clone)]
pub(crate) struct PyGraphWalkDirectionOptions {
    graph_name: String,
    start_node_id: String,
    direction: i32,
    edge_type: Option<String>,
    max_depth: u32,
    limit: usize,
}

/// Timings and counters for one profiled directional walk.
#[pyclass(name = "GraphWalkProfile", frozen, get_all, skip_from_py_object)]
pub(crate) struct PyGraphWalkProfile {
    mutex_wait_ms: f64,
    root_lookup_ms: f64,
    adjacency_prepare_ms: f64,
    adjacency_execute_ms: f64,
    bfs_bookkeeping_allocation_ms: f64,
    c_abi_result_export_ms: f64,
    total_profiled_ms: f64,
    frontier_expansions: u64,
    adjacency_query_binds: u64,
    adjacency_rows_stepped: u64,
    result_count: u64,
}

/// A node for a fresh graph build. Edges refer to nodes by list position.
#[pyclass(name = "GraphFreshNodeInput", frozen, get_all, skip_from_py_object)]
#[derive(Clone)]
pub(crate) struct PyGraphFreshNodeInput {
    node_id: String,
    kind: String,
    target_type: i32,
    target_namespace: Option<String>,
    target_ref: Option<String>,
}

/// An edge for a fresh graph build between two node list positions.
/// `payload` is accepted only by the payload-aware builders.
#[pyclass(name = "GraphFreshEdgeInput", frozen, get_all, skip_from_py_object)]
#[derive(Clone)]
pub(crate) struct PyGraphFreshEdgeInput {
    from_node_ordinal: usize,
    edge_type: String,
    to_node_ordinal: usize,
    payload: Option<Vec<u8>>,
}

#[pymethods]
impl PyGraphKeyedNode {
    fn __repr__(&self) -> String {
        format!(
            "GraphKeyedNode(node_key={}, node_id='{}', kind='{}', created_order={})",
            self.node_key, self.node_id, self.kind, self.created_order
        )
    }
}

#[pymethods]
impl PyGraphKeyedEdge {
    fn __repr__(&self) -> String {
        format!(
            "GraphKeyedEdge(edge_key={}, source_node_key={}, edge_type='{}', target_node_key={}, created_order={})",
            self.edge_key, self.source_node_key, self.edge_type, self.target_node_key, self.created_order
        )
    }
}

#[pymethods]
impl PyGraphKeyedNeighbor {
    fn __repr__(&self) -> String {
        format!(
            "GraphKeyedNeighbor(edge_key={}, neighbor_node_key={}, node_id='{}', kind='{}', edge_type='{}')",
            self.edge_key, self.neighbor_node_key, self.node_id, self.kind, self.edge_type
        )
    }
}

#[pymethods]
impl PyGraphScanPage {
    fn __repr__(&self) -> String {
        format!(
            "GraphScanPage(nodes={}, edges={}, has_more_nodes={}, has_more_edges={})",
            self.nodes.len(),
            self.edges.len(),
            self.has_more_nodes,
            self.has_more_edges
        )
    }
}

#[pymethods]
impl PyGraphWalkDirectionOptions {
    #[new]
    #[pyo3(signature = (graph_name, start_node_id, direction, edge_type = None, max_depth = 1, limit = 10))]
    fn new(
        graph_name: String,
        start_node_id: String,
        direction: i32,
        edge_type: Option<String>,
        max_depth: u32,
        limit: usize,
    ) -> PyResult<Self> {
        direction_from_i32(direction)?;
        Ok(Self {
            graph_name,
            start_node_id,
            direction,
            edge_type,
            max_depth,
            limit,
        })
    }

    fn __repr__(&self) -> String {
        format!(
            "GraphWalkDirectionOptions(graph_name='{}', start_node_id='{}', direction={}, max_depth={}, limit={})",
            self.graph_name, self.start_node_id, self.direction, self.max_depth, self.limit
        )
    }
}

#[pymethods]
impl PyGraphWalkProfile {
    fn __repr__(&self) -> String {
        format!(
            "GraphWalkProfile(total_profiled_ms={}, result_count={})",
            self.total_profiled_ms, self.result_count
        )
    }
}

#[pymethods]
impl PyGraphFreshNodeInput {
    #[new]
    #[pyo3(signature = (node_id, kind, target_type, target_namespace = None, target_ref = None))]
    fn new(
        node_id: String,
        kind: String,
        target_type: i32,
        target_namespace: Option<String>,
        target_ref: Option<String>,
    ) -> PyResult<Self> {
        target_type_from_i32(target_type)?;
        Ok(Self {
            node_id,
            kind,
            target_type,
            target_namespace,
            target_ref,
        })
    }

    fn __repr__(&self) -> String {
        format!(
            "GraphFreshNodeInput(node_id='{}', kind='{}', target_type={})",
            self.node_id, self.kind, self.target_type
        )
    }
}

#[pymethods]
impl PyGraphFreshEdgeInput {
    #[new]
    #[pyo3(signature = (from_node_ordinal, edge_type, to_node_ordinal, payload = None))]
    fn new(
        from_node_ordinal: usize,
        edge_type: String,
        to_node_ordinal: usize,
        payload: Option<Vec<u8>>,
    ) -> Self {
        Self {
            from_node_ordinal,
            edge_type,
            to_node_ordinal,
            payload,
        }
    }

    fn __repr__(&self) -> String {
        format!(
            "GraphFreshEdgeInput(from_node_ordinal={}, edge_type='{}', to_node_ordinal={})",
            self.from_node_ordinal, self.edge_type, self.to_node_ordinal
        )
    }
}

impl PyGraphWalkDirectionOptions {
    pub(crate) fn as_rust(&self) -> PyResult<zova_rust::GraphWalkDirectionOptions<'_>> {
        Ok(zova_rust::GraphWalkDirectionOptions {
            graph_name: &self.graph_name,
            start_node_id: &self.start_node_id,
            direction: direction_from_i32(self.direction)?,
            edge_type: self.edge_type.as_deref(),
            max_depth: self.max_depth,
            limit: self.limit,
        })
    }
}

pub(crate) fn walk_direction_options_from_py(
    value: &Bound<'_, PyAny>,
) -> PyResult<PyGraphWalkDirectionOptions> {
    Ok(value
        .extract::<PyRef<'_, PyGraphWalkDirectionOptions>>()?
        .clone())
}

pub(crate) fn fresh_nodes_from_py(
    value: &Bound<'_, PyAny>,
) -> PyResult<Vec<PyGraphFreshNodeInput>> {
    value
        .try_iter()?
        .map(|item| Ok(item?.extract::<PyRef<'_, PyGraphFreshNodeInput>>()?.clone()))
        .collect()
}

pub(crate) fn fresh_edges_from_py(
    value: &Bound<'_, PyAny>,
) -> PyResult<Vec<PyGraphFreshEdgeInput>> {
    value
        .try_iter()?
        .map(|item| Ok(item?.extract::<PyRef<'_, PyGraphFreshEdgeInput>>()?.clone()))
        .collect()
}

pub(crate) fn fresh_node_refs(
    nodes: &[PyGraphFreshNodeInput],
) -> PyResult<Vec<zova_rust::GraphFreshNodeInput<'_>>> {
    nodes
        .iter()
        .map(|node| {
            Ok(zova_rust::GraphFreshNodeInput {
                node_id: &node.node_id,
                kind: &node.kind,
                target_type: target_type_from_i32(node.target_type)?,
                target_namespace: node.target_namespace.as_deref(),
                target_ref: node.target_ref.as_deref(),
            })
        })
        .collect()
}

/// Topology-only edges; a payload is rejected rather than silently dropped.
pub(crate) fn fresh_edge_refs(
    edges: &[PyGraphFreshEdgeInput],
) -> PyResult<Vec<zova_rust::GraphFreshEdgeInput<'_>>> {
    edges
        .iter()
        .map(|edge| {
            if edge.payload.is_some() {
                return Err(PyValueError::new_err(
                    "this graph builder does not accept edge payloads",
                ));
            }
            Ok(zova_rust::GraphFreshEdgeInput {
                from_node_ordinal: edge.from_node_ordinal,
                edge_type: &edge.edge_type,
                to_node_ordinal: edge.to_node_ordinal,
            })
        })
        .collect()
}

/// Payload-aware edges; a missing payload is stored as an empty payload.
pub(crate) fn fresh_edge_payload_refs(
    edges: &[PyGraphFreshEdgeInput],
) -> Vec<zova_rust::GraphFreshEdgePayloadInput<'_>> {
    edges
        .iter()
        .map(|edge| zova_rust::GraphFreshEdgePayloadInput {
            from_node_ordinal: edge.from_node_ordinal,
            edge_type: &edge.edge_type,
            to_node_ordinal: edge.to_node_ordinal,
            payload: edge.payload.as_deref().unwrap_or_default(),
        })
        .collect()
}

pub(crate) fn py_keyed_node(node: zova_rust::GraphKeyedNode) -> PyGraphKeyedNode {
    PyGraphKeyedNode {
        node_key: node.node_key,
        node_id: node.node_id,
        kind: node.kind,
        created_order: node.created_order,
    }
}

pub(crate) fn py_keyed_edge(edge: zova_rust::GraphKeyedEdge) -> PyGraphKeyedEdge {
    PyGraphKeyedEdge {
        edge_key: edge.edge_key,
        source_node_key: edge.source_node_key,
        edge_type: edge.edge_type,
        target_node_key: edge.target_node_key,
        created_order: edge.created_order,
    }
}

pub(crate) fn py_keyed_neighbors(
    neighbors: Vec<zova_rust::GraphKeyedNeighbor>,
) -> Vec<PyGraphKeyedNeighbor> {
    neighbors
        .into_iter()
        .map(|neighbor| PyGraphKeyedNeighbor {
            edge_key: neighbor.edge_key,
            neighbor_node_key: neighbor.neighbor_node_key,
            node_id: neighbor.node_id,
            kind: neighbor.kind,
            edge_type: neighbor.edge_type,
        })
        .collect()
}

pub(crate) fn py_scan_page(page: zova_rust::GraphScanPage) -> PyGraphScanPage {
    PyGraphScanPage {
        nodes: page.nodes.into_iter().map(py_keyed_node).collect(),
        edges: page.edges.into_iter().map(py_keyed_edge).collect(),
        has_more_nodes: page.has_more_nodes,
        has_more_edges: page.has_more_edges,
    }
}

pub(crate) fn py_walk_profile(profile: zova_rust::GraphWalkProfile) -> PyGraphWalkProfile {
    PyGraphWalkProfile {
        mutex_wait_ms: profile.mutex_wait_ms,
        root_lookup_ms: profile.root_lookup_ms,
        adjacency_prepare_ms: profile.adjacency_prepare_ms,
        adjacency_execute_ms: profile.adjacency_execute_ms,
        bfs_bookkeeping_allocation_ms: profile.bfs_bookkeeping_allocation_ms,
        c_abi_result_export_ms: profile.c_abi_result_export_ms,
        total_profiled_ms: profile.total_profiled_ms,
        frontier_expansions: profile.frontier_expansions,
        adjacency_query_binds: profile.adjacency_query_binds,
        adjacency_rows_stepped: profile.adjacency_rows_stepped,
        result_count: profile.result_count,
    }
}
