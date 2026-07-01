use crate::database::cstring;
use crate::error::{Error, Result};
use crate::Database;
use std::ffi::CString;
use std::os::raw::c_char;
use std::ptr;

pub const DEFAULT_GRAPH_NAME: &str = "default";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GraphTargetType {
    None,
    Record,
    Object,
    ObjectChunk,
    Vector,
    Entity,
    Fact,
    Concept,
    External,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GraphInfo {
    pub name: String,
    pub node_count: u64,
    pub edge_count: u64,
}

#[derive(Debug, Clone, Copy)]
pub struct GraphNodeInput<'a> {
    pub graph_name: &'a str,
    pub node_id: &'a str,
    pub kind: &'a str,
    pub target_type: GraphTargetType,
    pub target_namespace: Option<&'a str>,
    pub target_ref: Option<&'a str>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GraphNode {
    pub graph_name: String,
    pub node_id: String,
    pub kind: String,
    pub target_type: GraphTargetType,
    pub target_namespace: Option<String>,
    pub target_ref: Option<String>,
}

#[derive(Debug, Clone, Copy)]
pub struct GraphEdgeInput<'a> {
    pub graph_name: &'a str,
    pub from_node_id: &'a str,
    pub edge_type: &'a str,
    pub to_node_id: &'a str,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GraphEdge {
    pub graph_name: String,
    pub from_node_id: String,
    pub edge_type: String,
    pub to_node_id: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GraphNeighborDirection {
    Outgoing,
    Incoming,
}

#[derive(Debug, Clone, Copy)]
pub struct GraphNeighborsOptions<'a> {
    pub graph_name: &'a str,
    pub node_id: &'a str,
    pub direction: GraphNeighborDirection,
    pub edge_type: Option<&'a str>,
    pub limit: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GraphNeighbor {
    pub node_id: String,
    pub kind: String,
    pub edge_type: String,
}

#[derive(Debug, Clone, Copy)]
pub struct GraphWalkOptions<'a> {
    pub graph_name: &'a str,
    pub start_node_id: &'a str,
    pub edge_type: Option<&'a str>,
    pub max_depth: u32,
    pub limit: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GraphWalkItem {
    pub node_id: String,
    pub kind: String,
    pub depth: u32,
    pub predecessor_node_id: Option<String>,
    pub edge_type: Option<String>,
}

impl Database {
    pub fn create_graph(&mut self, name: &str) -> Result<()> {
        let db = self.raw_ptr();
        create_graph_raw(db, |status| self.status(status), name)
    }

    pub fn has_graph(&mut self, name: &str) -> Result<bool> {
        let db = self.raw_ptr();
        has_graph_raw(db, |status| self.status(status), name)
    }

    pub fn graph_info(&mut self, name: &str) -> Result<GraphInfo> {
        let db = self.raw_ptr();
        graph_info_raw(db, |status| self.status(status), name)
    }

    pub fn list_graphs(&mut self) -> Result<Vec<GraphInfo>> {
        let db = self.raw_ptr();
        list_graphs_raw(db, |status| self.status(status))
    }

    pub fn delete_graph(&mut self, name: &str) -> Result<()> {
        let db = self.raw_ptr();
        delete_graph_raw(db, |status| self.status(status), name)
    }

    pub fn put_graph_node(&mut self, input: GraphNodeInput<'_>) -> Result<()> {
        let db = self.raw_ptr();
        put_graph_node_raw(db, |status| self.status(status), input)
    }

    pub fn get_graph_node(&mut self, graph_name: &str, node_id: &str) -> Result<GraphNode> {
        let db = self.raw_ptr();
        get_graph_node_raw(db, |status| self.status(status), graph_name, node_id)
    }

    pub fn has_graph_node(&mut self, graph_name: &str, node_id: &str) -> Result<bool> {
        let db = self.raw_ptr();
        has_graph_node_raw(db, |status| self.status(status), graph_name, node_id)
    }

    pub fn delete_graph_node(&mut self, graph_name: &str, node_id: &str) -> Result<()> {
        let db = self.raw_ptr();
        delete_graph_node_raw(db, |status| self.status(status), graph_name, node_id)
    }

