use napi::bindgen_prelude::{BigInt, BigInt64Array, BigUint64Array, Uint8Array};
use napi::Result;
use napi_derive::napi;

use crate::database::NativeDatabase;
use crate::error::{invalid_argument_error, zova_error};
use crate::graph::{
    direction, graph_edge_inputs, graph_node_inputs, native_walk_items, target_type,
    NativeGraphEdgeInput, NativeGraphNeighborsOptions, NativeGraphNodeInput, NativeGraphWalkItem,
};

#[napi(object)]
pub struct NativeGraphKeyedNode {
    pub node_key: BigInt,
    pub node_id: String,
    pub kind: String,
    pub created_order: BigInt,
}

#[napi(object)]
pub struct NativeGraphKeyedEdge {
    pub edge_key: BigInt,
    pub source_node_key: BigInt,
    pub edge_type: String,
    pub target_node_key: BigInt,
    pub created_order: BigInt,
}

#[napi(object)]
pub struct NativeGraphKeyedNeighbor {
    pub edge_key: BigInt,
    pub neighbor_node_key: BigInt,
    pub node_id: String,
    pub kind: String,
    pub edge_type: String,
}

#[napi(object)]
pub struct NativeGraphKeyedDegreeOptions {
    pub graph_name: String,
    pub node_keys: BigInt64Array,
    pub direction: String,
    pub edge_type: Option<String>,
}

#[napi(object)]
pub struct NativeGraphEdgePayloadReplacement {
    pub edge_key: BigInt,
    pub payload: Uint8Array,
}

#[napi(object)]
pub struct NativeGraphScanCursor {
    pub created_order: BigInt,
    pub key: BigInt,
}

#[napi(object)]
pub struct NativeGraphScanOptions {
    pub graph_name: String,
    pub node_after: Option<NativeGraphScanCursor>,
    pub edge_after: Option<NativeGraphScanCursor>,
    pub node_limit: u32,
    pub edge_limit: u32,
}

#[napi(object)]
pub struct NativeGraphScanPage {
    pub nodes: Vec<NativeGraphKeyedNode>,
    pub edges: Vec<NativeGraphKeyedEdge>,
    pub has_more_nodes: bool,
    pub has_more_edges: bool,
}

#[napi(object)]
pub struct NativeGraphWalkDirectionOptions {
    pub graph_name: String,
    pub start_node_id: String,
    pub direction: String,
    pub edge_type: Option<String>,
    pub max_depth: u32,
    pub limit: u32,
}

/// Timings are milliseconds; counters are plain numbers.
#[napi(object)]
pub struct NativeGraphWalkProfile {
    pub mutex_wait_ms: f64,
    pub root_lookup_ms: f64,
    pub adjacency_prepare_ms: f64,
    pub adjacency_execute_ms: f64,
    pub bfs_bookkeeping_allocation_ms: f64,
    pub c_abi_result_export_ms: f64,
    pub total_profiled_ms: f64,
    pub frontier_expansions: f64,
    pub adjacency_query_binds: f64,
    pub adjacency_rows_stepped: f64,
    pub result_count: f64,
}

#[napi(object)]
pub struct NativeGraphWalkDirectionProfiled {
    pub items: Vec<NativeGraphWalkItem>,
    pub profile: NativeGraphWalkProfile,
}

#[napi(object)]
pub struct NativeGraphFreshNodeInput {
    pub node_id: String,
    pub kind: String,
    pub target_type: String,
    pub target_namespace: Option<String>,
    pub target_ref: Option<String>,
}

/// An edge between two nodes of the same fresh build, by node position.
#[napi(object)]
pub struct NativeGraphFreshEdgeInput {
    pub from_node_ordinal: u32,
    pub edge_type: String,
    pub to_node_ordinal: u32,
    pub payload: Option<Uint8Array>,
}

#[napi(object)]
pub struct NativeGraphFreshKeys {
    pub node_keys: BigInt64Array,
    pub edge_keys: BigInt64Array,
}

pub(crate) fn key(value: &BigInt, name: &str) -> Result<i64> {
    match value.get_i64() {
        (value, true) => Ok(value),
        _ => Err(invalid_argument_error(format!(
            "{name} must fit in a signed 64-bit integer"
        ))),
    }
}

