use pyo3::exceptions::PyValueError;
use pyo3::prelude::*;
use pyo3::types::PyAny;

#[pyclass(name = "GraphInfo", frozen, skip_from_py_object)]
#[derive(Clone)]
pub(crate) struct PyGraphInfo {
    #[pyo3(get)]
    name: String,
    #[pyo3(get)]
    node_count: u64,
    #[pyo3(get)]
    edge_count: u64,
}

#[pyclass(name = "GraphNodeInput", frozen, skip_from_py_object)]
#[derive(Clone)]
pub(crate) struct PyGraphNodeInput {
    graph_name: String,
    node_id: String,
    kind: String,
    target_type: i32,
    target_namespace: Option<String>,
    target_ref: Option<String>,
}

#[pyclass(name = "GraphNode", frozen, skip_from_py_object)]
#[derive(Clone)]
pub(crate) struct PyGraphNode {
    #[pyo3(get)]
    graph_name: String,
    #[pyo3(get)]
    node_id: String,
    #[pyo3(get)]
    kind: String,
    #[pyo3(get)]
    target_type: i32,
    #[pyo3(get)]
    target_namespace: Option<String>,
    #[pyo3(get)]
    target_ref: Option<String>,
}

#[pyclass(name = "GraphEdgeInput", frozen, skip_from_py_object)]
#[derive(Clone)]
pub(crate) struct PyGraphEdgeInput {
    graph_name: String,
    from_node_id: String,
    edge_type: String,
    to_node_id: String,
}

#[pyclass(name = "GraphEdge", frozen, skip_from_py_object)]
#[derive(Clone)]
pub(crate) struct PyGraphEdge {
    #[pyo3(get)]
    graph_name: String,
    #[pyo3(get)]
    from_node_id: String,
    #[pyo3(get)]
    edge_type: String,
    #[pyo3(get)]
    to_node_id: String,
}

#[pyclass(name = "GraphNeighborsOptions", frozen, skip_from_py_object)]
#[derive(Clone)]
pub(crate) struct PyGraphNeighborsOptions {
    graph_name: String,
    node_id: String,
    direction: i32,
    edge_type: Option<String>,
    limit: usize,
}

#[pyclass(name = "GraphNeighbor", frozen, skip_from_py_object)]
#[derive(Clone)]
pub(crate) struct PyGraphNeighbor {
    #[pyo3(get)]
    node_id: String,
    #[pyo3(get)]
    kind: String,
    #[pyo3(get)]
    edge_type: String,
}

#[pyclass(name = "GraphWalkOptions", frozen, skip_from_py_object)]
#[derive(Clone)]
pub(crate) struct PyGraphWalkOptions {
    graph_name: String,
    start_node_id: String,
    edge_type: Option<String>,
    max_depth: u32,
    limit: usize,
}

#[pyclass(name = "GraphWalkItem", frozen, skip_from_py_object)]
#[derive(Clone)]
pub(crate) struct PyGraphWalkItem {
    #[pyo3(get)]
    node_id: String,
    #[pyo3(get)]
    kind: String,
    #[pyo3(get)]
    depth: u32,
    #[pyo3(get)]
    predecessor_node_id: Option<String>,
    #[pyo3(get)]
    edge_type: Option<String>,
}

pub(crate) struct OwnedGraphNodeInput {
    graph_name: String,
    node_id: String,
    kind: String,
    target_type: zova_rust::GraphTargetType,
    target_namespace: Option<String>,
    target_ref: Option<String>,
}

pub(crate) struct OwnedGraphEdgeInput {
    graph_name: String,
    from_node_id: String,
    edge_type: String,
    to_node_id: String,
}

pub(crate) struct OwnedGraphNeighborsOptions {
    graph_name: String,
    node_id: String,
    direction: zova_rust::GraphNeighborDirection,
    edge_type: Option<String>,
    limit: usize,
}

pub(crate) struct OwnedGraphWalkOptions {
    graph_name: String,
    start_node_id: String,
    edge_type: Option<String>,
    max_depth: u32,
    limit: usize,
}

#[pymethods]
impl PyGraphInfo {
    pub(crate) fn __repr__(&self) -> String {
        format!(
            "GraphInfo(name='{}', node_count={}, edge_count={})",
            self.name, self.node_count, self.edge_count
        )
    }
}