    pub fn put_graph_edge(&mut self, input: GraphEdgeInput<'_>) -> Result<()> {
        let db = self.raw_ptr();
        put_graph_edge_raw(db, |status| self.status(status), input)
    }

    pub fn get_graph_edge(
        &mut self,
        graph_name: &str,
        from_node_id: &str,
        edge_type: &str,
        to_node_id: &str,
    ) -> Result<GraphEdge> {
        let db = self.raw_ptr();
        get_graph_edge_raw(
            db,
            |status| self.status(status),
            graph_name,
            from_node_id,
            edge_type,
            to_node_id,
        )
    }

    pub fn has_graph_edge(
        &mut self,
        graph_name: &str,
        from_node_id: &str,
        edge_type: &str,
        to_node_id: &str,
    ) -> Result<bool> {
        let db = self.raw_ptr();
        has_graph_edge_raw(
            db,
            |status| self.status(status),
            graph_name,
            from_node_id,
            edge_type,
            to_node_id,
        )
    }

    pub fn delete_graph_edge(&mut self, input: GraphEdgeInput<'_>) -> Result<()> {
        let db = self.raw_ptr();
        delete_graph_edge_raw(db, |status| self.status(status), input)
    }

    pub fn graph_neighbors(
        &mut self,
        options: GraphNeighborsOptions<'_>,
    ) -> Result<Vec<GraphNeighbor>> {
        let db = self.raw_ptr();
        graph_neighbors_raw(db, |status| self.status(status), options)
    }

    pub fn graph_walk(&mut self, options: GraphWalkOptions<'_>) -> Result<Vec<GraphWalkItem>> {
        let db = self.raw_ptr();
        graph_walk_raw(db, |status| self.status(status), options)
    }
}

impl GraphTargetType {
    pub(crate) fn to_c(self) -> i32 {
        match self {
            Self::None => zova_sys::ZOVA_GRAPH_TARGET_NONE,
            Self::Record => zova_sys::ZOVA_GRAPH_TARGET_RECORD,
            Self::Object => zova_sys::ZOVA_GRAPH_TARGET_OBJECT,
            Self::ObjectChunk => zova_sys::ZOVA_GRAPH_TARGET_OBJECT_CHUNK,
            Self::Vector => zova_sys::ZOVA_GRAPH_TARGET_VECTOR,
            Self::Entity => zova_sys::ZOVA_GRAPH_TARGET_ENTITY,
            Self::Fact => zova_sys::ZOVA_GRAPH_TARGET_FACT,
            Self::Concept => zova_sys::ZOVA_GRAPH_TARGET_CONCEPT,
            Self::External => zova_sys::ZOVA_GRAPH_TARGET_EXTERNAL,
        }
    }

    pub(crate) fn from_c(value: i32) -> Result<Self> {
        match value {
            zova_sys::ZOVA_GRAPH_TARGET_NONE => Ok(Self::None),
            zova_sys::ZOVA_GRAPH_TARGET_RECORD => Ok(Self::Record),
            zova_sys::ZOVA_GRAPH_TARGET_OBJECT => Ok(Self::Object),
            zova_sys::ZOVA_GRAPH_TARGET_OBJECT_CHUNK => Ok(Self::ObjectChunk),
            zova_sys::ZOVA_GRAPH_TARGET_VECTOR => Ok(Self::Vector),
            zova_sys::ZOVA_GRAPH_TARGET_ENTITY => Ok(Self::Entity),
            zova_sys::ZOVA_GRAPH_TARGET_FACT => Ok(Self::Fact),
            zova_sys::ZOVA_GRAPH_TARGET_CONCEPT => Ok(Self::Concept),
            zova_sys::ZOVA_GRAPH_TARGET_EXTERNAL => Ok(Self::External),
            _ => Err(Error::from_status(zova_sys::ZOVA_INVALID_ARGUMENT, None)),
        }
    }
}

impl GraphNeighborDirection {
    pub(crate) fn to_c(self) -> i32 {
        match self {
            Self::Outgoing => zova_sys::ZOVA_GRAPH_NEIGHBOR_OUTGOING,
            Self::Incoming => zova_sys::ZOVA_GRAPH_NEIGHBOR_INCOMING,
        }
    }
}

