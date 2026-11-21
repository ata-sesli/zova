package zova

/*
#include <stdlib.h>
#include "zova.h"
*/
import "C"

import "unsafe"

// Node and edge keys are opaque database-assigned int64 values. They identify
// a row while it exists and carry no other meaning; do not persist them across
// a rebuild of the graph.

// GraphDegreeOptions selects the edges counted by GraphDegree.
type GraphDegreeOptions struct {
	GraphName string
	NodeID    string
	Direction GraphNeighborDirection
	EdgeType  *string
}

// GraphKeyedNode is a node row identified by its opaque key.
type GraphKeyedNode struct {
	NodeKey      int64
	NodeID       string
	Kind         string
	CreatedOrder int64
}

// GraphKeyedEdge is an edge row identified by its opaque key. Endpoints are
// node keys.
type GraphKeyedEdge struct {
	EdgeKey       int64
	SourceNodeKey int64
	EdgeType      string
	TargetNodeKey int64
	CreatedOrder  int64
}

// GraphKeyedNeighbor is a neighbor reached through one edge, with both keys.
type GraphKeyedNeighbor struct {
	EdgeKey         int64
	NeighborNodeKey int64
	NodeID          string
	Kind            string
	EdgeType        string
}

// GraphKeyedDegreeOptions selects the edges counted for each node key.
type GraphKeyedDegreeOptions struct {
	GraphName string
	NodeKeys  []int64
	Direction GraphNeighborDirection
	EdgeType  *string
}

// GraphEdgePayloadReplacement replaces the opaque payload of one edge.
type GraphEdgePayloadReplacement struct {
	EdgeKey int64
	Payload []byte
}

// GraphScanCursor is a scan position. The zero value starts a scan; otherwise
// pass the CreatedOrder and key of the last row already returned.
type GraphScanCursor struct {
	CreatedOrder int64
	Key          int64
}

// GraphScanOptions configures one page of GraphScan.
type GraphScanOptions struct {
	GraphName string
	NodeAfter GraphScanCursor
	EdgeAfter GraphScanCursor
	NodeLimit uint
	EdgeLimit uint
}

// GraphScanPage is one page of nodes and edges in (CreatedOrder, key) order.
type GraphScanPage struct {
	Nodes        []GraphKeyedNode
	Edges        []GraphKeyedEdge
	HasMoreNodes bool
	HasMoreEdges bool
}

// GraphWalkDirectionOptions configures a bounded walk in one direction. The
// start node is returned at depth 0 and counts toward Limit.
type GraphWalkDirectionOptions struct {
	GraphName   string
	StartNodeID string
	Direction   GraphNeighborDirection
	EdgeType    *string
	MaxDepth    uint32
	Limit       uint
}

// GraphWalkProfile holds diagnostic timings and counters for one walk.
type GraphWalkProfile struct {
	MutexWaitMS                float64
	RootLookupMS               float64
	AdjacencyPrepareMS         float64
	AdjacencyExecuteMS         float64
	BFSBookkeepingAllocationMS float64
	CABIResultExportMS         float64
	TotalProfiledMS            float64
	FrontierExpansions         uint64
	AdjacencyQueryBinds        uint64
	AdjacencyRowsStepped       uint64
	ResultCount                uint64
}

// GraphFreshNodeInput is a node row for a fresh graph build. Rows are
// addressed by their input position.
type GraphFreshNodeInput struct {
	NodeID          string
	Kind            string
	TargetType      GraphTargetType
	TargetNamespace *string
	TargetRef       *string
}

// GraphFreshEdgeInput connects two node rows of the same fresh build by
// their input positions.
type GraphFreshEdgeInput struct {
	FromNodeOrdinal uint
	EdgeType        string
	ToNodeOrdinal   uint
}

// GraphFreshEdgePayloadInput is a fresh-build edge with an opaque payload.
type GraphFreshEdgePayloadInput struct {
	FromNodeOrdinal uint
	EdgeType        string
	ToNodeOrdinal   uint
	Payload         []byte
}

// GraphFreshKeys holds the keys assigned by a fresh build, aligned with the
// node and edge inputs.
type GraphFreshKeys struct {
	NodeKeys []int64
	EdgeKeys []int64
}

