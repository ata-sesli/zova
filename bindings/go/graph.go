package zova

/*
#include <stdlib.h>
#include "zova.h"
*/
import "C"

import "unsafe"

// DefaultGraphName is the conventional graph name for apps that do not need
// multiple named relationship graphs.
const DefaultGraphName = "default"

// GraphTargetType describes what a graph node points at.
type GraphTargetType int

const (
	GraphTargetNone        GraphTargetType = C.ZOVA_GRAPH_TARGET_NONE
	GraphTargetRecord      GraphTargetType = C.ZOVA_GRAPH_TARGET_RECORD
	GraphTargetObject      GraphTargetType = C.ZOVA_GRAPH_TARGET_OBJECT
	GraphTargetObjectChunk GraphTargetType = C.ZOVA_GRAPH_TARGET_OBJECT_CHUNK
	GraphTargetVector      GraphTargetType = C.ZOVA_GRAPH_TARGET_VECTOR
	GraphTargetEntity      GraphTargetType = C.ZOVA_GRAPH_TARGET_ENTITY
	GraphTargetFact        GraphTargetType = C.ZOVA_GRAPH_TARGET_FACT
	GraphTargetConcept     GraphTargetType = C.ZOVA_GRAPH_TARGET_CONCEPT
	GraphTargetExternal    GraphTargetType = C.ZOVA_GRAPH_TARGET_EXTERNAL
)

// GraphNeighborDirection chooses outgoing or incoming edge traversal.
type GraphNeighborDirection int

const (
	GraphNeighborOutgoing GraphNeighborDirection = C.ZOVA_GRAPH_NEIGHBOR_OUTGOING
	GraphNeighborIncoming GraphNeighborDirection = C.ZOVA_GRAPH_NEIGHBOR_INCOMING
)

// GraphInfo describes one named graph.
type GraphInfo struct {
	Name      string
	NodeCount uint64
	EdgeCount uint64
}

// GraphNodeInput creates or updates a graph node.
type GraphNodeInput struct {
	GraphName       string
	NodeID          string
	Kind            string
	TargetType      GraphTargetType
	TargetNamespace *string
	TargetRef       *string
}

// GraphNode is one owned graph node returned by Zova.
type GraphNode struct {
	GraphName       string
	NodeID          string
	Kind            string
	TargetType      GraphTargetType
	TargetNamespace *string
	TargetRef       *string
}

// GraphEdgeInput creates or deletes one directed graph edge.
type GraphEdgeInput struct {
	GraphName  string
	FromNodeID string
	EdgeType   string
	ToNodeID   string
}

// GraphEdge is one exact directed graph edge.
type GraphEdge struct {
	GraphName  string
	FromNodeID string
	EdgeType   string
	ToNodeID   string
}

// GraphNeighborsOptions configures a bounded neighbor query.
type GraphNeighborsOptions struct {
	GraphName string
	NodeID    string
	Direction GraphNeighborDirection
	EdgeType  *string
	Limit     uint
}

// GraphNeighbor is one neighbor query result.
type GraphNeighbor struct {
	NodeID   string
	Kind     string
	EdgeType string
}

// GraphWalkOptions configures a bounded directed walk.
type GraphWalkOptions struct {
	GraphName   string
	StartNodeID string
	EdgeType    *string
	MaxDepth    uint32
	Limit       uint
}

// GraphWalkItem is one bounded walk result.
type GraphWalkItem struct {
	NodeID            string
	Kind              string
	Depth             uint32
	PredecessorNodeID *string
	EdgeType          *string
}

// CreateGraph creates a named graph.
func (db *DB) CreateGraph(name string) error {
	cName, err := cString("graph name", name)
	if err != nil {
		return err
	}
	defer freeCString(cName)

	return db.withLock(func() error {
		request := C.zova_graph_create_request{
			db:   db.ptr,
			name: cName,
		}
		return statusFromDB(db, C.zova_graph_create(&request))
	})
}

// HasGraph reports whether a named graph exists.
func (db *DB) HasGraph(name string) (bool, error) {
	cName, err := cString("graph name", name)
	if err != nil {
		return false, err
	}
	defer freeCString(cName)

	out := (*C.uint8_t)(C.calloc(1, C.size_t(unsafe.Sizeof(C.uint8_t(0)))))
	defer C.free(unsafe.Pointer(out))
	err = db.withLock(func() error {
		request := C.zova_graph_exists_request{
			db:         db.ptr,
			name:       cName,
			out_exists: out,
		}
		return statusFromDB(db, C.zova_graph_exists(&request))
	})
	return *out != 0, err
}