#[pymethods]
impl PyGraphNodeInput {
    #[new]
    #[pyo3(signature = (graph_name, node_id, kind, target_type, target_namespace = None, target_ref = None))]
    pub(crate) fn new(
        graph_name: String,
        node_id: String,
        kind: String,
        target_type: i32,
        target_namespace: Option<String>,
        target_ref: Option<String>,
    ) -> PyResult<Self> {
        let _ = target_type_from_i32(target_type)?;
        Ok(Self {
            graph_name,
            node_id,
            kind,
            target_type,
            target_namespace,
            target_ref,
        })
    }

    #[getter]
    pub(crate) fn graph_name(&self) -> String {
        self.graph_name.clone()
    }

    #[getter]
    pub(crate) fn node_id(&self) -> String {
        self.node_id.clone()
    }

    #[getter]
    pub(crate) fn kind(&self) -> String {
        self.kind.clone()
    }

    #[getter]
    pub(crate) fn target_type(&self) -> i32 {
        self.target_type
    }

    #[getter]
    pub(crate) fn target_namespace(&self) -> Option<String> {
        self.target_namespace.clone()
    }

    #[getter]
    pub(crate) fn target_ref(&self) -> Option<String> {
        self.target_ref.clone()
    }

    pub(crate) fn __repr__(&self) -> String {
        format!(
            "GraphNodeInput(graph_name='{}', node_id='{}', kind='{}', target_type={})",
            self.graph_name, self.node_id, self.kind, self.target_type
        )
    }
}

#[pymethods]
impl PyGraphNode {
    pub(crate) fn __repr__(&self) -> String {
        format!(
            "GraphNode(graph_name='{}', node_id='{}', kind='{}', target_type={})",
            self.graph_name, self.node_id, self.kind, self.target_type
        )
    }
}

#[pymethods]
impl PyGraphEdgeInput {
    #[new]
    pub(crate) fn new(
        graph_name: String,
        from_node_id: String,
        edge_type: String,
        to_node_id: String,
    ) -> Self {
        Self {
            graph_name,
            from_node_id,
            edge_type,
            to_node_id,
        }
    }

    #[getter]
    pub(crate) fn graph_name(&self) -> String {
        self.graph_name.clone()
    }

    #[getter]
    pub(crate) fn from_node_id(&self) -> String {
        self.from_node_id.clone()
    }

    #[getter]
    pub(crate) fn edge_type(&self) -> String {
        self.edge_type.clone()
    }

    #[getter]
    pub(crate) fn to_node_id(&self) -> String {
        self.to_node_id.clone()
    }

    pub(crate) fn __repr__(&self) -> String {
        format!(
            "GraphEdgeInput(graph_name='{}', from_node_id='{}', edge_type='{}', to_node_id='{}')",
            self.graph_name, self.from_node_id, self.edge_type, self.to_node_id
        )
    }
}

#[pymethods]
impl PyGraphEdge {
    pub(crate) fn __repr__(&self) -> String {
        format!(
            "GraphEdge(graph_name='{}', from_node_id='{}', edge_type='{}', to_node_id='{}')",
            self.graph_name, self.from_node_id, self.edge_type, self.to_node_id
        )
    }
}

#[pymethods]
impl PyGraphNeighborsOptions {
    #[new]
    #[pyo3(signature = (graph_name, node_id, direction, edge_type = None, limit = 10))]
    pub(crate) fn new(
        graph_name: String,
        node_id: String,
        direction: i32,
        edge_type: Option<String>,
        limit: usize,
    ) -> PyResult<Self> {
        let _ = direction_from_i32(direction)?;
        Ok(Self {
            graph_name,
            node_id,
            direction,
            edge_type,
            limit,
        })
    }

    #[getter]
    pub(crate) fn graph_name(&self) -> String {
        self.graph_name.clone()
    }

    #[getter]
    pub(crate) fn node_id(&self) -> String {
        self.node_id.clone()
    }

    #[getter]
    pub(crate) fn direction(&self) -> i32 {
        self.direction
    }

    #[getter]
    pub(crate) fn edge_type(&self) -> Option<String> {
        self.edge_type.clone()
    }

    #[getter]
    pub(crate) fn limit(&self) -> usize {
        self.limit
    }

    pub(crate) fn __repr__(&self) -> String {
        format!(
            "GraphNeighborsOptions(graph_name='{}', node_id='{}', direction={}, limit={})",
            self.graph_name, self.node_id, self.direction, self.limit
        )
    }
}

#[pymethods]
impl PyGraphNeighbor {
    pub(crate) fn __repr__(&self) -> String {
        format!(
            "GraphNeighbor(node_id='{}', kind='{}', edge_type='{}')",
            self.node_id, self.kind, self.edge_type
        )
    }
}