// PutGraphNodes creates or updates many graph nodes atomically.
func (db *DB) PutGraphNodes(inputs []GraphNodeInput) error {
	var arena cArena
	defer arena.free()
	nodes, err := arena.graphNodeInputs(inputs)
	if err != nil {
		return err
	}
	return db.withLock(func() error {
		request := C.zova_graph_node_put_many_request{db: db.ptr, nodes: nodes, nodes_len: C.size_t(len(inputs))}
		return statusFromDB(db, C.zova_graph_node_put_many(&request))
	})
}

// PutGraphEdges creates many directed graph edges atomically.
func (db *DB) PutGraphEdges(inputs []GraphEdgeInput) error {
	var arena cArena
	defer arena.free()
	edges, err := arena.graphEdgeInputs(inputs)
	if err != nil {
		return err
	}
	return db.withLock(func() error {
		request := C.zova_graph_edge_put_many_request{db: db.ptr, edges: edges, edges_len: C.size_t(len(inputs))}
		return statusFromDB(db, C.zova_graph_edge_put_many(&request))
	})
}

// DeleteGraphNodes deletes many nodes of one graph, and their incident edges,
// atomically.
func (db *DB) DeleteGraphNodes(graphName string, nodeIDs []string) error {
	var arena cArena
	defer arena.free()
	cGraph, err := arena.str("graph name", graphName)
	if err != nil {
		return err
	}
	cIDs, err := arena.strs("graph node id", nodeIDs)
	if err != nil {
		return err
	}
	return db.withLock(func() error {
		request := C.zova_graph_node_delete_many_request{db: db.ptr, graph_name: cGraph, node_ids: cIDs, node_count: C.size_t(len(nodeIDs))}
		return statusFromDB(db, C.zova_graph_node_delete_many(&request))
	})
}

// DeleteGraphEdges deletes many exact graph edges atomically.
func (db *DB) DeleteGraphEdges(inputs []GraphEdgeInput) error {
	var arena cArena
	defer arena.free()
	edges, err := arena.graphEdgeInputs(inputs)
	if err != nil {
		return err
	}
	return db.withLock(func() error {
		request := C.zova_graph_edge_delete_many_request{db: db.ptr, edges: edges, edges_len: C.size_t(len(inputs))}
		return statusFromDB(db, C.zova_graph_edge_delete_many(&request))
	})
}

// GraphDegree counts the incoming or outgoing edges of one node.
func (db *DB) GraphDegree(options GraphDegreeOptions) (uint64, error) {
	var arena cArena
	defer arena.free()
	cGraph, err := arena.str("graph name", options.GraphName)
	if err != nil {
		return 0, err
	}
	cNode, err := arena.str("graph node id", options.NodeID)
	if err != nil {
		return 0, err
	}
	cEdgeType, err := arena.optionalStr("graph edge type", options.EdgeType)
	if err != nil {
		return 0, err
	}
	out := (*C.uint64_t)(arena.alloc(1, unsafe.Sizeof(C.uint64_t(0))))
	err = db.withLock(func() error {
		request := C.zova_graph_degree_request{
			db: db.ptr, graph_name: cGraph, node_id: cNode,
			direction: C.int(options.Direction), edge_type: cEdgeType, out_degree: out,
		}
		return statusFromDB(db, C.zova_graph_degree(&request))
	})
	if err != nil {
		return 0, err
	}
	return uint64(*out), nil
}

// PutGraphNodesKeyed creates or updates many nodes atomically and returns
// their keys in input order.
func (db *DB) PutGraphNodesKeyed(inputs []GraphNodeInput) ([]int64, error) {
	var arena cArena
	defer arena.free()
	nodes, err := arena.graphNodeInputs(inputs)
	if err != nil {
		return nil, err
	}
	keys := (*C.int64_t)(arena.alloc(len(inputs), unsafe.Sizeof(C.int64_t(0))))
	err = db.withLock(func() error {
		request := C.zova_graph_node_put_many_keyed_request{
			db: db.ptr, nodes: nodes, nodes_len: C.size_t(len(inputs)),
			out_node_keys: keys, out_node_keys_capacity: C.size_t(len(inputs)),
		}
		return statusFromDB(db, C.zova_graph_node_put_many_keyed(&request))
	})
	if err != nil {
		return nil, err
	}
	return copyInt64s(keys, len(inputs)), nil
}

