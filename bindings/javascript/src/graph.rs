use napi::bindgen_prelude::BigInt;
use napi::Result;
use napi_derive::napi;

use crate::database::NativeDatabase;
use crate::error::{invalid_argument_error, zova_error};

#[napi(object)]
pub struct NativeGraphInfo {
    pub name: String,
    pub node_count: BigInt,
    pub edge_count: BigInt,
}

#[napi(object)]
pub struct NativeGraphNodeInput {
    pub graph_name: String,
    pub node_id: String,
    pub kind: String,
    pub target_type: String,
    pub target_namespace: Option<String>,
    pub target_ref: Option<String>,
}

#[napi(object)]
pub struct NativeGraphNode {
    pub graph_name: String,
    pub node_id: String,
    pub kind: String,
    pub target_type: String,
    pub target_namespace: Option<String>,
    pub target_ref: Option<String>,
}

#[napi(object)]
pub struct NativeGraphEdgeInput {
    pub graph_name: String,
    pub from_node_id: String,
    pub edge_type: String,
    pub to_node_id: String,
}

#[napi(object)]
pub struct NativeGraphEdge {
    pub graph_name: String,
    pub from_node_id: String,
    pub edge_type: String,
    pub to_node_id: String,
}

#[napi(object)]
pub struct NativeGraphNeighborsOptions {
    pub graph_name: String,
    pub node_id: String,
    pub direction: String,
    pub edge_type: Option<String>,
    pub limit: u32,
}

#[napi(object)]
pub struct NativeGraphNeighbor {
    pub node_id: String,
    pub kind: String,
    pub edge_type: String,
}

#[napi(object)]
pub struct NativeGraphDegreeOptions {
    pub graph_name: String,
    pub node_id: String,
    pub direction: String,
    pub edge_type: Option<String>,
}

#[napi(object)]
pub struct NativeGraphWalkOptions {
    pub graph_name: String,
    pub start_node_id: String,
    pub edge_type: Option<String>,
    pub max_depth: u32,
    pub limit: u32,
}

#[napi(object)]
pub struct NativeGraphWalkItem {
    pub node_id: String,
    pub kind: String,
    pub depth: u32,
    pub predecessor_node_id: Option<String>,
    pub edge_type: Option<String>,
}

pub(crate) fn target_type(value: &str) -> Result<zova::GraphTargetType> {
    match value {
        "none" => Ok(zova::GraphTargetType::None),
        "record" => Ok(zova::GraphTargetType::Record),
        "object" => Ok(zova::GraphTargetType::Object),
        "object-chunk" => Ok(zova::GraphTargetType::ObjectChunk),
        "vector" => Ok(zova::GraphTargetType::Vector),
        "entity" => Ok(zova::GraphTargetType::Entity),
        "fact" => Ok(zova::GraphTargetType::Fact),
        "concept" => Ok(zova::GraphTargetType::Concept),
        "external" => Ok(zova::GraphTargetType::External),
        _ => Err(invalid_argument_error(format!(
            "unsupported graph target type: {value}"
        ))),
    }
}

fn target_type_name(value: zova::GraphTargetType) -> &'static str {
    match value {
        zova::GraphTargetType::None => "none",
        zova::GraphTargetType::Record => "record",
        zova::GraphTargetType::Object => "object",
        zova::GraphTargetType::ObjectChunk => "object-chunk",
        zova::GraphTargetType::Vector => "vector",
        zova::GraphTargetType::Entity => "entity",
        zova::GraphTargetType::Fact => "fact",
        zova::GraphTargetType::Concept => "concept",
        zova::GraphTargetType::External => "external",
    }
}

fn direction(value: &str) -> Result<zova::GraphNeighborDirection> {
    match value {
        "outgoing" => Ok(zova::GraphNeighborDirection::Outgoing),
        "incoming" => Ok(zova::GraphNeighborDirection::Incoming),
        _ => Err(invalid_argument_error(format!(
            "unsupported graph direction: {value}"
        ))),
    }
}

fn graph_info(info: zova::GraphInfo) -> NativeGraphInfo {
    NativeGraphInfo {
        name: info.name,
        node_count: BigInt::from(info.node_count),
        edge_count: BigInt::from(info.edge_count),
    }
}