// GraphInfo returns metadata for one named graph.
func (db *DB) GraphInfo(name string) (GraphInfo, error) {
	cName, err := cString("graph name", name)
	if err != nil {
		return GraphInfo{}, err
	}
	defer freeCString(cName)

	info := newCGraphInfo()
	defer freeCGraphInfo(info)
	err = db.withLock(func() error {
		request := C.zova_graph_info_get_request{
			db:       db.ptr,
			name:     cName,
			out_info: info,
		}
		return statusFromDB(db, C.zova_graph_info_get(&request))
	})
	if err != nil {
		return GraphInfo{}, err
	}
	return copyGraphInfo(info), nil
}

// ListGraphs returns all named graphs sorted by name.
func (db *DB) ListGraphs() ([]GraphInfo, error) {
	list := newCGraphList()
	defer freeCGraphList(list)
	err := db.withLock(func() error {
		request := C.zova_graph_list_request{
			db:       db.ptr,
			out_list: list,
		}
		return statusFromDB(db, C.zova_graphs_list(&request))
	})
	if err != nil {
		return nil, err
	}
	return copyGraphList(list), nil
}

// DeleteGraph deletes a named graph and its graph nodes and graph edges.
func (db *DB) DeleteGraph(name string) error {
	cName, err := cString("graph name", name)
	if err != nil {
		return err
	}
	defer freeCString(cName)

	return db.withLock(func() error {
		request := C.zova_graph_delete_request{
			db:   db.ptr,
			name: cName,
		}
		return statusFromDB(db, C.zova_graph_delete(&request))
	})
}

// PutGraphNode creates or updates a graph node.
func (db *DB) PutGraphNode(input GraphNodeInput) error {
	graphName, err := cString("graph name", input.GraphName)
	if err != nil {
		return err
	}
	defer freeCString(graphName)
	nodeID, err := cString("graph node id", input.NodeID)
	if err != nil {
		return err
	}
	defer freeCString(nodeID)
	kind, err := cString("graph node kind", input.Kind)
	if err != nil {
		return err
	}
	defer freeCString(kind)
	targetNamespace, cleanupNamespace, err := optionalCString("graph target namespace", input.TargetNamespace)
	if err != nil {
		return err
	}
	defer cleanupNamespace()
	targetRef, cleanupRef, err := optionalCString("graph target ref", input.TargetRef)
	if err != nil {
		return err
	}
	defer cleanupRef()

	return db.withLock(func() error {
		request := C.zova_graph_node_put_request{
			db:               db.ptr,
			graph_name:       graphName,
			node_id:          nodeID,
			kind:             kind,
			target_type:      C.int(input.TargetType),
			target_namespace: targetNamespace,
			target_ref:       targetRef,
		}
		return statusFromDB(db, C.zova_graph_node_put(&request))
	})
}

// GetGraphNode returns one graph node.
func (db *DB) GetGraphNode(graphName, nodeID string) (GraphNode, error) {
	cGraphName, err := cString("graph name", graphName)
	if err != nil {
		return GraphNode{}, err
	}
	defer freeCString(cGraphName)
	cNodeID, err := cString("graph node id", nodeID)
	if err != nil {
		return GraphNode{}, err
	}
	defer freeCString(cNodeID)

	node := newCGraphNode()
	defer freeCGraphNode(node)
	err = db.withLock(func() error {
		request := C.zova_graph_node_get_request{
			db:         db.ptr,
			graph_name: cGraphName,
			node_id:    cNodeID,
			out_node:   node,
		}
		return statusFromDB(db, C.zova_graph_node_get(&request))
	})
	if err != nil {
		return GraphNode{}, err
	}
	return copyGraphNode(node), nil
}

// HasGraphNode reports whether a graph node exists.
func (db *DB) HasGraphNode(graphName, nodeID string) (bool, error) {
	cGraphName, err := cString("graph name", graphName)
	if err != nil {
		return false, err
	}
	defer freeCString(cGraphName)
	cNodeID, err := cString("graph node id", nodeID)
	if err != nil {
		return false, err
	}
	defer freeCString(cNodeID)

	out := (*C.uint8_t)(C.calloc(1, C.size_t(unsafe.Sizeof(C.uint8_t(0)))))
	defer C.free(unsafe.Pointer(out))
	err = db.withLock(func() error {
		request := C.zova_graph_node_exists_request{
			db:         db.ptr,
			graph_name: cGraphName,
			node_id:    cNodeID,
			out_exists: out,
		}
		return statusFromDB(db, C.zova_graph_node_exists(&request))
	})
	return *out != 0, err
}