fn cursor(value: Option<&NativeGraphScanCursor>) -> Result<zova::GraphScanCursor> {
    match value {
        None => Ok(zova::GraphScanCursor::default()),
        Some(value) => Ok(zova::GraphScanCursor {
            created_order: key(&value.created_order, "createdOrder")?,
            key: key(&value.key, "key")?,
        }),
    }
}

fn keyed_node(node: zova::GraphKeyedNode) -> NativeGraphKeyedNode {
    NativeGraphKeyedNode {
        node_key: BigInt::from(node.node_key),
        node_id: node.node_id,
        kind: node.kind,
        created_order: BigInt::from(node.created_order),
    }
}

fn keyed_edge(edge: zova::GraphKeyedEdge) -> NativeGraphKeyedEdge {
    NativeGraphKeyedEdge {
        edge_key: BigInt::from(edge.edge_key),
        source_node_key: BigInt::from(edge.source_node_key),
        edge_type: edge.edge_type,
        target_node_key: BigInt::from(edge.target_node_key),
        created_order: BigInt::from(edge.created_order),
    }
}

fn walk_direction_options(
    options: &NativeGraphWalkDirectionOptions,
) -> Result<zova::GraphWalkDirectionOptions<'_>> {
    Ok(zova::GraphWalkDirectionOptions {
        graph_name: &options.graph_name,
        start_node_id: &options.start_node_id,
        direction: direction(&options.direction)?,
        edge_type: options.edge_type.as_deref(),
        max_depth: options.max_depth,
        limit: options.limit as usize,
    })
}

fn walk_profile(profile: zova::GraphWalkProfile) -> NativeGraphWalkProfile {
    NativeGraphWalkProfile {
        mutex_wait_ms: profile.mutex_wait_ms,
        root_lookup_ms: profile.root_lookup_ms,
        adjacency_prepare_ms: profile.adjacency_prepare_ms,
        adjacency_execute_ms: profile.adjacency_execute_ms,
        bfs_bookkeeping_allocation_ms: profile.bfs_bookkeeping_allocation_ms,
        c_abi_result_export_ms: profile.c_abi_result_export_ms,
        total_profiled_ms: profile.total_profiled_ms,
        frontier_expansions: profile.frontier_expansions as f64,
        adjacency_query_binds: profile.adjacency_query_binds as f64,
        adjacency_rows_stepped: profile.adjacency_rows_stepped as f64,
        result_count: profile.result_count as f64,
    }
}

pub(crate) fn fresh_nodes(
    nodes: &[NativeGraphFreshNodeInput],
) -> Result<Vec<zova::GraphFreshNodeInput<'_>>> {
    nodes
        .iter()
        .map(|node| {
            Ok(zova::GraphFreshNodeInput {
                node_id: &node.node_id,
                kind: &node.kind,
                target_type: target_type(&node.target_type)?,
                target_namespace: node.target_namespace.as_deref(),
                target_ref: node.target_ref.as_deref(),
            })
        })
        .collect()
}

fn fresh_edges(edges: &[NativeGraphFreshEdgeInput]) -> Result<Vec<zova::GraphFreshEdgeInput<'_>>> {
    edges
        .iter()
        .map(|edge| {
            if edge.payload.is_some() {
                return Err(invalid_argument_error(
                    "this graph builder does not accept edge payloads",
                ));
            }
            Ok(zova::GraphFreshEdgeInput {
                from_node_ordinal: edge.from_node_ordinal as usize,
                edge_type: &edge.edge_type,
                to_node_ordinal: edge.to_node_ordinal as usize,
            })
        })
        .collect()
}

/// Edges with payloads; an absent payload is empty.
pub(crate) fn fresh_payload_edges(
    edges: &[NativeGraphFreshEdgeInput],
) -> Vec<zova::GraphFreshEdgePayloadInput<'_>> {
    edges
        .iter()
        .map(|edge| zova::GraphFreshEdgePayloadInput {
            from_node_ordinal: edge.from_node_ordinal as usize,
            edge_type: &edge.edge_type,
            to_node_ordinal: edge.to_node_ordinal as usize,
            payload: edge
                .payload
                .as_ref()
                .map_or(&[], |payload| payload.as_ref()),
        })
        .collect()
}

