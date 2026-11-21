//! Opaque-key graph operations, edge payloads, graph scans, directional walks,
//! and fresh graph builds.
//!
//! Node and edge keys are opaque database-assigned `i64` values. They are
//! stable for the lifetime of a row but carry no meaning beyond identity and
//! must not be persisted across a rebuild of the graph.

use crate::database::cstring;
use crate::error::Result;
use crate::graph::{
    empty_graph_walk_results, graph_edge_inputs, graph_node_inputs, optional_cstring, optional_ptr,
    slice_ptr, string_from_parts, take_graph_walk, GraphEdgeInput, GraphNeighborDirection,
    GraphNeighborsOptions, GraphNodeInput, GraphTargetType, GraphWalkItem,
};
use crate::Database;
use std::ffi::CString;
use std::ptr;

/// Node row identified by its opaque key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GraphKeyedNode {
    pub node_key: i64,
    pub node_id: String,
    pub kind: String,
    pub created_order: i64,
}

/// Edge row identified by its opaque key. Endpoints are node keys.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GraphKeyedEdge {
    pub edge_key: i64,
    pub source_node_key: i64,
    pub edge_type: String,
    pub target_node_key: i64,
    pub created_order: i64,
}

/// Neighbor reached through one edge, with both opaque keys.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GraphKeyedNeighbor {
    pub edge_key: i64,
    pub neighbor_node_key: i64,
    pub node_id: String,
    pub kind: String,
    pub edge_type: String,
}

#[derive(Debug, Clone, Copy)]
pub struct GraphKeyedDegreeOptions<'a> {
    pub graph_name: &'a str,
    pub node_keys: &'a [i64],
    pub direction: GraphNeighborDirection,
    pub edge_type: Option<&'a str>,
}

#[derive(Debug, Clone, Copy)]
pub struct GraphEdgePayloadReplacement<'a> {
    pub edge_key: i64,
    pub payload: &'a [u8],
}

/// Scan position. The default value starts a scan; otherwise pass the
/// `created_order` and key of the last row already returned.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct GraphScanCursor {
    pub created_order: i64,
    pub key: i64,
}

#[derive(Debug, Clone, Copy)]
pub struct GraphScanOptions<'a> {
    pub graph_name: &'a str,
    pub node_after: GraphScanCursor,
    pub edge_after: GraphScanCursor,
    pub node_limit: usize,
    pub edge_limit: usize,
}

/// One page of nodes and edges in `(created_order, key)` order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GraphScanPage {
    pub nodes: Vec<GraphKeyedNode>,
    pub edges: Vec<GraphKeyedEdge>,
    pub has_more_nodes: bool,
    pub has_more_edges: bool,
}

#[derive(Debug, Clone, Copy)]
pub struct GraphWalkDirectionOptions<'a> {
    pub graph_name: &'a str,
    pub start_node_id: &'a str,
    pub direction: GraphNeighborDirection,
    pub edge_type: Option<&'a str>,
    pub max_depth: u32,
    pub limit: usize,
}

/// Diagnostic timings and counters for one directional walk.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct GraphWalkProfile {
    pub mutex_wait_ms: f64,
    pub root_lookup_ms: f64,
    pub adjacency_prepare_ms: f64,
    pub adjacency_execute_ms: f64,
    pub bfs_bookkeeping_allocation_ms: f64,
    pub c_abi_result_export_ms: f64,
    pub total_profiled_ms: f64,
    pub frontier_expansions: u64,
    pub adjacency_query_binds: u64,
    pub adjacency_rows_stepped: u64,
    pub result_count: u64,
}

/// Node row for a fresh graph build. Rows are addressed by input position.
#[derive(Debug, Clone, Copy)]
pub struct GraphFreshNodeInput<'a> {
    pub node_id: &'a str,
    pub kind: &'a str,
    pub target_type: GraphTargetType,
    pub target_namespace: Option<&'a str>,
    pub target_ref: Option<&'a str>,
}

/// Edge between two node rows of the same fresh build, by node input index.
#[derive(Debug, Clone, Copy)]
pub struct GraphFreshEdgeInput<'a> {
    pub from_node_ordinal: usize,
    pub edge_type: &'a str,
    pub to_node_ordinal: usize,
}