// DeleteGraphNode deletes a graph node and incident graph edges only.
func (db *DB) DeleteGraphNode(graphName, nodeID string) error {
	cGraphName, err := cString("graph name", graphName)
	if err != nil {
		return err
	}
	defer freeCString(cGraphName)
	cNodeID, err := cString("graph node id", nodeID)
	if err != nil {
		return err
	}
	defer freeCString(cNodeID)

	return db.withLock(func() error {
		request := C.zova_graph_node_delete_request{
			db:         db.ptr,
			graph_name: cGraphName,
			node_id:    cNodeID,
		}
		return statusFromDB(db, C.zova_graph_node_delete(&request))
	})
}

// PutGraphEdge creates a directed graph edge.
func (db *DB) PutGraphEdge(input GraphEdgeInput) error {
	graphName, fromNodeID, edgeType, toNodeID, cleanup, err := cGraphEdgeInput(input)
	if err != nil {
		return err
	}
	defer cleanup()

	return db.withLock(func() error {
		request := C.zova_graph_edge_put_request{
			db:           db.ptr,
			graph_name:   graphName,
			from_node_id: fromNodeID,
			edge_type:    edgeType,
			to_node_id:   toNodeID,
		}
		return statusFromDB(db, C.zova_graph_edge_put(&request))
	})
}

// GetGraphEdge returns one exact graph edge.
func (db *DB) GetGraphEdge(graphName, fromNodeID, edgeType, toNodeID string) (GraphEdge, error) {
	input := GraphEdgeInput{
		GraphName:  graphName,
		FromNodeID: fromNodeID,
		EdgeType:   edgeType,
		ToNodeID:   toNodeID,
	}
	cGraphName, cFromNodeID, cEdgeType, cToNodeID, cleanup, err := cGraphEdgeInput(input)
	if err != nil {
		return GraphEdge{}, err
	}
	defer cleanup()

	edge := newCGraphEdge()
	defer freeCGraphEdge(edge)
	err = db.withLock(func() error {
		request := C.zova_graph_edge_get_request{
			db:           db.ptr,
			graph_name:   cGraphName,
			from_node_id: cFromNodeID,
			edge_type:    cEdgeType,
			to_node_id:   cToNodeID,
			out_edge:     edge,
		}
		return statusFromDB(db, C.zova_graph_edge_get(&request))
	})
	if err != nil {
		return GraphEdge{}, err
	}
	return copyGraphEdge(edge), nil
}

// HasGraphEdge reports whether one exact graph edge exists.
func (db *DB) HasGraphEdge(graphName, fromNodeID, edgeType, toNodeID string) (bool, error) {
	input := GraphEdgeInput{
		GraphName:  graphName,
		FromNodeID: fromNodeID,
		EdgeType:   edgeType,
		ToNodeID:   toNodeID,
	}
	cGraphName, cFromNodeID, cEdgeType, cToNodeID, cleanup, err := cGraphEdgeInput(input)
	if err != nil {
		return false, err
	}
	defer cleanup()

	out := (*C.uint8_t)(C.calloc(1, C.size_t(unsafe.Sizeof(C.uint8_t(0)))))
	defer C.free(unsafe.Pointer(out))
	err = db.withLock(func() error {
		request := C.zova_graph_edge_exists_request{
			db:           db.ptr,
			graph_name:   cGraphName,
			from_node_id: cFromNodeID,
			edge_type:    cEdgeType,
			to_node_id:   cToNodeID,
			out_exists:   out,
		}
		return statusFromDB(db, C.zova_graph_edge_exists(&request))
	})
	return *out != 0, err
}

// DeleteGraphEdge deletes one exact graph edge.
func (db *DB) DeleteGraphEdge(input GraphEdgeInput) error {
	graphName, fromNodeID, edgeType, toNodeID, cleanup, err := cGraphEdgeInput(input)
	if err != nil {
		return err
	}
	defer cleanup()

	return db.withLock(func() error {
		request := C.zova_graph_edge_delete_request{
			db:           db.ptr,
			graph_name:   graphName,
			from_node_id: fromNodeID,
			edge_type:    edgeType,
			to_node_id:   toNodeID,
		}
		return statusFromDB(db, C.zova_graph_edge_delete(&request))
	})
}