pub(crate) fn create_graph_raw(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
    name: &str,
) -> Result<()> {
    let name = cstring(name, "graph name")?;
    let request = zova_sys::zova_graph_create_request {
        db,
        name: name.as_ptr(),
    };
    status(unsafe { zova_sys::zova_graph_create(&request) })
}

pub(crate) fn has_graph_raw(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
    name: &str,
) -> Result<bool> {
    let name = cstring(name, "graph name")?;
    let mut exists = 0;
    let request = zova_sys::zova_graph_exists_request {
        db,
        name: name.as_ptr(),
        out_exists: &mut exists,
    };
    status(unsafe { zova_sys::zova_graph_exists(&request) })?;
    Ok(exists != 0)
}

pub(crate) fn graph_info_raw(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
    name: &str,
) -> Result<GraphInfo> {
    let name = cstring(name, "graph name")?;
    let mut info = empty_graph_info();
    let request = zova_sys::zova_graph_info_get_request {
        db,
        name: name.as_ptr(),
        out_info: &mut info,
    };
    status(unsafe { zova_sys::zova_graph_info_get(&request) })?;
    take_graph_info(&mut info)
}

pub(crate) fn list_graphs_raw(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
) -> Result<Vec<GraphInfo>> {
    let mut list = empty_graph_list();
    let request = zova_sys::zova_graph_list_request {
        db,
        out_list: &mut list,
    };
    status(unsafe { zova_sys::zova_graphs_list(&request) })?;
    take_graph_list(&mut list)
}

pub(crate) fn delete_graph_raw(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
    name: &str,
) -> Result<()> {
    let name = cstring(name, "graph name")?;
    let request = zova_sys::zova_graph_delete_request {
        db,
        name: name.as_ptr(),
    };
    status(unsafe { zova_sys::zova_graph_delete(&request) })
}

pub(crate) fn put_graph_node_raw(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
    input: GraphNodeInput<'_>,
) -> Result<()> {
    let graph_name = cstring(input.graph_name, "graph name")?;
    let node_id = cstring(input.node_id, "graph node id")?;
    let kind = cstring(input.kind, "graph node kind")?;
    let target_namespace = optional_cstring(input.target_namespace, "graph target namespace")?;
    let target_ref = optional_cstring(input.target_ref, "graph target ref")?;
    let request = zova_sys::zova_graph_node_put_request {
        db,
        graph_name: graph_name.as_ptr(),
        node_id: node_id.as_ptr(),
        kind: kind.as_ptr(),
        target_type: input.target_type.to_c(),
        target_namespace: optional_ptr(&target_namespace),
        target_ref: optional_ptr(&target_ref),
    };
    status(unsafe { zova_sys::zova_graph_node_put(&request) })
}

pub(crate) fn get_graph_node_raw(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
    graph_name: &str,
    node_id: &str,
) -> Result<GraphNode> {
    let graph_name = cstring(graph_name, "graph name")?;
    let node_id = cstring(node_id, "graph node id")?;
    let mut node = empty_graph_node();
    let request = zova_sys::zova_graph_node_get_request {
        db,
        graph_name: graph_name.as_ptr(),
        node_id: node_id.as_ptr(),
        out_node: &mut node,
    };
    status(unsafe { zova_sys::zova_graph_node_get(&request) })?;
    take_graph_node(&mut node)
}

pub(crate) fn has_graph_node_raw(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
    graph_name: &str,
    node_id: &str,
) -> Result<bool> {
    let graph_name = cstring(graph_name, "graph name")?;
    let node_id = cstring(node_id, "graph node id")?;
    let mut exists = 0;
    let request = zova_sys::zova_graph_node_exists_request {
        db,
        graph_name: graph_name.as_ptr(),
        node_id: node_id.as_ptr(),
        out_exists: &mut exists,
    };
    status(unsafe { zova_sys::zova_graph_node_exists(&request) })?;
    Ok(exists != 0)
}

pub(crate) fn delete_graph_node_raw(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
    graph_name: &str,
    node_id: &str,
) -> Result<()> {
    let graph_name = cstring(graph_name, "graph name")?;
    let node_id = cstring(node_id, "graph node id")?;
    let request = zova_sys::zova_graph_node_delete_request {
        db,
        graph_name: graph_name.as_ptr(),
        node_id: node_id.as_ptr(),
    };
    status(unsafe { zova_sys::zova_graph_node_delete(&request) })
}