// PutGraphEdgesKeyed creates many edges atomically and returns their keys in
// input order.
func (db *DB) PutGraphEdgesKeyed(inputs []GraphEdgeInput) ([]int64, error) {
	var arena cArena
	defer arena.free()
	edges, err := arena.graphEdgeInputs(inputs)
	if err != nil {
		return nil, err
	}
	keys := (*C.int64_t)(arena.alloc(len(inputs), unsafe.Sizeof(C.int64_t(0))))
	err = db.withLock(func() error {
		request := C.zova_graph_edge_put_many_keyed_request{
			db: db.ptr, edges: edges, edges_len: C.size_t(len(inputs)),
			out_edge_keys: keys, out_edge_keys_capacity: C.size_t(len(inputs)),
		}
		return statusFromDB(db, C.zova_graph_edge_put_many_keyed(&request))
	})
	if err != nil {
		return nil, err
	}
	return copyInt64s(keys, len(inputs)), nil
}

// GetGraphNodesKeyed looks up nodes by key. The result is aligned with keys;
// a missing key yields nil.
func (db *DB) GetGraphNodesKeyed(graphName string, keys []int64) ([]*GraphKeyedNode, error) {
	var arena cArena
	defer arena.free()
	cGraph, err := arena.str("graph name", graphName)
	if err != nil {
		return nil, err
	}
	cKeys := arena.int64s(keys)
	results := (*C.zova_graph_keyed_node_results)(C.calloc(1, C.size_t(unsafe.Sizeof(C.zova_graph_keyed_node_results{}))))
	defer func() {
		C.zova_graph_keyed_node_results_free(results)
		C.free(unsafe.Pointer(results))
	}()
	err = db.withLock(func() error {
		request := C.zova_graph_nodes_get_many_keyed_request{db: db.ptr, graph_name: cGraph, node_keys: cKeys, key_count: C.size_t(len(keys)), out_results: results}
		return statusFromDB(db, C.zova_graph_nodes_get_many_keyed(&request))
	})
	if err != nil {
		return nil, err
	}
	out := make([]*GraphKeyedNode, results.len)
	if results.len > 0 {
		for i, item := range unsafe.Slice(results.items, int(results.len)) {
			if item.found == 0 {
				continue
			}
			out[i] = &GraphKeyedNode{
				NodeKey: int64(item.node_key), NodeID: cStringN(item.node_id, item.node_id_len),
				Kind: cStringN(item.kind, item.kind_len), CreatedOrder: int64(item.created_order),
			}
		}
	}
	return out, nil
}

// GetGraphEdgesKeyed looks up edges by key. The result is aligned with keys;
// a missing key yields nil.
func (db *DB) GetGraphEdgesKeyed(graphName string, keys []int64) ([]*GraphKeyedEdge, error) {
	var arena cArena
	defer arena.free()
	cGraph, err := arena.str("graph name", graphName)
	if err != nil {
		return nil, err
	}
	cKeys := arena.int64s(keys)
	results := (*C.zova_graph_keyed_edge_results)(C.calloc(1, C.size_t(unsafe.Sizeof(C.zova_graph_keyed_edge_results{}))))
	defer func() {
		C.zova_graph_keyed_edge_results_free(results)
		C.free(unsafe.Pointer(results))
	}()
	err = db.withLock(func() error {
		request := C.zova_graph_edges_get_many_keyed_request{db: db.ptr, graph_name: cGraph, edge_keys: cKeys, key_count: C.size_t(len(keys)), out_results: results}
		return statusFromDB(db, C.zova_graph_edges_get_many_keyed(&request))
	})
	if err != nil {
		return nil, err
	}
	out := make([]*GraphKeyedEdge, results.len)
	if results.len > 0 {
		for i, item := range unsafe.Slice(results.items, int(results.len)) {
			if item.found == 0 {
				continue
			}
			out[i] = &GraphKeyedEdge{
				EdgeKey: int64(item.edge_key), SourceNodeKey: int64(item.source_node_key),
				EdgeType:      cStringN(item.edge_type, item.edge_type_len),
				TargetNodeKey: int64(item.target_node_key), CreatedOrder: int64(item.created_order),
			}
		}
	}
	return out, nil
}