fn graph_node(node: zova::GraphNode) -> NativeGraphNode {
    NativeGraphNode {
        graph_name: node.graph_name,
        node_id: node.node_id,
        kind: node.kind,
        target_type: target_type_name(node.target_type).to_owned(),
        target_namespace: node.target_namespace,
        target_ref: node.target_ref,
    }
}

fn graph_edge(edge: zova::GraphEdge) -> NativeGraphEdge {
    NativeGraphEdge {
        graph_name: edge.graph_name,
        from_node_id: edge.from_node_id,
        edge_type: edge.edge_type,
        to_node_id: edge.to_node_id,
    }
}

#[napi]
impl NativeDatabase {
    #[napi]
    pub fn create_graph(&self, name: String) -> Result<()> {
        self.state
            .database()?
            .create_graph(&name)
            .map_err(zova_error)
    }

    #[napi]
    pub fn has_graph(&self, name: String) -> Result<bool> {
        self.state.database()?.has_graph(&name).map_err(zova_error)
    }

    #[napi]
    pub fn graph_info(&self, name: String) -> Result<NativeGraphInfo> {
        self.state
            .database()?
            .graph_info(&name)
            .map(graph_info)
            .map_err(zova_error)
    }

    #[napi]
    pub fn list_graphs(&self) -> Result<Vec<NativeGraphInfo>> {
        self.state
            .database()?
            .list_graphs()
            .map(|items| items.into_iter().map(graph_info).collect())
            .map_err(zova_error)
    }

    #[napi]
    pub fn delete_graph(&self, name: String) -> Result<()> {
        self.state
            .database()?
            .delete_graph(&name)
            .map_err(zova_error)
    }

    #[napi]
    pub fn put_graph_node(&self, input: NativeGraphNodeInput) -> Result<()> {
        self.state
            .database()?
            .put_graph_node(zova::GraphNodeInput {
                graph_name: &input.graph_name,
                node_id: &input.node_id,
                kind: &input.kind,
                target_type: target_type(&input.target_type)?,
                target_namespace: input.target_namespace.as_deref(),
                target_ref: input.target_ref.as_deref(),
            })
            .map_err(zova_error)
    }

    #[napi]
    pub fn put_graph_nodes(&self, inputs: Vec<NativeGraphNodeInput>) -> Result<()> {
        let inputs = inputs
            .iter()
            .map(|input| {
                Ok(zova::GraphNodeInput {
                    graph_name: &input.graph_name,
                    node_id: &input.node_id,
                    kind: &input.kind,
                    target_type: target_type(&input.target_type)?,
                    target_namespace: input.target_namespace.as_deref(),
                    target_ref: input.target_ref.as_deref(),
                })
            })
            .collect::<Result<Vec<_>>>()?;
        self.state
            .database()?
            .put_graph_nodes(&inputs)
            .map_err(zova_error)
    }

    #[napi]
    pub fn get_graph_node(&self, graph_name: String, node_id: String) -> Result<NativeGraphNode> {
        self.state
            .database()?
            .get_graph_node(&graph_name, &node_id)
            .map(graph_node)
            .map_err(zova_error)
    }

    #[napi]
    pub fn has_graph_node(&self, graph_name: String, node_id: String) -> Result<bool> {
        self.state
            .database()?
            .has_graph_node(&graph_name, &node_id)
            .map_err(zova_error)
    }

    #[napi]
    pub fn delete_graph_node(&self, graph_name: String, node_id: String) -> Result<()> {
        self.state
            .database()?
            .delete_graph_node(&graph_name, &node_id)
            .map_err(zova_error)
    }

    #[napi]
    pub fn delete_graph_nodes(&self, graph_name: String, node_ids: Vec<String>) -> Result<()> {
        let node_ids = node_ids.iter().map(String::as_str).collect::<Vec<_>>();
        self.state
            .database()?
            .delete_graph_nodes(&graph_name, &node_ids)
            .map_err(zova_error)
    }

    #[napi]
    pub fn put_graph_edge(&self, input: NativeGraphEdgeInput) -> Result<()> {
        self.state
            .database()?
            .put_graph_edge(zova::GraphEdgeInput {
                graph_name: &input.graph_name,
                from_node_id: &input.from_node_id,
                edge_type: &input.edge_type,
                to_node_id: &input.to_node_id,
            })
            .map_err(zova_error)
    }