/// Fresh-build edge carrying an opaque payload.
#[derive(Debug, Clone, Copy)]
pub struct GraphFreshEdgePayloadInput<'a> {
    pub from_node_ordinal: usize,
    pub edge_type: &'a str,
    pub to_node_ordinal: usize,
    pub payload: &'a [u8],
}

/// Input-aligned opaque keys published by a fresh graph build.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct GraphFreshKeys {
    pub node_keys: Vec<i64>,
    pub edge_keys: Vec<i64>,
}

impl Database {
    /// Insert or replace nodes atomically and return their keys in input order.
    pub fn put_graph_nodes_keyed(&mut self, inputs: &[GraphNodeInput<'_>]) -> Result<Vec<i64>> {
        let db = self.raw_ptr();
        put_graph_nodes_keyed_raw(db, |status| self.status(status), inputs)
    }

    /// Insert edges atomically and return their keys in input order.
    pub fn put_graph_edges_keyed(&mut self, inputs: &[GraphEdgeInput<'_>]) -> Result<Vec<i64>> {
        let db = self.raw_ptr();
        put_graph_edges_keyed_raw(db, |status| self.status(status), inputs)
    }

    /// Look up nodes by key; missing keys yield `None` in the same position.
    pub fn get_graph_nodes_keyed(
        &mut self,
        graph_name: &str,
        node_keys: &[i64],
    ) -> Result<Vec<Option<GraphKeyedNode>>> {
        let db = self.raw_ptr();
        get_graph_nodes_keyed_raw(db, |status| self.status(status), graph_name, node_keys)
    }

    /// Look up edges by key; missing keys yield `None` in the same position.
    pub fn get_graph_edges_keyed(
        &mut self,
        graph_name: &str,
        edge_keys: &[i64],
    ) -> Result<Vec<Option<GraphKeyedEdge>>> {
        let db = self.raw_ptr();
        get_graph_edges_keyed_raw(db, |status| self.status(status), graph_name, edge_keys)
    }

    pub fn graph_neighbors_keyed(
        &mut self,
        options: GraphNeighborsOptions<'_>,
    ) -> Result<Vec<GraphKeyedNeighbor>> {
        let db = self.raw_ptr();
        graph_neighbors_keyed_raw(db, |status| self.status(status), options)
    }

    /// Degrees aligned with `options.node_keys`.
    pub fn graph_degrees_keyed(
        &mut self,
        options: GraphKeyedDegreeOptions<'_>,
    ) -> Result<Vec<u64>> {
        let db = self.raw_ptr();
        graph_degrees_keyed_raw(db, |status| self.status(status), options)
    }

    /// Edge payloads by edge key; missing edges yield `None`.
    pub fn get_graph_edge_payloads(
        &mut self,
        graph_name: &str,
        edge_keys: &[i64],
    ) -> Result<Vec<Option<Vec<u8>>>> {
        let db = self.raw_ptr();
        get_graph_edge_payloads_raw(db, |status| self.status(status), graph_name, edge_keys)
    }

    /// Replace edge payloads atomically.
    pub fn replace_graph_edge_payloads(
        &mut self,
        graph_name: &str,
        replacements: &[GraphEdgePayloadReplacement<'_>],
    ) -> Result<()> {
        let db = self.raw_ptr();
        replace_graph_edge_payloads_raw(db, |status| self.status(status), graph_name, replacements)
    }

    pub fn graph_scan(&mut self, options: GraphScanOptions<'_>) -> Result<GraphScanPage> {
        let db = self.raw_ptr();
        graph_scan_raw(db, |status| self.status(status), options)
    }

    /// Directional bounded breadth-first walk. The start node is returned at
    /// depth 0 and counts toward `limit`.
    pub fn graph_walk_direction(
        &mut self,
        options: GraphWalkDirectionOptions<'_>,
    ) -> Result<Vec<GraphWalkItem>> {
        let db = self.raw_ptr();
        graph_walk_direction_raw(db, |status| self.status(status), options)
    }

    pub fn graph_walk_direction_profiled(
        &mut self,
        options: GraphWalkDirectionOptions<'_>,
    ) -> Result<(Vec<GraphWalkItem>, GraphWalkProfile)> {
        let db = self.raw_ptr();
        graph_walk_direction_profiled_raw(db, |status| self.status(status), options)
    }

    /// Build one graph into an empty graph store, normalizing the input.
    pub fn build_fresh_graph_keyed(
        &mut self,
        graph_name: &str,
        nodes: &[GraphFreshNodeInput<'_>],
        edges: &[GraphFreshEdgeInput<'_>],
    ) -> Result<GraphFreshKeys> {
        let db = self.raw_ptr();
        build_fresh_graph_keyed_raw(
            db,
            |status| self.status(status),
            graph_name,
            nodes,
            edges,
            false,
        )
    }

    /// Trusted build: nodes must be unique final-order rows and edges
    /// deduplicated final-order topology. Violations fail atomically.
    pub fn build_fresh_graph_prepared_keyed(
        &mut self,
        graph_name: &str,
        nodes: &[GraphFreshNodeInput<'_>],
        edges: &[GraphFreshEdgeInput<'_>],
    ) -> Result<GraphFreshKeys> {
        let db = self.raw_ptr();
        build_fresh_graph_keyed_raw(
            db,
            |status| self.status(status),
            graph_name,
            nodes,
            edges,
            true,
        )
    }

    pub fn build_fresh_graph_prepared_keyed_with_payloads(
        &mut self,
        graph_name: &str,
        nodes: &[GraphFreshNodeInput<'_>],
        edges: &[GraphFreshEdgePayloadInput<'_>],
    ) -> Result<GraphFreshKeys> {
        let db = self.raw_ptr();
        build_fresh_graph_prepared_keyed_with_payloads_raw(
            db,
            |status| self.status(status),
            graph_name,
            nodes,
            edges,
        )
    }
}

pub(crate) fn put_graph_nodes_keyed_raw(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
    inputs: &[GraphNodeInput<'_>],
) -> Result<Vec<i64>> {
    let (_strings, raw) = graph_node_inputs(inputs)?;
    let mut keys = vec![0i64; raw.len()];
    let request = zova_sys::zova_graph_node_put_many_keyed_request {
        db,
        nodes: slice_ptr(&raw),
        nodes_len: raw.len(),
        out_node_keys: mut_slice_ptr(&mut keys),
        out_node_keys_capacity: keys.len(),
    };
    status(unsafe { zova_sys::zova_graph_node_put_many_keyed(&request) })?;
    Ok(keys)
}

pub(crate) fn put_graph_edges_keyed_raw(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
    inputs: &[GraphEdgeInput<'_>],
) -> Result<Vec<i64>> {
    let (_strings, raw) = graph_edge_inputs(inputs)?;
    let mut keys = vec![0i64; raw.len()];
    let request = zova_sys::zova_graph_edge_put_many_keyed_request {
        db,
        edges: slice_ptr(&raw),
        edges_len: raw.len(),
        out_edge_keys: mut_slice_ptr(&mut keys),
        out_edge_keys_capacity: keys.len(),
    };
    status(unsafe { zova_sys::zova_graph_edge_put_many_keyed(&request) })?;
    Ok(keys)
}

pub(crate) fn get_graph_nodes_keyed_raw(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
    graph_name: &str,
    node_keys: &[i64],
) -> Result<Vec<Option<GraphKeyedNode>>> {
    let graph_name = cstring(graph_name, "graph name")?;
    let mut results = zova_sys::zova_graph_keyed_node_results {
        items: ptr::null_mut(),
        len: 0,
    };
    let request = zova_sys::zova_graph_nodes_get_many_keyed_request {
        db,
        graph_name: graph_name.as_ptr(),
        node_keys: slice_ptr(node_keys),
        key_count: node_keys.len(),
        out_results: &mut results,
    };
    status(unsafe { zova_sys::zova_graph_nodes_get_many_keyed(&request) })?;
    let out = result_items(results.items, results.len)
        .iter()
        .map(|item| {
            if item.found == 0 {
                return Ok(None);
            }
            Ok(Some(GraphKeyedNode {
                node_key: item.node_key,
                node_id: string_from_parts(item.node_id, item.node_id_len)?,
                kind: string_from_parts(item.kind, item.kind_len)?,
                created_order: item.created_order,
            }))
        })
        .collect::<Result<Vec<_>>>();
    unsafe { zova_sys::zova_graph_keyed_node_results_free(&mut results) };
    out
}

pub(crate) fn get_graph_edges_keyed_raw(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
    graph_name: &str,
    edge_keys: &[i64],
) -> Result<Vec<Option<GraphKeyedEdge>>> {
    let graph_name = cstring(graph_name, "graph name")?;
    let mut results = zova_sys::zova_graph_keyed_edge_results {
        items: ptr::null_mut(),
        len: 0,
    };
    let request = zova_sys::zova_graph_edges_get_many_keyed_request {
        db,
        graph_name: graph_name.as_ptr(),
        edge_keys: slice_ptr(edge_keys),
        key_count: edge_keys.len(),
        out_results: &mut results,
    };
    status(unsafe { zova_sys::zova_graph_edges_get_many_keyed(&request) })?;
    let out = result_items(results.items, results.len)
        .iter()
        .map(|item| {
            if item.found == 0 {
                return Ok(None);
            }
            Ok(Some(GraphKeyedEdge {
                edge_key: item.edge_key,
                source_node_key: item.source_node_key,
                edge_type: string_from_parts(item.edge_type, item.edge_type_len)?,
                target_node_key: item.target_node_key,
                created_order: item.created_order,
            }))
        })
        .collect::<Result<Vec<_>>>();
    unsafe { zova_sys::zova_graph_keyed_edge_results_free(&mut results) };
    out
}

pub(crate) fn graph_neighbors_keyed_raw(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
    options: GraphNeighborsOptions<'_>,
) -> Result<Vec<GraphKeyedNeighbor>> {
    let graph_name = cstring(options.graph_name, "graph name")?;
    let node_id = cstring(options.node_id, "graph node id")?;
    let edge_type = optional_cstring(options.edge_type, "graph edge type")?;
    let mut results = zova_sys::zova_graph_keyed_neighbor_results {
        items: ptr::null_mut(),
        len: 0,
    };
    let request = zova_sys::zova_graph_neighbors_keyed_request {
        db,
        graph_name: graph_name.as_ptr(),
        node_id: node_id.as_ptr(),
        direction: options.direction.to_c(),
        edge_type: optional_ptr(&edge_type),
        limit: options.limit,
        out_results: &mut results,
    };
    status(unsafe { zova_sys::zova_graph_neighbors_keyed(&request) })?;
    let out = result_items(results.items, results.len)
        .iter()
        .map(|item| {
            Ok(GraphKeyedNeighbor {
                edge_key: item.edge_key,
                neighbor_node_key: item.neighbor_node_key,
                node_id: string_from_parts(item.node_id, item.node_id_len)?,
                kind: string_from_parts(item.kind, item.kind_len)?,
                edge_type: string_from_parts(item.edge_type, item.edge_type_len)?,
            })
        })
        .collect::<Result<Vec<_>>>();
    unsafe { zova_sys::zova_graph_keyed_neighbor_results_free(&mut results) };
    out
}

pub(crate) fn graph_degrees_keyed_raw(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
    options: GraphKeyedDegreeOptions<'_>,
) -> Result<Vec<u64>> {
    let graph_name = cstring(options.graph_name, "graph name")?;
    let edge_type = optional_cstring(options.edge_type, "graph edge type")?;
    let mut degrees = vec![0u64; options.node_keys.len()];
    let request = zova_sys::zova_graph_degree_many_keyed_request {
        db,
        graph_name: graph_name.as_ptr(),
        node_keys: slice_ptr(options.node_keys),
        node_count: options.node_keys.len(),
        direction: options.direction.to_c(),
        edge_type: optional_ptr(&edge_type),
        out_degrees: mut_slice_ptr(&mut degrees),
        out_degrees_capacity: degrees.len(),
    };
    status(unsafe { zova_sys::zova_graph_degree_many_keyed(&request) })?;
    Ok(degrees)
}

pub(crate) fn get_graph_edge_payloads_raw(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
    graph_name: &str,
    edge_keys: &[i64],
) -> Result<Vec<Option<Vec<u8>>>> {
    let graph_name = cstring(graph_name, "graph name")?;
    let mut results = zova_sys::zova_graph_edge_payload_results {
        items: ptr::null_mut(),
        len: 0,
    };
    let request = zova_sys::zova_graph_edge_payload_get_many_request {
        db,
        graph_name: graph_name.as_ptr(),
        edge_keys: slice_ptr(edge_keys),
        key_count: edge_keys.len(),
        out_results: &mut results,
    };
    status(unsafe { zova_sys::zova_graph_edge_payload_get_many(&request) })?;
    let out = result_items(results.items, results.len)
        .iter()
        .map(|item| {
            if item.found == 0 {
                None
            } else {
                Some(result_items(item.payload, item.payload_len).to_vec())
            }
        })
        .collect();
    unsafe { zova_sys::zova_graph_edge_payload_results_free(&mut results) };
    Ok(out)
}

pub(crate) fn replace_graph_edge_payloads_raw(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
    graph_name: &str,
    replacements: &[GraphEdgePayloadReplacement<'_>],
) -> Result<()> {
    let graph_name = cstring(graph_name, "graph name")?;
    let raw = replacements
        .iter()
        .map(|item| zova_sys::zova_graph_edge_payload_replacement {
            edge_key: item.edge_key,
            payload: slice_ptr(item.payload),
            payload_len: item.payload.len(),
        })
        .collect::<Vec<_>>();
    let request = zova_sys::zova_graph_edge_payload_replace_many_request {
        db,
        graph_name: graph_name.as_ptr(),
        replacements: slice_ptr(&raw),
        replacement_count: raw.len(),
    };
    status(unsafe { zova_sys::zova_graph_edge_payload_replace_many(&request) })
}

pub(crate) fn graph_scan_raw(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
    options: GraphScanOptions<'_>,
) -> Result<GraphScanPage> {
    let graph_name = cstring(options.graph_name, "graph name")?;
    let mut results = zova_sys::zova_graph_scan_results {
        nodes: ptr::null_mut(),
        nodes_len: 0,
        edges: ptr::null_mut(),
        edges_len: 0,
        has_more_nodes: 0,
        has_more_edges: 0,
    };
    let request = zova_sys::zova_graph_scan_request {
        db,
        graph_name: graph_name.as_ptr(),
        node_after: zova_sys::zova_graph_scan_cursor {
            created_order: options.node_after.created_order,
            key: options.node_after.key,
        },
        edge_after: zova_sys::zova_graph_scan_cursor {
            created_order: options.edge_after.created_order,
            key: options.edge_after.key,
        },
        node_limit: options.node_limit,
        edge_limit: options.edge_limit,
        out_results: &mut results,
    };
    status(unsafe { zova_sys::zova_graph_scan(&request) })?;
    let out = (|| {
        let nodes = result_items(results.nodes, results.nodes_len)
            .iter()
            .map(|item| {
                Ok(GraphKeyedNode {
                    node_key: item.node_key,
                    node_id: string_from_parts(item.node_id, item.node_id_len)?,
                    kind: string_from_parts(item.kind, item.kind_len)?,
                    created_order: item.created_order,
                })
            })
            .collect::<Result<Vec<_>>>()?;
        let edges = result_items(results.edges, results.edges_len)
            .iter()
            .map(|item| {
                Ok(GraphKeyedEdge {
                    edge_key: item.edge_key,
                    source_node_key: item.source_node_key,
                    edge_type: string_from_parts(item.edge_type, item.edge_type_len)?,
                    target_node_key: item.target_node_key,
                    created_order: item.created_order,
                })
            })
            .collect::<Result<Vec<_>>>()?;
        Ok(GraphScanPage {
            nodes,
            edges,
            has_more_nodes: results.has_more_nodes != 0,
            has_more_edges: results.has_more_edges != 0,
        })
    })();
    unsafe { zova_sys::zova_graph_scan_results_free(&mut results) };
    out
}

pub(crate) fn graph_walk_direction_raw(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
    options: GraphWalkDirectionOptions<'_>,
) -> Result<Vec<GraphWalkItem>> {
    let graph_name = cstring(options.graph_name, "graph name")?;
    let start_node_id = cstring(options.start_node_id, "graph node id")?;
    let edge_type = optional_cstring(options.edge_type, "graph edge type")?;
    let mut results = empty_graph_walk_results();
    let request = zova_sys::zova_graph_walk_direction_request {
        db,
        graph_name: graph_name.as_ptr(),
        start_node_id: start_node_id.as_ptr(),
        direction: options.direction.to_c(),
        edge_type: optional_ptr(&edge_type),
        max_depth: options.max_depth,
        limit: options.limit,
        out_results: &mut results,
    };
    status(unsafe { zova_sys::zova_graph_walk_direction(&request) })?;
    take_graph_walk(&mut results)
}

pub(crate) fn graph_walk_direction_profiled_raw(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
    options: GraphWalkDirectionOptions<'_>,
) -> Result<(Vec<GraphWalkItem>, GraphWalkProfile)> {
    let graph_name = cstring(options.graph_name, "graph name")?;
    let start_node_id = cstring(options.start_node_id, "graph node id")?;
    let edge_type = optional_cstring(options.edge_type, "graph edge type")?;
    let mut results = empty_graph_walk_results();
    let mut profile = zova_sys::zova_graph_walk_profile::default();
    let request = zova_sys::zova_graph_walk_direction_profiled_request {
        db,
        graph_name: graph_name.as_ptr(),
        start_node_id: start_node_id.as_ptr(),
        direction: options.direction.to_c(),
        edge_type: optional_ptr(&edge_type),
        max_depth: options.max_depth,
        limit: options.limit,
        out_results: &mut results,
        out_profile: &mut profile,
    };
    status(unsafe { zova_sys::zova_graph_walk_direction_profiled(&request) })?;
    let items = take_graph_walk(&mut results)?;
    Ok((
        items,
        GraphWalkProfile {
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
        },
    ))
}

pub(crate) fn build_fresh_graph_keyed_raw(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
    graph_name: &str,
    nodes: &[GraphFreshNodeInput<'_>],
    edges: &[GraphFreshEdgeInput<'_>],
    prepared: bool,
) -> Result<GraphFreshKeys> {
    let graph_name = cstring(graph_name, "graph name")?;
    let (_node_strings, raw_nodes) = fresh_node_inputs(nodes)?;
    let edge_types = fresh_edge_types(edges.iter().map(|edge| edge.edge_type))?;
    let raw_edges = edges
        .iter()
        .zip(edge_types.iter())
        .map(|(edge, edge_type)| zova_sys::zova_graph_fresh_edge_input {
            from_node_ordinal: edge.from_node_ordinal,
            edge_type: edge_type.as_ptr(),
            to_node_ordinal: edge.to_node_ordinal,
        })
        .collect::<Vec<_>>();
    let mut keys = GraphFreshKeys {
        node_keys: vec![0; raw_nodes.len()],
        edge_keys: vec![0; raw_edges.len()],
    };
    let request = zova_sys::zova_graph_build_fresh_keyed_request {
        db,
        graph_name: graph_name.as_ptr(),
        nodes: slice_ptr(&raw_nodes),
        nodes_len: raw_nodes.len(),
        edges: slice_ptr(&raw_edges),
        edges_len: raw_edges.len(),
        out_node_keys: mut_slice_ptr(&mut keys.node_keys),
        out_node_keys_capacity: keys.node_keys.len(),
        out_edge_keys: mut_slice_ptr(&mut keys.edge_keys),
        out_edge_keys_capacity: keys.edge_keys.len(),
    };
    let code = unsafe {
        if prepared {
            zova_sys::zova_graph_build_fresh_prepared_keyed(&request)
        } else {
            zova_sys::zova_graph_build_fresh_keyed(&request)
        }
    };
    status(code)?;
    Ok(keys)
}

pub(crate) fn build_fresh_graph_prepared_keyed_with_payloads_raw(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
    graph_name: &str,
    nodes: &[GraphFreshNodeInput<'_>],
    edges: &[GraphFreshEdgePayloadInput<'_>],
) -> Result<GraphFreshKeys> {
    let graph_name = cstring(graph_name, "graph name")?;
    let (_node_strings, raw_nodes) = fresh_node_inputs(nodes)?;
    let (_edge_types, raw_edges) = fresh_edge_payload_inputs(edges)?;
    let mut keys = GraphFreshKeys {
        node_keys: vec![0; raw_nodes.len()],
        edge_keys: vec![0; raw_edges.len()],
    };
    let request = zova_sys::zova_graph_build_fresh_prepared_keyed_with_payloads_request {
        db,
        graph_name: graph_name.as_ptr(),
        nodes: slice_ptr(&raw_nodes),
        nodes_len: raw_nodes.len(),
        edges: slice_ptr(&raw_edges),
        edges_len: raw_edges.len(),
        out_node_keys: mut_slice_ptr(&mut keys.node_keys),
        out_node_keys_capacity: keys.node_keys.len(),
        out_edge_keys: mut_slice_ptr(&mut keys.edge_keys),
        out_edge_keys_capacity: keys.edge_keys.len(),
    };
    status(unsafe { zova_sys::zova_graph_build_fresh_prepared_keyed_with_payloads(&request) })?;
    Ok(keys)
}

pub(crate) struct FreshNodeStrings {
    node_id: CString,
    kind: CString,
    target_namespace: Option<CString>,
    target_ref: Option<CString>,
}

pub(crate) fn fresh_node_inputs(
    nodes: &[GraphFreshNodeInput<'_>],
) -> Result<(
    Vec<FreshNodeStrings>,
    Vec<zova_sys::zova_graph_fresh_node_input>,
)> {
    let strings = nodes
        .iter()
        .map(|node| {
            Ok(FreshNodeStrings {
                node_id: cstring(node.node_id, "graph node id")?,
                kind: cstring(node.kind, "graph node kind")?,
                target_namespace: optional_cstring(
                    node.target_namespace,
                    "graph target namespace",
                )?,
                target_ref: optional_cstring(node.target_ref, "graph target ref")?,
            })
        })
        .collect::<Result<Vec<_>>>()?;
    let raw = nodes
        .iter()
        .zip(strings.iter())
        .map(|(node, strings)| zova_sys::zova_graph_fresh_node_input {
            node_id: strings.node_id.as_ptr(),
            kind: strings.kind.as_ptr(),
            target_type: node.target_type.to_c(),
            target_namespace: optional_ptr(&strings.target_namespace),
            target_ref: optional_ptr(&strings.target_ref),
        })
        .collect();
    Ok((strings, raw))
}

pub(crate) fn fresh_edge_payload_inputs(
    edges: &[GraphFreshEdgePayloadInput<'_>],
) -> Result<(
    Vec<CString>,
    Vec<zova_sys::zova_graph_fresh_edge_payload_input>,
)> {
    let edge_types = fresh_edge_types(edges.iter().map(|edge| edge.edge_type))?;
    let raw = edges
        .iter()
        .zip(edge_types.iter())
        .map(
            |(edge, edge_type)| zova_sys::zova_graph_fresh_edge_payload_input {
                from_node_ordinal: edge.from_node_ordinal,
                edge_type: edge_type.as_ptr(),
                to_node_ordinal: edge.to_node_ordinal,
                payload: slice_ptr(edge.payload),
                payload_len: edge.payload.len(),
            },
        )
        .collect();
    Ok((edge_types, raw))
}

fn fresh_edge_types<'a>(edge_types: impl Iterator<Item = &'a str>) -> Result<Vec<CString>> {
    edge_types
        .map(|edge_type| cstring(edge_type, "graph edge type"))
        .collect()
}

pub(crate) fn mut_slice_ptr<T>(values: &mut [T]) -> *mut T {
    if values.is_empty() {
        ptr::null_mut()
    } else {
        values.as_mut_ptr()
    }
}

/// Borrow a C result array, treating null or empty as an empty slice.
fn result_items<'a, T>(items: *const T, len: usize) -> &'a [T] {
    if items.is_null() || len == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(items, len) }
    }
}