// GraphNeighborsKeyed is GraphNeighbors with edge and neighbor node keys.
func (db *DB) GraphNeighborsKeyed(options GraphNeighborsOptions) ([]GraphKeyedNeighbor, error) {
	var arena cArena
	defer arena.free()
	cGraph, err := arena.str("graph name", options.GraphName)
	if err != nil {
		return nil, err
	}
	cNode, err := arena.str("graph node id", options.NodeID)
	if err != nil {
		return nil, err
	}
	cEdgeType, err := arena.optionalStr("graph edge type", options.EdgeType)
	if err != nil {
		return nil, err
	}
	results := (*C.zova_graph_keyed_neighbor_results)(C.calloc(1, C.size_t(unsafe.Sizeof(C.zova_graph_keyed_neighbor_results{}))))
	defer func() {
		C.zova_graph_keyed_neighbor_results_free(results)
		C.free(unsafe.Pointer(results))
	}()
	err = db.withLock(func() error {
		request := C.zova_graph_neighbors_keyed_request{
			db: db.ptr, graph_name: cGraph, node_id: cNode, direction: C.int(options.Direction),
			edge_type: cEdgeType, limit: C.size_t(options.Limit), out_results: results,
		}
		return statusFromDB(db, C.zova_graph_neighbors_keyed(&request))
	})
	if err != nil {
		return nil, err
	}
	out := make([]GraphKeyedNeighbor, results.len)
	if results.len > 0 {
		for i, item := range unsafe.Slice(results.items, int(results.len)) {
			out[i] = GraphKeyedNeighbor{
				EdgeKey: int64(item.edge_key), NeighborNodeKey: int64(item.neighbor_node_key),
				NodeID: cStringN(item.node_id, item.node_id_len), Kind: cStringN(item.kind, item.kind_len),
				EdgeType: cStringN(item.edge_type, item.edge_type_len),
			}
		}
	}
	return out, nil
}

// GraphDegreesKeyed counts edges for each node key, aligned with NodeKeys.
func (db *DB) GraphDegreesKeyed(options GraphKeyedDegreeOptions) ([]uint64, error) {
	var arena cArena
	defer arena.free()
	cGraph, err := arena.str("graph name", options.GraphName)
	if err != nil {
		return nil, err
	}
	cEdgeType, err := arena.optionalStr("graph edge type", options.EdgeType)
	if err != nil {
		return nil, err
	}
	count := len(options.NodeKeys)
	cKeys := arena.int64s(options.NodeKeys)
	degrees := (*C.uint64_t)(arena.alloc(count, unsafe.Sizeof(C.uint64_t(0))))
	err = db.withLock(func() error {
		request := C.zova_graph_degree_many_keyed_request{
			db: db.ptr, graph_name: cGraph, node_keys: cKeys, node_count: C.size_t(count),
			direction: C.int(options.Direction), edge_type: cEdgeType,
			out_degrees: degrees, out_degrees_capacity: C.size_t(count),
		}
		return statusFromDB(db, C.zova_graph_degree_many_keyed(&request))
	})
	if err != nil {
		return nil, err
	}
	out := make([]uint64, count)
	if count > 0 {
		for i, value := range unsafe.Slice(degrees, count) {
			out[i] = uint64(value)
		}
	}
	return out, nil
}

// GetGraphEdgePayloads returns edge payloads aligned with keys. A missing
// edge yields nil; an edge without a payload yields an empty, non-nil slice.
func (db *DB) GetGraphEdgePayloads(graphName string, keys []int64) ([][]byte, error) {
	var arena cArena
	defer arena.free()
	cGraph, err := arena.str("graph name", graphName)
	if err != nil {
		return nil, err
	}
	cKeys := arena.int64s(keys)
	results := (*C.zova_graph_edge_payload_results)(C.calloc(1, C.size_t(unsafe.Sizeof(C.zova_graph_edge_payload_results{}))))
	defer func() {
		C.zova_graph_edge_payload_results_free(results)
		C.free(unsafe.Pointer(results))
	}()
	err = db.withLock(func() error {
		request := C.zova_graph_edge_payload_get_many_request{db: db.ptr, graph_name: cGraph, edge_keys: cKeys, key_count: C.size_t(len(keys)), out_results: results}
		return statusFromDB(db, C.zova_graph_edge_payload_get_many(&request))
	})
	if err != nil {
		return nil, err
	}
	out := make([][]byte, results.len)
	if results.len > 0 {
		for i, item := range unsafe.Slice(results.items, int(results.len)) {
			if item.found == 0 {
				continue
			}
			out[i] = []byte{}
			if item.payload_len > 0 {
				out[i] = C.GoBytes(unsafe.Pointer(item.payload), C.int(item.payload_len))
			}
		}
	}
	return out, nil
}