fn fresh_keys(keys: zova::GraphFreshKeys) -> NativeGraphFreshKeys {
    NativeGraphFreshKeys {
        node_keys: BigInt64Array::new(keys.node_keys),
        edge_keys: BigInt64Array::new(keys.edge_keys),
    }
}

#[napi]
impl NativeDatabase {
    #[napi]
    pub fn put_graph_nodes_keyed(
        &self,
        inputs: Vec<NativeGraphNodeInput>,
    ) -> Result<BigInt64Array> {
        let inputs = graph_node_inputs(&inputs)?;
        self.state
            .database()?
            .put_graph_nodes_keyed(&inputs)
            .map(BigInt64Array::new)
            .map_err(zova_error)
    }

    #[napi]
    pub fn put_graph_edges_keyed(
        &self,
        inputs: Vec<NativeGraphEdgeInput>,
    ) -> Result<BigInt64Array> {
        let inputs = graph_edge_inputs(&inputs);
        self.state
            .database()?
            .put_graph_edges_keyed(&inputs)
            .map(BigInt64Array::new)
            .map_err(zova_error)
    }

    #[napi]
    pub fn get_graph_nodes_keyed(
        &self,
        graph_name: String,
        node_keys: BigInt64Array,
    ) -> Result<Vec<Option<NativeGraphKeyedNode>>> {
        self.state
            .database()?
            .get_graph_nodes_keyed(&graph_name, node_keys.as_ref())
            .map(|items| items.into_iter().map(|item| item.map(keyed_node)).collect())
            .map_err(zova_error)
    }

    #[napi]
    pub fn get_graph_edges_keyed(
        &self,
        graph_name: String,
        edge_keys: BigInt64Array,
    ) -> Result<Vec<Option<NativeGraphKeyedEdge>>> {
        self.state
            .database()?
            .get_graph_edges_keyed(&graph_name, edge_keys.as_ref())
            .map(|items| items.into_iter().map(|item| item.map(keyed_edge)).collect())
            .map_err(zova_error)
    }

    #[napi]
    pub fn graph_neighbors_keyed(
        &self,
        options: NativeGraphNeighborsOptions,
    ) -> Result<Vec<NativeGraphKeyedNeighbor>> {
        self.state
            .database()?
            .graph_neighbors_keyed(zova::GraphNeighborsOptions {
                graph_name: &options.graph_name,
                node_id: &options.node_id,
                direction: direction(&options.direction)?,
                edge_type: options.edge_type.as_deref(),
                limit: options.limit as usize,
            })
            .map(|items| {
                items
                    .into_iter()
                    .map(|item| NativeGraphKeyedNeighbor {
                        edge_key: BigInt::from(item.edge_key),
                        neighbor_node_key: BigInt::from(item.neighbor_node_key),
                        node_id: item.node_id,
                        kind: item.kind,
                        edge_type: item.edge_type,
                    })
                    .collect()
            })
            .map_err(zova_error)
    }

    #[napi]
    pub fn graph_degrees_keyed(
        &self,
        options: NativeGraphKeyedDegreeOptions,
    ) -> Result<BigUint64Array> {
        self.state
            .database()?
            .graph_degrees_keyed(zova::GraphKeyedDegreeOptions {
                graph_name: &options.graph_name,
                node_keys: options.node_keys.as_ref(),
                direction: direction(&options.direction)?,
                edge_type: options.edge_type.as_deref(),
            })
            .map(BigUint64Array::new)
            .map_err(zova_error)
    }

    #[napi]
    pub fn get_graph_edge_payloads(
        &self,
        graph_name: String,
        edge_keys: BigInt64Array,
    ) -> Result<Vec<Option<Uint8Array>>> {
        self.state
            .database()?
            .get_graph_edge_payloads(&graph_name, edge_keys.as_ref())
            .map(|items| {
                items
                    .into_iter()
                    .map(|item| item.map(Uint8Array::new))
                    .collect()
            })
            .map_err(zova_error)
    }