// GraphNeighbors returns bounded incoming or outgoing graph neighbors.
func (db *DB) GraphNeighbors(options GraphNeighborsOptions) ([]GraphNeighbor, error) {
	graphName, err := cString("graph name", options.GraphName)
	if err != nil {
		return nil, err
	}
	defer freeCString(graphName)
	nodeID, err := cString("graph node id", options.NodeID)
	if err != nil {
		return nil, err
	}
	defer freeCString(nodeID)
	edgeType, cleanupEdgeType, err := optionalCString("graph edge type", options.EdgeType)
	if err != nil {
		return nil, err
	}
	defer cleanupEdgeType()

	results := newCGraphNeighborResults()
	defer freeCGraphNeighborResults(results)
	err = db.withLock(func() error {
		request := C.zova_graph_neighbors_request{
			db:          db.ptr,
			graph_name:  graphName,
			node_id:     nodeID,
			direction:   C.int(options.Direction),
			edge_type:   edgeType,
			limit:       C.size_t(options.Limit),
			out_results: results,
		}
		return statusFromDB(db, C.zova_graph_neighbors(&request))
	})
	if err != nil {
		return nil, err
	}
	return copyGraphNeighbors(results), nil
}

// GraphWalk returns a bounded directed walk from one start node.
func (db *DB) GraphWalk(options GraphWalkOptions) ([]GraphWalkItem, error) {
	graphName, err := cString("graph name", options.GraphName)
	if err != nil {
		return nil, err
	}
	defer freeCString(graphName)
	startNodeID, err := cString("graph start node id", options.StartNodeID)
	if err != nil {
		return nil, err
	}
	defer freeCString(startNodeID)
	edgeType, cleanupEdgeType, err := optionalCString("graph edge type", options.EdgeType)
	if err != nil {
		return nil, err
	}
	defer cleanupEdgeType()

	results := newCGraphWalkResults()
	defer freeCGraphWalkResults(results)
	err = db.withLock(func() error {
		request := C.zova_graph_walk_request{
			db:            db.ptr,
			graph_name:    graphName,
			start_node_id: startNodeID,
			edge_type:     edgeType,
			max_depth:     C.uint32_t(options.MaxDepth),
			limit:         C.size_t(options.Limit),
			out_results:   results,
		}
		return statusFromDB(db, C.zova_graph_walk(&request))
	})
	if err != nil {
		return nil, err
	}
	return copyGraphWalk(results), nil
}

func cGraphEdgeInput(input GraphEdgeInput) (*C.char, *C.char, *C.char, *C.char, func(), error) {
	graphName, err := cString("graph name", input.GraphName)
	if err != nil {
		return nil, nil, nil, nil, func() {}, err
	}
	fromNodeID, err := cString("from graph node id", input.FromNodeID)
	if err != nil {
		freeCString(graphName)
		return nil, nil, nil, nil, func() {}, err
	}
	edgeType, err := cString("graph edge type", input.EdgeType)
	if err != nil {
		freeCString(graphName)
		freeCString(fromNodeID)
		return nil, nil, nil, nil, func() {}, err
	}
	toNodeID, err := cString("to graph node id", input.ToNodeID)
	if err != nil {
		freeCString(graphName)
		freeCString(fromNodeID)
		freeCString(edgeType)
		return nil, nil, nil, nil, func() {}, err
	}
	cleanup := func() {
		freeCString(graphName)
		freeCString(fromNodeID)
		freeCString(edgeType)
		freeCString(toNodeID)
	}
	return graphName, fromNodeID, edgeType, toNodeID, cleanup, nil
}

func optionalCString(context string, value *string) (*C.char, func(), error) {
	if value == nil {
		return nil, func() {}, nil
	}
	out, err := cString(context, *value)
	if err != nil {
		return nil, func() {}, err
	}
	return out, func() { freeCString(out) }, nil
}

func newCGraphInfo() *C.zova_graph_info {
	return (*C.zova_graph_info)(C.calloc(1, C.size_t(unsafe.Sizeof(C.zova_graph_info{}))))
}

func freeCGraphInfo(info *C.zova_graph_info) {
	if info == nil {
		return
	}
	C.zova_graph_info_free(info)
	C.free(unsafe.Pointer(info))
}

func newCGraphList() *C.zova_graph_list {
	return (*C.zova_graph_list)(C.calloc(1, C.size_t(unsafe.Sizeof(C.zova_graph_list{}))))
}

func freeCGraphList(list *C.zova_graph_list) {
	if list == nil {
		return
	}
	C.zova_graph_list_free(list)
	C.free(unsafe.Pointer(list))
}

func newCGraphNode() *C.zova_graph_node {
	return (*C.zova_graph_node)(C.calloc(1, C.size_t(unsafe.Sizeof(C.zova_graph_node{}))))
}

func freeCGraphNode(node *C.zova_graph_node) {
	if node == nil {
		return
	}
	C.zova_graph_node_free(node)
	C.free(unsafe.Pointer(node))
}