// ReplaceGraphEdgePayloads replaces many edge payloads atomically.
func (db *DB) ReplaceGraphEdgePayloads(graphName string, replacements []GraphEdgePayloadReplacement) error {
	var arena cArena
	defer arena.free()
	cGraph, err := arena.str("graph name", graphName)
	if err != nil {
		return err
	}
	ptr := arena.alloc(len(replacements), unsafe.Sizeof(C.zova_graph_edge_payload_replacement{}))
	if ptr != nil {
		rows := unsafe.Slice((*C.zova_graph_edge_payload_replacement)(ptr), len(replacements))
		for i, replacement := range replacements {
			rows[i] = C.zova_graph_edge_payload_replacement{
				edge_key: C.int64_t(replacement.EdgeKey), payload: arena.bytes(replacement.Payload),
				payload_len: C.size_t(len(replacement.Payload)),
			}
		}
	}
	return db.withLock(func() error {
		request := C.zova_graph_edge_payload_replace_many_request{
			db: db.ptr, graph_name: cGraph,
			replacements:      (*C.zova_graph_edge_payload_replacement)(ptr),
			replacement_count: C.size_t(len(replacements)),
		}
		return statusFromDB(db, C.zova_graph_edge_payload_replace_many(&request))
	})
}

// GraphScan returns one page of nodes and edges after the given cursors.
func (db *DB) GraphScan(options GraphScanOptions) (GraphScanPage, error) {
	var arena cArena
	defer arena.free()
	cGraph, err := arena.str("graph name", options.GraphName)
	if err != nil {
		return GraphScanPage{}, err
	}
	results := (*C.zova_graph_scan_results)(C.calloc(1, C.size_t(unsafe.Sizeof(C.zova_graph_scan_results{}))))
	defer func() {
		C.zova_graph_scan_results_free(results)
		C.free(unsafe.Pointer(results))
	}()
	err = db.withLock(func() error {
		request := C.zova_graph_scan_request{
			db: db.ptr, graph_name: cGraph,
			node_after: C.zova_graph_scan_cursor{created_order: C.int64_t(options.NodeAfter.CreatedOrder), key: C.int64_t(options.NodeAfter.Key)},
			edge_after: C.zova_graph_scan_cursor{created_order: C.int64_t(options.EdgeAfter.CreatedOrder), key: C.int64_t(options.EdgeAfter.Key)},
			node_limit: C.size_t(options.NodeLimit), edge_limit: C.size_t(options.EdgeLimit),
			out_results: results,
		}
		return statusFromDB(db, C.zova_graph_scan(&request))
	})
	if err != nil {
		return GraphScanPage{}, err
	}
	page := GraphScanPage{
		Nodes:        make([]GraphKeyedNode, results.nodes_len),
		Edges:        make([]GraphKeyedEdge, results.edges_len),
		HasMoreNodes: results.has_more_nodes != 0,
		HasMoreEdges: results.has_more_edges != 0,
	}
	if results.nodes_len > 0 {
		for i, item := range unsafe.Slice(results.nodes, int(results.nodes_len)) {
			page.Nodes[i] = GraphKeyedNode{
				NodeKey: int64(item.node_key), NodeID: cStringN(item.node_id, item.node_id_len),
				Kind: cStringN(item.kind, item.kind_len), CreatedOrder: int64(item.created_order),
			}
		}
	}
	if results.edges_len > 0 {
		for i, item := range unsafe.Slice(results.edges, int(results.edges_len)) {
			page.Edges[i] = GraphKeyedEdge{
				EdgeKey: int64(item.edge_key), SourceNodeKey: int64(item.source_node_key),
				EdgeType:      cStringN(item.edge_type, item.edge_type_len),
				TargetNodeKey: int64(item.target_node_key), CreatedOrder: int64(item.created_order),
			}
		}
	}
	return page, nil
}

// GraphWalkDirection returns a bounded walk that follows edges in one
// direction.
func (db *DB) GraphWalkDirection(options GraphWalkDirectionOptions) ([]GraphWalkItem, error) {
	items, _, err := db.graphWalkDirection(options, false)
	return items, err
}