    #[napi]
    pub fn put_graph_edges(&self, inputs: Vec<NativeGraphEdgeInput>) -> Result<()> {
        let inputs = inputs
            .iter()
            .map(|input| zova::GraphEdgeInput {
                graph_name: &input.graph_name,
                from_node_id: &input.from_node_id,
                edge_type: &input.edge_type,
                to_node_id: &input.to_node_id,
            })
            .collect::<Vec<_>>();
        self.state
            .database()?
            .put_graph_edges(&inputs)
            .map_err(zova_error)
    }

    #[napi]
    pub fn get_graph_edge(
        &self,
        graph_name: String,
        from_node_id: String,
        edge_type: String,
        to_node_id: String,
    ) -> Result<NativeGraphEdge> {
        self.state
            .database()?
            .get_graph_edge(&graph_name, &from_node_id, &edge_type, &to_node_id)
            .map(graph_edge)
            .map_err(zova_error)
    }

    #[napi]
    pub fn has_graph_edge(
        &self,
        graph_name: String,
        from_node_id: String,
        edge_type: String,
        to_node_id: String,
    ) -> Result<bool> {
        self.state
            .database()?
            .has_graph_edge(&graph_name, &from_node_id, &edge_type, &to_node_id)
            .map_err(zova_error)
    }

    #[napi]
    pub fn delete_graph_edge(&self, input: NativeGraphEdgeInput) -> Result<()> {
        self.state
            .database()?
            .delete_graph_edge(zova::GraphEdgeInput {
                graph_name: &input.graph_name,
                from_node_id: &input.from_node_id,
                edge_type: &input.edge_type,
                to_node_id: &input.to_node_id,
            })
            .map_err(zova_error)
    }

    #[napi]
    pub fn delete_graph_edges(&self, inputs: Vec<NativeGraphEdgeInput>) -> Result<()> {
        let inputs = inputs
            .iter()
            .map(|input| zova::GraphEdgeInput {
                graph_name: &input.graph_name,
                from_node_id: &input.from_node_id,
                edge_type: &input.edge_type,
                to_node_id: &input.to_node_id,
            })
            .collect::<Vec<_>>();
        self.state
            .database()?
            .delete_graph_edges(&inputs)
            .map_err(zova_error)
    }

    #[napi]
    pub fn graph_neighbors(
        &self,
        options: NativeGraphNeighborsOptions,
    ) -> Result<Vec<NativeGraphNeighbor>> {
        self.state
            .database()?
            .graph_neighbors(zova::GraphNeighborsOptions {
                graph_name: &options.graph_name,
                node_id: &options.node_id,
                direction: direction(&options.direction)?,
                edge_type: options.edge_type.as_deref(),
                limit: options.limit as usize,
            })
            .map(|items| {
                items
                    .into_iter()
                    .map(|item| NativeGraphNeighbor {
                        node_id: item.node_id,
                        kind: item.kind,
                        edge_type: item.edge_type,
                    })
                    .collect()
            })
            .map_err(zova_error)
    }

    #[napi]
    pub fn graph_degree(&self, options: NativeGraphDegreeOptions) -> Result<BigInt> {
        self.state
            .database()?
            .graph_degree(zova::GraphDegreeOptions {
                graph_name: &options.graph_name,
                node_id: &options.node_id,
                direction: direction(&options.direction)?,
                edge_type: options.edge_type.as_deref(),
            })
            .map(BigInt::from)
            .map_err(zova_error)
    }

    #[napi]
    pub fn graph_walk(&self, options: NativeGraphWalkOptions) -> Result<Vec<NativeGraphWalkItem>> {
        self.state
            .database()?
            .graph_walk(zova::GraphWalkOptions {
                graph_name: &options.graph_name,
                start_node_id: &options.start_node_id,
                edge_type: options.edge_type.as_deref(),
                max_depth: options.max_depth,
                limit: options.limit as usize,
            })
            .map(|items| {
                items
                    .into_iter()
                    .map(|item| NativeGraphWalkItem {
                        node_id: item.node_id,
                        kind: item.kind,
                        depth: item.depth,
                        predecessor_node_id: item.predecessor_node_id,
                        edge_type: item.edge_type,
                    })
                    .collect()
            })
            .map_err(zova_error)
    }
}