    #[napi]
    pub fn replace_graph_edge_payloads(
        &self,
        graph_name: String,
        replacements: Vec<NativeGraphEdgePayloadReplacement>,
    ) -> Result<()> {
        let replacements = replacements
            .iter()
            .map(|item| {
                Ok(zova::GraphEdgePayloadReplacement {
                    edge_key: key(&item.edge_key, "edgeKey")?,
                    payload: item.payload.as_ref(),
                })
            })
            .collect::<Result<Vec<_>>>()?;
        self.state
            .database()?
            .replace_graph_edge_payloads(&graph_name, &replacements)
            .map_err(zova_error)
    }

    #[napi]
    pub fn graph_scan(&self, options: NativeGraphScanOptions) -> Result<NativeGraphScanPage> {
        let page = self
            .state
            .database()?
            .graph_scan(zova::GraphScanOptions {
                graph_name: &options.graph_name,
                node_after: cursor(options.node_after.as_ref())?,
                edge_after: cursor(options.edge_after.as_ref())?,
                node_limit: options.node_limit as usize,
                edge_limit: options.edge_limit as usize,
            })
            .map_err(zova_error)?;
        Ok(NativeGraphScanPage {
            nodes: page.nodes.into_iter().map(keyed_node).collect(),
            edges: page.edges.into_iter().map(keyed_edge).collect(),
            has_more_nodes: page.has_more_nodes,
            has_more_edges: page.has_more_edges,
        })
    }

    #[napi]
    pub fn graph_walk_direction(
        &self,
        options: NativeGraphWalkDirectionOptions,
    ) -> Result<Vec<NativeGraphWalkItem>> {
        self.state
            .database()?
            .graph_walk_direction(walk_direction_options(&options)?)
            .map(native_walk_items)
            .map_err(zova_error)
    }

    #[napi]
    pub fn graph_walk_direction_profiled(
        &self,
        options: NativeGraphWalkDirectionOptions,
    ) -> Result<NativeGraphWalkDirectionProfiled> {
        let (items, profile) = self
            .state
            .database()?
            .graph_walk_direction_profiled(walk_direction_options(&options)?)
            .map_err(zova_error)?;
        Ok(NativeGraphWalkDirectionProfiled {
            items: native_walk_items(items),
            profile: walk_profile(profile),
        })
    }

    #[napi]
    pub fn build_fresh_graph_keyed(
        &self,
        graph_name: String,
        nodes: Vec<NativeGraphFreshNodeInput>,
        edges: Vec<NativeGraphFreshEdgeInput>,
    ) -> Result<NativeGraphFreshKeys> {
        let nodes = fresh_nodes(&nodes)?;
        let edges = fresh_edges(&edges)?;
        self.state
            .database()?
            .build_fresh_graph_keyed(&graph_name, &nodes, &edges)
            .map(fresh_keys)
            .map_err(zova_error)
    }

    #[napi]
    pub fn build_fresh_graph_prepared_keyed(
        &self,
        graph_name: String,
        nodes: Vec<NativeGraphFreshNodeInput>,
        edges: Vec<NativeGraphFreshEdgeInput>,
    ) -> Result<NativeGraphFreshKeys> {
        let nodes = fresh_nodes(&nodes)?;
        let edges = fresh_edges(&edges)?;
        self.state
            .database()?
            .build_fresh_graph_prepared_keyed(&graph_name, &nodes, &edges)
            .map(fresh_keys)
            .map_err(zova_error)
    }

    #[napi]
    pub fn build_fresh_graph_prepared_keyed_with_payloads(
        &self,
        graph_name: String,
        nodes: Vec<NativeGraphFreshNodeInput>,
        edges: Vec<NativeGraphFreshEdgeInput>,
    ) -> Result<NativeGraphFreshKeys> {
        let nodes = fresh_nodes(&nodes)?;
        let edges = fresh_payload_edges(&edges);
        self.state
            .database()?
            .build_fresh_graph_prepared_keyed_with_payloads(&graph_name, &nodes, &edges)
            .map(fresh_keys)
            .map_err(zova_error)
    }
}