// GraphWalkDirectionProfiled is GraphWalkDirection with diagnostic timings.
func (db *DB) GraphWalkDirectionProfiled(options GraphWalkDirectionOptions) ([]GraphWalkItem, GraphWalkProfile, error) {
	return db.graphWalkDirection(options, true)
}

func (db *DB) graphWalkDirection(options GraphWalkDirectionOptions, profiled bool) ([]GraphWalkItem, GraphWalkProfile, error) {
	var arena cArena
	defer arena.free()
	cGraph, err := arena.str("graph name", options.GraphName)
	if err != nil {
		return nil, GraphWalkProfile{}, err
	}
	cStart, err := arena.str("graph start node id", options.StartNodeID)
	if err != nil {
		return nil, GraphWalkProfile{}, err
	}
	cEdgeType, err := arena.optionalStr("graph edge type", options.EdgeType)
	if err != nil {
		return nil, GraphWalkProfile{}, err
	}
	results := newCGraphWalkResults()
	defer freeCGraphWalkResults(results)
	profile := (*C.zova_graph_walk_profile)(arena.alloc(1, unsafe.Sizeof(C.zova_graph_walk_profile{})))
	err = db.withLock(func() error {
		if profiled {
			request := C.zova_graph_walk_direction_profiled_request{
				db: db.ptr, graph_name: cGraph, start_node_id: cStart, direction: C.int(options.Direction),
				edge_type: cEdgeType, max_depth: C.uint32_t(options.MaxDepth), limit: C.size_t(options.Limit),
				out_results: results, out_profile: profile,
			}
			return statusFromDB(db, C.zova_graph_walk_direction_profiled(&request))
		}
		request := C.zova_graph_walk_direction_request{
			db: db.ptr, graph_name: cGraph, start_node_id: cStart, direction: C.int(options.Direction),
			edge_type: cEdgeType, max_depth: C.uint32_t(options.MaxDepth), limit: C.size_t(options.Limit),
			out_results: results,
		}
		return statusFromDB(db, C.zova_graph_walk_direction(&request))
	})
	if err != nil {
		return nil, GraphWalkProfile{}, err
	}
	return copyGraphWalk(results), GraphWalkProfile{
		MutexWaitMS:                float64(profile.mutex_wait_ms),
		RootLookupMS:               float64(profile.root_lookup_ms),
		AdjacencyPrepareMS:         float64(profile.adjacency_prepare_ms),
		AdjacencyExecuteMS:         float64(profile.adjacency_execute_ms),
		BFSBookkeepingAllocationMS: float64(profile.bfs_bookkeeping_allocation_ms),
		CABIResultExportMS:         float64(profile.c_abi_result_export_ms),
		TotalProfiledMS:            float64(profile.total_profiled_ms),
		FrontierExpansions:         uint64(profile.frontier_expansions),
		AdjacencyQueryBinds:        uint64(profile.adjacency_query_binds),
		AdjacencyRowsStepped:       uint64(profile.adjacency_rows_stepped),
		ResultCount:                uint64(profile.result_count),
	}, nil
}

// BuildFreshGraphKeyed creates graphName and loads nodes and edges in one
// operation. The graph must not exist yet.
func (db *DB) BuildFreshGraphKeyed(graphName string, nodes []GraphFreshNodeInput, edges []GraphFreshEdgeInput) (GraphFreshKeys, error) {
	return db.buildFreshGraph(graphName, nodes, edges, false)
}

// BuildFreshGraphPreparedKeyed is BuildFreshGraphKeyed through the prepared
// bulk loader.
func (db *DB) BuildFreshGraphPreparedKeyed(graphName string, nodes []GraphFreshNodeInput, edges []GraphFreshEdgeInput) (GraphFreshKeys, error) {
	return db.buildFreshGraph(graphName, nodes, edges, true)
}