pub(crate) fn put_graph_edge_raw(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
    input: GraphEdgeInput<'_>,
) -> Result<()> {
    let graph_name = cstring(input.graph_name, "graph name")?;
    let from_node_id = cstring(input.from_node_id, "from graph node id")?;
    let edge_type = cstring(input.edge_type, "graph edge type")?;
    let to_node_id = cstring(input.to_node_id, "to graph node id")?;
    let request = zova_sys::zova_graph_edge_put_request {
        db,
        graph_name: graph_name.as_ptr(),
        from_node_id: from_node_id.as_ptr(),
        edge_type: edge_type.as_ptr(),
        to_node_id: to_node_id.as_ptr(),
    };
    status(unsafe { zova_sys::zova_graph_edge_put(&request) })
}

pub(crate) fn get_graph_edge_raw(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
    graph_name: &str,
    from_node_id: &str,
    edge_type: &str,
    to_node_id: &str,
) -> Result<GraphEdge> {
    let graph_name = cstring(graph_name, "graph name")?;
    let from_node_id = cstring(from_node_id, "from graph node id")?;
    let edge_type = cstring(edge_type, "graph edge type")?;
    let to_node_id = cstring(to_node_id, "to graph node id")?;
    let mut edge = empty_graph_edge();
    let request = zova_sys::zova_graph_edge_get_request {
        db,
        graph_name: graph_name.as_ptr(),
        from_node_id: from_node_id.as_ptr(),
        edge_type: edge_type.as_ptr(),
        to_node_id: to_node_id.as_ptr(),
        out_edge: &mut edge,
    };
    status(unsafe { zova_sys::zova_graph_edge_get(&request) })?;
    take_graph_edge(&mut edge)
}

pub(crate) fn has_graph_edge_raw(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
    graph_name: &str,
    from_node_id: &str,
    edge_type: &str,
    to_node_id: &str,
) -> Result<bool> {
    let graph_name = cstring(graph_name, "graph name")?;
    let from_node_id = cstring(from_node_id, "from graph node id")?;
    let edge_type = cstring(edge_type, "graph edge type")?;
    let to_node_id = cstring(to_node_id, "to graph node id")?;
    let mut exists = 0;
    let request = zova_sys::zova_graph_edge_exists_request {
        db,
        graph_name: graph_name.as_ptr(),
        from_node_id: from_node_id.as_ptr(),
        edge_type: edge_type.as_ptr(),
        to_node_id: to_node_id.as_ptr(),
        out_exists: &mut exists,
    };
    status(unsafe { zova_sys::zova_graph_edge_exists(&request) })?;
    Ok(exists != 0)
}

pub(crate) fn delete_graph_edge_raw(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
    input: GraphEdgeInput<'_>,
) -> Result<()> {
    let graph_name = cstring(input.graph_name, "graph name")?;
    let from_node_id = cstring(input.from_node_id, "from graph node id")?;
    let edge_type = cstring(input.edge_type, "graph edge type")?;
    let to_node_id = cstring(input.to_node_id, "to graph node id")?;
    let request = zova_sys::zova_graph_edge_delete_request {
        db,
        graph_name: graph_name.as_ptr(),
        from_node_id: from_node_id.as_ptr(),
        edge_type: edge_type.as_ptr(),
        to_node_id: to_node_id.as_ptr(),
    };
    status(unsafe { zova_sys::zova_graph_edge_delete(&request) })
}

pub(crate) fn graph_neighbors_raw(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
    options: GraphNeighborsOptions<'_>,
) -> Result<Vec<GraphNeighbor>> {
    let graph_name = cstring(options.graph_name, "graph name")?;
    let node_id = cstring(options.node_id, "graph node id")?;
    let edge_type = optional_cstring(options.edge_type, "graph edge type")?;
    let mut results = empty_graph_neighbor_results();
    let request = zova_sys::zova_graph_neighbors_request {
        db,
        graph_name: graph_name.as_ptr(),
        node_id: node_id.as_ptr(),
        direction: options.direction.to_c(),
        edge_type: optional_ptr(&edge_type),
        limit: options.limit,
        out_results: &mut results,
    };
    status(unsafe { zova_sys::zova_graph_neighbors(&request) })?;
    take_graph_neighbors(&mut results)
}