#[pymethods]
impl PyGraphWalkOptions {
    #[new]
    #[pyo3(signature = (graph_name, start_node_id, edge_type = None, max_depth = 1, limit = 10))]
    pub(crate) fn new(
        graph_name: String,
        start_node_id: String,
        edge_type: Option<String>,
        max_depth: u32,
        limit: usize,
    ) -> Self {
        Self {
            graph_name,
            start_node_id,
            edge_type,
            max_depth,
            limit,
        }
    }

    #[getter]
    pub(crate) fn graph_name(&self) -> String {
        self.graph_name.clone()
    }

    #[getter]
    pub(crate) fn start_node_id(&self) -> String {
        self.start_node_id.clone()
    }

    #[getter]
    pub(crate) fn edge_type(&self) -> Option<String> {
        self.edge_type.clone()
    }

    #[getter]
    pub(crate) fn max_depth(&self) -> u32 {
        self.max_depth
    }

    #[getter]
    pub(crate) fn limit(&self) -> usize {
        self.limit
    }

    pub(crate) fn __repr__(&self) -> String {
        format!(
            "GraphWalkOptions(graph_name='{}', start_node_id='{}', max_depth={}, limit={})",
            self.graph_name, self.start_node_id, self.max_depth, self.limit
        )
    }
}

#[pymethods]
impl PyGraphWalkItem {
    pub(crate) fn __repr__(&self) -> String {
        format!(
            "GraphWalkItem(node_id='{}', kind='{}', depth={})",
            self.node_id, self.kind, self.depth
        )
    }
}

impl OwnedGraphNodeInput {
    pub(crate) fn as_rust(&self) -> zova_rust::GraphNodeInput<'_> {
        zova_rust::GraphNodeInput {
            graph_name: self.graph_name.as_str(),
            node_id: self.node_id.as_str(),
            kind: self.kind.as_str(),
            target_type: self.target_type,
            target_namespace: self.target_namespace.as_deref(),
            target_ref: self.target_ref.as_deref(),
        }
    }
}

impl OwnedGraphEdgeInput {
    pub(crate) fn as_rust(&self) -> zova_rust::GraphEdgeInput<'_> {
        zova_rust::GraphEdgeInput {
            graph_name: self.graph_name.as_str(),
            from_node_id: self.from_node_id.as_str(),
            edge_type: self.edge_type.as_str(),
            to_node_id: self.to_node_id.as_str(),
        }
    }
}

impl OwnedGraphNeighborsOptions {
    pub(crate) fn as_rust(&self) -> zova_rust::GraphNeighborsOptions<'_> {
        zova_rust::GraphNeighborsOptions {
            graph_name: self.graph_name.as_str(),
            node_id: self.node_id.as_str(),
            direction: self.direction,
            edge_type: self.edge_type.as_deref(),
            limit: self.limit,
        }
    }
}

impl OwnedGraphWalkOptions {
    pub(crate) fn as_rust(&self) -> zova_rust::GraphWalkOptions<'_> {
        zova_rust::GraphWalkOptions {
            graph_name: self.graph_name.as_str(),
            start_node_id: self.start_node_id.as_str(),
            edge_type: self.edge_type.as_deref(),
            max_depth: self.max_depth,
            limit: self.limit,
        }
    }
}

pub(crate) fn node_input_from_py(value: &Bound<'_, PyAny>) -> PyResult<OwnedGraphNodeInput> {
    let input = value.extract::<PyRef<'_, PyGraphNodeInput>>()?;
    Ok(OwnedGraphNodeInput {
        graph_name: input.graph_name.clone(),
        node_id: input.node_id.clone(),
        kind: input.kind.clone(),
        target_type: target_type_from_i32(input.target_type)?,
        target_namespace: input.target_namespace.clone(),
        target_ref: input.target_ref.clone(),
    })
}

pub(crate) fn edge_input_from_py(value: &Bound<'_, PyAny>) -> PyResult<OwnedGraphEdgeInput> {
    let input = value.extract::<PyRef<'_, PyGraphEdgeInput>>()?;
    Ok(OwnedGraphEdgeInput {
        graph_name: input.graph_name.clone(),
        from_node_id: input.from_node_id.clone(),
        edge_type: input.edge_type.clone(),
        to_node_id: input.to_node_id.clone(),
    })
}