func (db *DB) buildFreshGraph(graphName string, nodes []GraphFreshNodeInput, edges []GraphFreshEdgeInput, prepared bool) (GraphFreshKeys, error) {
	var arena cArena
	defer arena.free()
	cGraph, err := arena.str("graph name", graphName)
	if err != nil {
		return GraphFreshKeys{}, err
	}
	cNodes, err := arena.graphFreshNodeInputs(nodes)
	if err != nil {
		return GraphFreshKeys{}, err
	}
	ptr := arena.alloc(len(edges), unsafe.Sizeof(C.zova_graph_fresh_edge_input{}))
	if ptr != nil {
		rows := unsafe.Slice((*C.zova_graph_fresh_edge_input)(ptr), len(edges))
		for i, edge := range edges {
			edgeType, err := arena.str("graph edge type", edge.EdgeType)
			if err != nil {
				return GraphFreshKeys{}, err
			}
			rows[i] = C.zova_graph_fresh_edge_input{
				from_node_ordinal: C.size_t(edge.FromNodeOrdinal), edge_type: edgeType,
				to_node_ordinal: C.size_t(edge.ToNodeOrdinal),
			}
		}
	}
	nodeKeys := (*C.int64_t)(arena.alloc(len(nodes), unsafe.Sizeof(C.int64_t(0))))
	edgeKeys := (*C.int64_t)(arena.alloc(len(edges), unsafe.Sizeof(C.int64_t(0))))
	err = db.withLock(func() error {
		request := C.zova_graph_build_fresh_keyed_request{
			db: db.ptr, graph_name: cGraph,
			nodes: cNodes, nodes_len: C.size_t(len(nodes)),
			edges: (*C.zova_graph_fresh_edge_input)(ptr), edges_len: C.size_t(len(edges)),
			out_node_keys: nodeKeys, out_node_keys_capacity: C.size_t(len(nodes)),
			out_edge_keys: edgeKeys, out_edge_keys_capacity: C.size_t(len(edges)),
		}
		if prepared {
			return statusFromDB(db, C.zova_graph_build_fresh_prepared_keyed(&request))
		}
		return statusFromDB(db, C.zova_graph_build_fresh_keyed(&request))
	})
	if err != nil {
		return GraphFreshKeys{}, err
	}
	return GraphFreshKeys{NodeKeys: copyInt64s(nodeKeys, len(nodes)), EdgeKeys: copyInt64s(edgeKeys, len(edges))}, nil
}

// BuildFreshGraphPreparedKeyedWithPayloads is BuildFreshGraphPreparedKeyed
// with an opaque payload on each edge.
func (db *DB) BuildFreshGraphPreparedKeyedWithPayloads(graphName string, nodes []GraphFreshNodeInput, edges []GraphFreshEdgePayloadInput) (GraphFreshKeys, error) {
	var arena cArena
	defer arena.free()
	cGraph, err := arena.str("graph name", graphName)
	if err != nil {
		return GraphFreshKeys{}, err
	}
	cNodes, err := arena.graphFreshNodeInputs(nodes)
	if err != nil {
		return GraphFreshKeys{}, err
	}
	cEdges, err := arena.graphFreshEdgePayloadInputs(edges)
	if err != nil {
		return GraphFreshKeys{}, err
	}
	nodeKeys := (*C.int64_t)(arena.alloc(len(nodes), unsafe.Sizeof(C.int64_t(0))))
	edgeKeys := (*C.int64_t)(arena.alloc(len(edges), unsafe.Sizeof(C.int64_t(0))))
	err = db.withLock(func() error {
		request := C.zova_graph_build_fresh_prepared_keyed_with_payloads_request{
			db: db.ptr, graph_name: cGraph,
			nodes: cNodes, nodes_len: C.size_t(len(nodes)),
			edges: cEdges, edges_len: C.size_t(len(edges)),
			out_node_keys: nodeKeys, out_node_keys_capacity: C.size_t(len(nodes)),
			out_edge_keys: edgeKeys, out_edge_keys_capacity: C.size_t(len(edges)),
		}
		return statusFromDB(db, C.zova_graph_build_fresh_prepared_keyed_with_payloads(&request))
	})
	if err != nil {
		return GraphFreshKeys{}, err
	}
	return GraphFreshKeys{NodeKeys: copyInt64s(nodeKeys, len(nodes)), EdgeKeys: copyInt64s(edgeKeys, len(edges))}, nil
}