pub(crate) fn graph_walk_raw(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
    options: GraphWalkOptions<'_>,
) -> Result<Vec<GraphWalkItem>> {
    let graph_name = cstring(options.graph_name, "graph name")?;
    let start_node_id = cstring(options.start_node_id, "graph node id")?;
    let edge_type = optional_cstring(options.edge_type, "graph edge type")?;
    let mut results = empty_graph_walk_results();
    let request = zova_sys::zova_graph_walk_request {
        db,
        graph_name: graph_name.as_ptr(),
        start_node_id: start_node_id.as_ptr(),
        edge_type: optional_ptr(&edge_type),
        max_depth: options.max_depth,
        limit: options.limit,
        out_results: &mut results,
    };
    status(unsafe { zova_sys::zova_graph_walk(&request) })?;
    take_graph_walk(&mut results)
}

pub(crate) fn empty_graph_info() -> zova_sys::zova_graph_info {
    zova_sys::zova_graph_info {
        name: ptr::null_mut(),
        name_len: 0,
        node_count: 0,
        edge_count: 0,
    }
}

pub(crate) fn empty_graph_list() -> zova_sys::zova_graph_list {
    zova_sys::zova_graph_list {
        items: ptr::null_mut(),
        len: 0,
    }
}

pub(crate) fn empty_graph_node() -> zova_sys::zova_graph_node {
    zova_sys::zova_graph_node {
        graph_name: ptr::null_mut(),
        graph_name_len: 0,
        node_id: ptr::null_mut(),
        node_id_len: 0,
        kind: ptr::null_mut(),
        kind_len: 0,
        target_type: zova_sys::ZOVA_GRAPH_TARGET_NONE,
        target_namespace: ptr::null_mut(),
        target_namespace_len: 0,
        has_target_namespace: 0,
        target_ref: ptr::null_mut(),
        target_ref_len: 0,
        has_target_ref: 0,
    }
}

pub(crate) fn empty_graph_edge() -> zova_sys::zova_graph_edge {
    zova_sys::zova_graph_edge {
        graph_name: ptr::null_mut(),
        graph_name_len: 0,
        from_node_id: ptr::null_mut(),
        from_node_id_len: 0,
        edge_type: ptr::null_mut(),
        edge_type_len: 0,
        to_node_id: ptr::null_mut(),
        to_node_id_len: 0,
    }
}

pub(crate) fn empty_graph_neighbor_results() -> zova_sys::zova_graph_neighbor_results {
    zova_sys::zova_graph_neighbor_results {
        items: ptr::null_mut(),
        len: 0,
    }
}

pub(crate) fn empty_graph_walk_results() -> zova_sys::zova_graph_walk_results {
    zova_sys::zova_graph_walk_results {
        items: ptr::null_mut(),
        len: 0,
    }
}

pub(crate) fn take_graph_info(info: &mut zova_sys::zova_graph_info) -> Result<GraphInfo> {
    let out = (|| {
        Ok(GraphInfo {
            name: string_from_parts(info.name, info.name_len)?,
            node_count: info.node_count,
            edge_count: info.edge_count,
        })
    })();
    unsafe {
        zova_sys::zova_graph_info_free(info);
    }
    out
}

pub(crate) fn take_graph_list(list: &mut zova_sys::zova_graph_list) -> Result<Vec<GraphInfo>> {
    let out = (|| {
        if list.items.is_null() || list.len == 0 {
            Ok(Vec::new())
        } else {
            unsafe { std::slice::from_raw_parts(list.items, list.len) }
                .iter()
                .map(|item| {
                    Ok(GraphInfo {
                        name: string_from_parts(item.name, item.name_len)?,
                        node_count: item.node_count,
                        edge_count: item.edge_count,
                    })
                })
                .collect::<Result<Vec<_>>>()
        }
    })();
    unsafe {
        zova_sys::zova_graph_list_free(list);
    }
    out
}