pub(crate) fn neighbors_options_from_py(
    value: &Bound<'_, PyAny>,
) -> PyResult<OwnedGraphNeighborsOptions> {
    let options = value.extract::<PyRef<'_, PyGraphNeighborsOptions>>()?;
    Ok(OwnedGraphNeighborsOptions {
        graph_name: options.graph_name.clone(),
        node_id: options.node_id.clone(),
        direction: direction_from_i32(options.direction)?,
        edge_type: options.edge_type.clone(),
        limit: options.limit,
    })
}

pub(crate) fn walk_options_from_py(value: &Bound<'_, PyAny>) -> PyResult<OwnedGraphWalkOptions> {
    let options = value.extract::<PyRef<'_, PyGraphWalkOptions>>()?;
    Ok(OwnedGraphWalkOptions {
        graph_name: options.graph_name.clone(),
        start_node_id: options.start_node_id.clone(),
        edge_type: options.edge_type.clone(),
        max_depth: options.max_depth,
        limit: options.limit,
    })
}

pub(crate) fn py_graph_info(info: zova_rust::GraphInfo) -> PyGraphInfo {
    PyGraphInfo {
        name: info.name,
        node_count: info.node_count,
        edge_count: info.edge_count,
    }
}

pub(crate) fn py_graph_node(node: zova_rust::GraphNode) -> PyGraphNode {
    PyGraphNode {
        graph_name: node.graph_name,
        node_id: node.node_id,
        kind: node.kind,
        target_type: target_type_to_i32(node.target_type),
        target_namespace: node.target_namespace,
        target_ref: node.target_ref,
    }
}

pub(crate) fn py_graph_edge(edge: zova_rust::GraphEdge) -> PyGraphEdge {
    PyGraphEdge {
        graph_name: edge.graph_name,
        from_node_id: edge.from_node_id,
        edge_type: edge.edge_type,
        to_node_id: edge.to_node_id,
    }
}

pub(crate) fn py_graph_neighbors(neighbors: Vec<zova_rust::GraphNeighbor>) -> Vec<PyGraphNeighbor> {
    neighbors
        .into_iter()
        .map(|neighbor| PyGraphNeighbor {
            node_id: neighbor.node_id,
            kind: neighbor.kind,
            edge_type: neighbor.edge_type,
        })
        .collect()
}

pub(crate) fn py_graph_walk(items: Vec<zova_rust::GraphWalkItem>) -> Vec<PyGraphWalkItem> {
    items
        .into_iter()
        .map(|item| PyGraphWalkItem {
            node_id: item.node_id,
            kind: item.kind,
            depth: item.depth,
            predecessor_node_id: item.predecessor_node_id,
            edge_type: item.edge_type,
        })
        .collect()
}

pub(crate) fn target_type_from_i32(value: i32) -> PyResult<zova_rust::GraphTargetType> {
    match value {
        0 => Ok(zova_rust::GraphTargetType::None),
        1 => Ok(zova_rust::GraphTargetType::Record),
        2 => Ok(zova_rust::GraphTargetType::Object),
        3 => Ok(zova_rust::GraphTargetType::ObjectChunk),
        4 => Ok(zova_rust::GraphTargetType::Vector),
        5 => Ok(zova_rust::GraphTargetType::Entity),
        6 => Ok(zova_rust::GraphTargetType::Fact),
        7 => Ok(zova_rust::GraphTargetType::Concept),
        8 => Ok(zova_rust::GraphTargetType::External),
        _ => Err(PyValueError::new_err(format!(
            "invalid graph target type {value}; expected 0 through 8"
        ))),
    }
}

pub(crate) fn target_type_to_i32(value: zova_rust::GraphTargetType) -> i32 {
    match value {
        zova_rust::GraphTargetType::None => 0,
        zova_rust::GraphTargetType::Record => 1,
        zova_rust::GraphTargetType::Object => 2,
        zova_rust::GraphTargetType::ObjectChunk => 3,
        zova_rust::GraphTargetType::Vector => 4,
        zova_rust::GraphTargetType::Entity => 5,
        zova_rust::GraphTargetType::Fact => 6,
        zova_rust::GraphTargetType::Concept => 7,
        zova_rust::GraphTargetType::External => 8,
    }
}

pub(crate) fn direction_from_i32(value: i32) -> PyResult<zova_rust::GraphNeighborDirection> {
    match value {
        0 => Ok(zova_rust::GraphNeighborDirection::Outgoing),
        1 => Ok(zova_rust::GraphNeighborDirection::Incoming),
        _ => Err(PyValueError::new_err(format!(
            "invalid graph neighbor direction {value}; expected 0 or 1"
        ))),
    }
}