func (a *cArena) graphNodeInputs(inputs []GraphNodeInput) (*C.zova_graph_node_input, error) {
	ptr := a.alloc(len(inputs), unsafe.Sizeof(C.zova_graph_node_input{}))
	if ptr == nil {
		return nil, nil
	}
	rows := unsafe.Slice((*C.zova_graph_node_input)(ptr), len(inputs))
	for i, input := range inputs {
		graphName, err := a.str("graph name", input.GraphName)
		if err != nil {
			return nil, err
		}
		nodeID, err := a.str("graph node id", input.NodeID)
		if err != nil {
			return nil, err
		}
		kind, err := a.str("graph node kind", input.Kind)
		if err != nil {
			return nil, err
		}
		namespace, err := a.optionalStr("graph target namespace", input.TargetNamespace)
		if err != nil {
			return nil, err
		}
		ref, err := a.optionalStr("graph target ref", input.TargetRef)
		if err != nil {
			return nil, err
		}
		rows[i] = C.zova_graph_node_input{
			graph_name: graphName, node_id: nodeID, kind: kind,
			target_type: C.int(input.TargetType), target_namespace: namespace, target_ref: ref,
		}
	}
	return (*C.zova_graph_node_input)(ptr), nil
}

func (a *cArena) graphEdgeInputs(inputs []GraphEdgeInput) (*C.zova_graph_edge_input, error) {
	ptr := a.alloc(len(inputs), unsafe.Sizeof(C.zova_graph_edge_input{}))
	if ptr == nil {
		return nil, nil
	}
	rows := unsafe.Slice((*C.zova_graph_edge_input)(ptr), len(inputs))
	for i, input := range inputs {
		graphName, err := a.str("graph name", input.GraphName)
		if err != nil {
			return nil, err
		}
		from, err := a.str("from graph node id", input.FromNodeID)
		if err != nil {
			return nil, err
		}
		edgeType, err := a.str("graph edge type", input.EdgeType)
		if err != nil {
			return nil, err
		}
		to, err := a.str("to graph node id", input.ToNodeID)
		if err != nil {
			return nil, err
		}
		rows[i] = C.zova_graph_edge_input{graph_name: graphName, from_node_id: from, edge_type: edgeType, to_node_id: to}
	}
	return (*C.zova_graph_edge_input)(ptr), nil
}

func (a *cArena) graphFreshNodeInputs(inputs []GraphFreshNodeInput) (*C.zova_graph_fresh_node_input, error) {
	ptr := a.alloc(len(inputs), unsafe.Sizeof(C.zova_graph_fresh_node_input{}))
	if ptr == nil {
		return nil, nil
	}
	rows := unsafe.Slice((*C.zova_graph_fresh_node_input)(ptr), len(inputs))
	for i, input := range inputs {
		nodeID, err := a.str("graph node id", input.NodeID)
		if err != nil {
			return nil, err
		}
		kind, err := a.str("graph node kind", input.Kind)
		if err != nil {
			return nil, err
		}
		namespace, err := a.optionalStr("graph target namespace", input.TargetNamespace)
		if err != nil {
			return nil, err
		}
		ref, err := a.optionalStr("graph target ref", input.TargetRef)
		if err != nil {
			return nil, err
		}
		rows[i] = C.zova_graph_fresh_node_input{
			node_id: nodeID, kind: kind, target_type: C.int(input.TargetType),
			target_namespace: namespace, target_ref: ref,
		}
	}
	return (*C.zova_graph_fresh_node_input)(ptr), nil
}

func (a *cArena) graphFreshEdgePayloadInputs(inputs []GraphFreshEdgePayloadInput) (*C.zova_graph_fresh_edge_payload_input, error) {
	ptr := a.alloc(len(inputs), unsafe.Sizeof(C.zova_graph_fresh_edge_payload_input{}))
	if ptr == nil {
		return nil, nil
	}
	rows := unsafe.Slice((*C.zova_graph_fresh_edge_payload_input)(ptr), len(inputs))
	for i, input := range inputs {
		edgeType, err := a.str("graph edge type", input.EdgeType)
		if err != nil {
			return nil, err
		}
		rows[i] = C.zova_graph_fresh_edge_payload_input{
			from_node_ordinal: C.size_t(input.FromNodeOrdinal), edge_type: edgeType,
			to_node_ordinal: C.size_t(input.ToNodeOrdinal),
			payload:         a.bytes(input.Payload), payload_len: C.size_t(len(input.Payload)),
		}
	}
	return (*C.zova_graph_fresh_edge_payload_input)(ptr), nil
}