pub(crate) fn take_graph_node(node: &mut zova_sys::zova_graph_node) -> Result<GraphNode> {
    let out = (|| {
        Ok(GraphNode {
            graph_name: string_from_parts(node.graph_name, node.graph_name_len)?,
            node_id: string_from_parts(node.node_id, node.node_id_len)?,
            kind: string_from_parts(node.kind, node.kind_len)?,
            target_type: GraphTargetType::from_c(node.target_type)?,
            target_namespace: optional_string_from_parts(
                node.target_namespace,
                node.target_namespace_len,
                node.has_target_namespace,
            )?,
            target_ref: optional_string_from_parts(
                node.target_ref,
                node.target_ref_len,
                node.has_target_ref,
            )?,
        })
    })();
    unsafe {
        zova_sys::zova_graph_node_free(node);
    }
    out
}

pub(crate) fn take_graph_edge(edge: &mut zova_sys::zova_graph_edge) -> Result<GraphEdge> {
    let out = (|| {
        Ok(GraphEdge {
            graph_name: string_from_parts(edge.graph_name, edge.graph_name_len)?,
            from_node_id: string_from_parts(edge.from_node_id, edge.from_node_id_len)?,
            edge_type: string_from_parts(edge.edge_type, edge.edge_type_len)?,
            to_node_id: string_from_parts(edge.to_node_id, edge.to_node_id_len)?,
        })
    })();
    unsafe {
        zova_sys::zova_graph_edge_free(edge);
    }
    out
}

pub(crate) fn take_graph_neighbors(
    results: &mut zova_sys::zova_graph_neighbor_results,
) -> Result<Vec<GraphNeighbor>> {
    let out = (|| {
        if results.items.is_null() || results.len == 0 {
            Ok(Vec::new())
        } else {
            unsafe { std::slice::from_raw_parts(results.items, results.len) }
                .iter()
                .map(|item| {
                    Ok(GraphNeighbor {
                        node_id: string_from_parts(item.node_id, item.node_id_len)?,
                        kind: string_from_parts(item.kind, item.kind_len)?,
                        edge_type: string_from_parts(item.edge_type, item.edge_type_len)?,
                    })
                })
                .collect::<Result<Vec<_>>>()
        }
    })();
    unsafe {
        zova_sys::zova_graph_neighbor_results_free(results);
    }
    out
}

pub(crate) fn take_graph_walk(
    results: &mut zova_sys::zova_graph_walk_results,
) -> Result<Vec<GraphWalkItem>> {
    let out = (|| {
        if results.items.is_null() || results.len == 0 {
            Ok(Vec::new())
        } else {
            unsafe { std::slice::from_raw_parts(results.items, results.len) }
                .iter()
                .map(|item| {
                    Ok(GraphWalkItem {
                        node_id: string_from_parts(item.node_id, item.node_id_len)?,
                        kind: string_from_parts(item.kind, item.kind_len)?,
                        depth: item.depth,
                        predecessor_node_id: optional_string_from_parts(
                            item.predecessor_node_id,
                            item.predecessor_node_id_len,
                            item.has_predecessor_node_id,
                        )?,
                        edge_type: optional_string_from_parts(
                            item.edge_type,
                            item.edge_type_len,
                            item.has_edge_type,
                        )?,
                    })
                })
                .collect::<Result<Vec<_>>>()
        }
    })();
    unsafe {
        zova_sys::zova_graph_walk_results_free(results);
    }
    out
}

fn optional_cstring(value: Option<&str>, context: &'static str) -> Result<Option<CString>> {
    value.map(|value| cstring(value, context)).transpose()
}

fn optional_ptr(value: &Option<CString>) -> *const c_char {
    value.as_ref().map_or(ptr::null(), |value| value.as_ptr())
}

fn string_from_parts(data: *const c_char, len: usize) -> Result<String> {
    if data.is_null() {
        return Ok(String::new());
    }
    let bytes = unsafe { std::slice::from_raw_parts(data.cast::<u8>(), len) };
    String::from_utf8(bytes.to_vec()).map_err(|_| Error::InvalidUtf8Text)
}

fn optional_string_from_parts(
    data: *const c_char,
    len: usize,
    has_value: u8,
) -> Result<Option<String>> {
    if has_value == 0 {
        Ok(None)
    } else {
        string_from_parts(data, len).map(Some)
    }
}