func newCGraphEdge() *C.zova_graph_edge {
	return (*C.zova_graph_edge)(C.calloc(1, C.size_t(unsafe.Sizeof(C.zova_graph_edge{}))))
}

func freeCGraphEdge(edge *C.zova_graph_edge) {
	if edge == nil {
		return
	}
	C.zova_graph_edge_free(edge)
	C.free(unsafe.Pointer(edge))
}

func newCGraphNeighborResults() *C.zova_graph_neighbor_results {
	return (*C.zova_graph_neighbor_results)(C.calloc(1, C.size_t(unsafe.Sizeof(C.zova_graph_neighbor_results{}))))
}

func freeCGraphNeighborResults(results *C.zova_graph_neighbor_results) {
	if results == nil {
		return
	}
	C.zova_graph_neighbor_results_free(results)
	C.free(unsafe.Pointer(results))
}

func newCGraphWalkResults() *C.zova_graph_walk_results {
	return (*C.zova_graph_walk_results)(C.calloc(1, C.size_t(unsafe.Sizeof(C.zova_graph_walk_results{}))))
}

func freeCGraphWalkResults(results *C.zova_graph_walk_results) {
	if results == nil {
		return
	}
	C.zova_graph_walk_results_free(results)
	C.free(unsafe.Pointer(results))
}

func copyGraphInfo(info *C.zova_graph_info) GraphInfo {
	return GraphInfo{
		Name:      cStringN(info.name, info.name_len),
		NodeCount: uint64(info.node_count),
		EdgeCount: uint64(info.edge_count),
	}
}

func copyGraphList(list *C.zova_graph_list) []GraphInfo {
	if list == nil || list.len == 0 {
		return []GraphInfo{}
	}
	items := unsafe.Slice(list.items, int(list.len))
	out := make([]GraphInfo, len(items))
	for i := range items {
		out[i] = copyGraphInfo(&items[i])
	}
	return out
}

func copyGraphNode(node *C.zova_graph_node) GraphNode {
	return GraphNode{
		GraphName:       cStringN(node.graph_name, node.graph_name_len),
		NodeID:          cStringN(node.node_id, node.node_id_len),
		Kind:            cStringN(node.kind, node.kind_len),
		TargetType:      GraphTargetType(node.target_type),
		TargetNamespace: optionalStringN(node.target_namespace, node.target_namespace_len, node.has_target_namespace),
		TargetRef:       optionalStringN(node.target_ref, node.target_ref_len, node.has_target_ref),
	}
}

func copyGraphEdge(edge *C.zova_graph_edge) GraphEdge {
	return GraphEdge{
		GraphName:  cStringN(edge.graph_name, edge.graph_name_len),
		FromNodeID: cStringN(edge.from_node_id, edge.from_node_id_len),
		EdgeType:   cStringN(edge.edge_type, edge.edge_type_len),
		ToNodeID:   cStringN(edge.to_node_id, edge.to_node_id_len),
	}
}

func copyGraphNeighbors(results *C.zova_graph_neighbor_results) []GraphNeighbor {
	if results == nil || results.len == 0 {
		return []GraphNeighbor{}
	}
	items := unsafe.Slice(results.items, int(results.len))
	out := make([]GraphNeighbor, len(items))
	for i, item := range items {
		out[i] = GraphNeighbor{
			NodeID:   cStringN(item.node_id, item.node_id_len),
			Kind:     cStringN(item.kind, item.kind_len),
			EdgeType: cStringN(item.edge_type, item.edge_type_len),
		}
	}
	return out
}

func copyGraphWalk(results *C.zova_graph_walk_results) []GraphWalkItem {
	if results == nil || results.len == 0 {
		return []GraphWalkItem{}
	}
	items := unsafe.Slice(results.items, int(results.len))
	out := make([]GraphWalkItem, len(items))
	for i, item := range items {
		out[i] = GraphWalkItem{
			NodeID:            cStringN(item.node_id, item.node_id_len),
			Kind:              cStringN(item.kind, item.kind_len),
			Depth:             uint32(item.depth),
			PredecessorNodeID: optionalStringN(item.predecessor_node_id, item.predecessor_node_id_len, item.has_predecessor_node_id),
			EdgeType:          optionalStringN(item.edge_type, item.edge_type_len, item.has_edge_type),
		}
	}
	return out
}

func optionalStringN(value *C.char, length C.size_t, hasValue C.uint8_t) *string {
	if hasValue == 0 {
		return nil
	}
	out := cStringN(value, length)
	return &out
}
