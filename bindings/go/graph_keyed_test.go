package zova

import (
	"math"
	"reflect"
	"testing"
)

func keyedNode(graph, id, kind string) GraphNodeInput {
	return GraphNodeInput{GraphName: graph, NodeID: id, Kind: kind}
}

func keyedEdge(graph, from, edgeType, to string) GraphEdgeInput {
	return GraphEdgeInput{GraphName: graph, FromNodeID: from, EdgeType: edgeType, ToNodeID: to}
}

func freshNode(id string) GraphFreshNodeInput {
	return GraphFreshNodeInput{NodeID: id, Kind: "file"}
}

func memoryDB(t *testing.T) *DB {
	t.Helper()
	db, err := CreateMemory()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return db
}

func TestGraphBatchMutationsAndDegree(t *testing.T) {
	db := memoryDB(t)
	must(t, db.CreateGraph("g"))
	must(t, db.PutGraphNodes([]GraphNodeInput{keyedNode("g", "a", "file"), keyedNode("g", "b", "file"), keyedNode("g", "c", "file")}))
	must(t, db.PutGraphEdges([]GraphEdgeInput{keyedEdge("g", "a", "calls", "b"), keyedEdge("g", "a", "calls", "c")}))
	calls := "calls"
	degree, err := db.GraphDegree(GraphDegreeOptions{GraphName: "g", NodeID: "a", Direction: GraphNeighborOutgoing, EdgeType: &calls})
	if err != nil || degree != 2 {
		t.Fatalf("GraphDegree = %d, %v", degree, err)
	}
	must(t, db.DeleteGraphEdges([]GraphEdgeInput{keyedEdge("g", "a", "calls", "b")}))
	must(t, db.DeleteGraphNodes("g", []string{"c"}))
	degree, err = db.GraphDegree(GraphDegreeOptions{GraphName: "g", NodeID: "a", Direction: GraphNeighborOutgoing})
	if err != nil || degree != 0 {
		t.Fatalf("GraphDegree after deletes = %d, %v", degree, err)
	}
	if ok, _ := db.HasGraphNode("g", "c"); ok {
		t.Fatal("DeleteGraphNodes left node c")
	}
	if err := db.PutGraphEdges([]GraphEdgeInput{keyedEdge("g", "a", "calls", "missing")}); !errorStatusIs(err, StatusGraphNodeNotFound) {
		t.Fatalf("PutGraphEdges(missing) = %v", err)
	}
}

func TestKeyedGraphCRUDPayloadsDegreesAndScan(t *testing.T) {
	db := memoryDB(t)
	must(t, db.CreateGraph("g"))
	nodeKeys, err := db.PutGraphNodesKeyed([]GraphNodeInput{keyedNode("g", "a", "file"), keyedNode("g", "b", "file"), keyedNode("g", "c", "dir")})
	if err != nil || len(nodeKeys) != 3 {
		t.Fatalf("PutGraphNodesKeyed = %v, %v", nodeKeys, err)
	}
	edgeKeys, err := db.PutGraphEdgesKeyed([]GraphEdgeInput{keyedEdge("g", "a", "calls", "b"), keyedEdge("g", "a", "contains", "c")})
	if err != nil || len(edgeKeys) != 2 {
		t.Fatalf("PutGraphEdgesKeyed = %v, %v", edgeKeys, err)
	}
	if empty, err := db.PutGraphNodesKeyed(nil); err != nil || len(empty) != 0 {
		t.Fatalf("PutGraphNodesKeyed(nil) = %v, %v", empty, err)
	}

	nodes, err := db.GetGraphNodesKeyed("g", []int64{nodeKeys[1], math.MaxInt64})
	must(t, err)
	if nodes[0] == nil || nodes[0].NodeID != "b" || nodes[0].NodeKey != nodeKeys[1] || nodes[1] != nil {
		t.Fatalf("GetGraphNodesKeyed = %+v", nodes)
	}
	edges, err := db.GetGraphEdgesKeyed("g", []int64{edgeKeys[0]})
	must(t, err)
	if edges[0] == nil || edges[0].SourceNodeKey != nodeKeys[0] || edges[0].TargetNodeKey != nodeKeys[1] || edges[0].EdgeType != "calls" {
		t.Fatalf("GetGraphEdgesKeyed = %+v", edges[0])
	}

	neighbors, err := db.GraphNeighborsKeyed(GraphNeighborsOptions{GraphName: "g", NodeID: "a", Direction: GraphNeighborOutgoing, Limit: 10})
	must(t, err)
	if len(neighbors) != 2 || neighbors[0].EdgeKey != edgeKeys[0] || neighbors[1].NeighborNodeKey != nodeKeys[2] || neighbors[1].NodeID != "c" {
		t.Fatalf("GraphNeighborsKeyed = %+v", neighbors)
	}
	degrees, err := db.GraphDegreesKeyed(GraphKeyedDegreeOptions{GraphName: "g", NodeKeys: nodeKeys, Direction: GraphNeighborOutgoing})
	if err != nil || !reflect.DeepEqual(degrees, []uint64{2, 0, 0}) {
		t.Fatalf("GraphDegreesKeyed = %v, %v", degrees, err)
	}

	must(t, db.ReplaceGraphEdgePayloads("g", []GraphEdgePayloadReplacement{{EdgeKey: edgeKeys[0], Payload: []byte("weight=3")}}))
	payloads, err := db.GetGraphEdgePayloads("g", []int64{edgeKeys[0], edgeKeys[1], math.MaxInt64})
	must(t, err)
	if string(payloads[0]) != "weight=3" || payloads[1] == nil || len(payloads[1]) != 0 || payloads[2] != nil {
		t.Fatalf("GetGraphEdgePayloads = %q", payloads)
	}

	options := GraphScanOptions{GraphName: "g", NodeLimit: 2, EdgeLimit: 1}
	first, err := db.GraphScan(options)
	must(t, err)
	if len(first.Nodes) != 2 || len(first.Edges) != 1 || !first.HasMoreNodes || !first.HasMoreEdges {
		t.Fatalf("first scan page = %+v", first)
	}
	lastNode, lastEdge := first.Nodes[1], first.Edges[0]
	options.NodeAfter = GraphScanCursor{CreatedOrder: lastNode.CreatedOrder, Key: lastNode.NodeKey}
	options.EdgeAfter = GraphScanCursor{CreatedOrder: lastEdge.CreatedOrder, Key: lastEdge.EdgeKey}
	second, err := db.GraphScan(options)
	must(t, err)
	if second.Nodes[0].NodeID != "c" || second.Edges[0].EdgeKey != edgeKeys[1] || second.HasMoreNodes || second.HasMoreEdges {
		t.Fatalf("second scan page = %+v", second)
	}
}

func TestDirectionalWalks(t *testing.T) {
	db := memoryDB(t)
	must(t, db.CreateGraph("g"))
	must(t, db.PutGraphNodes([]GraphNodeInput{keyedNode("g", "a", "file"), keyedNode("g", "b", "file"), keyedNode("g", "c", "file")}))
	must(t, db.PutGraphEdges([]GraphEdgeInput{keyedEdge("g", "a", "calls", "b"), keyedEdge("g", "b", "calls", "c")}))
	calls := "calls"
	options := GraphWalkDirectionOptions{GraphName: "g", StartNodeID: "c", Direction: GraphNeighborIncoming, EdgeType: &calls, MaxDepth: 5, Limit: 10}
	walk, err := db.GraphWalkDirection(options)
	must(t, err)
	var got []string
	for _, item := range walk {
		got = append(got, item.NodeID)
	}
	if !reflect.DeepEqual(got, []string{"c", "b", "a"}) || walk[2].Depth != 2 {
		t.Fatalf("incoming walk = %+v", walk)
	}
	profiled, profile, err := db.GraphWalkDirectionProfiled(options)
	must(t, err)
	if !reflect.DeepEqual(profiled, walk) || profile.ResultCount != 3 {
		t.Fatalf("profiled walk = %+v %+v", profiled, profile)
	}
	options.Direction = GraphNeighborOutgoing
	outgoing, err := db.GraphWalkDirection(options)
	if err != nil || len(outgoing) != 1 {
		t.Fatalf("outgoing walk = %+v, %v", outgoing, err)
	}
}

func TestFreshGraphBuildsPublishInputAlignedKeys(t *testing.T) {
	nodes := []GraphFreshNodeInput{freshNode("a"), freshNode("b"), freshNode("c")}
	db := memoryDB(t)
	keys, err := db.BuildFreshGraphKeyed("g", nodes, []GraphFreshEdgeInput{
		{FromNodeOrdinal: 0, EdgeType: "calls", ToNodeOrdinal: 1},
		{FromNodeOrdinal: 1, EdgeType: "calls", ToNodeOrdinal: 2},
	})
	must(t, err)
	if len(keys.NodeKeys) != 3 || len(keys.EdgeKeys) != 2 {
		t.Fatalf("BuildFreshGraphKeyed = %+v", keys)
	}
	found, err := db.GetGraphNodesKeyed("g", keys.NodeKeys)
	if err != nil || found[2] == nil || found[2].NodeID != "c" {
		t.Fatalf("lookup fresh keys = %+v, %v", found, err)
	}

	db = memoryDB(t)
	keys, err = db.BuildFreshGraphPreparedKeyedWithPayloads("p", nodes[:2], []GraphFreshEdgePayloadInput{
		{FromNodeOrdinal: 0, EdgeType: "calls", ToNodeOrdinal: 1, Payload: []byte("line=4")},
	})
	must(t, err)
	payloads, err := db.GetGraphEdgePayloads("p", keys.EdgeKeys)
	if err != nil || string(payloads[0]) != "line=4" {
		t.Fatalf("fresh payloads = %q, %v", payloads, err)
	}

	db = memoryDB(t)
	_, err = db.BuildFreshGraphPreparedKeyed("q", nodes[:1], []GraphFreshEdgeInput{{FromNodeOrdinal: 0, EdgeType: "calls", ToNodeOrdinal: 9}})
	if !errorStatusIs(err, StatusInvalidArgument) {
		t.Fatalf("out-of-range ordinal = %v", err)
	}
}

func TestVectorBatchDeleteAndMultiI8Search(t *testing.T) {
	db := memoryDB(t)
	must(t, db.CreateVectorCollection("codes", VectorCollectionOptions{Dimensions: 2, Metric: VectorMetricCosine, ElementType: VectorElementTypeI8}))
	i8 := func(values ...int8) VectorValues { return VectorValues{ElementType: VectorElementTypeI8, I8: values} }
	must(t, db.PutVectors("codes", []VectorInput{{ID: "x", Values: i8(1, 0)}, {ID: "y", Values: i8(0, 1)}, {ID: "xy", Values: i8(1, 1)}, {ID: "gone", Values: i8(1, 1)}}))
	must(t, db.DeleteVectors("codes", []string{"gone"}))
	if ok, _ := db.HasVector("codes", "gone"); ok {
		t.Fatal("DeleteVectors left vector")
	}

	options := VectorMultiI8SearchOptions{QueryValues: []int8{1, 0, 0, 1}, QueryCount: 2, Dimensions: 2, Mode: VectorMultiI8SearchGlobalMinCosine, Aggregation: VectorMultiI8AggregationMinCosine, Limit: 3}
	results, err := db.SearchVectorsMultiI8("codes", options)
	must(t, err)
	var ids []string
	for _, result := range results {
		ids = append(ids, result.ID)
	}
	// Min-cosine aggregation scores each vector by its least similar query row.
	if !reflect.DeepEqual(ids, []string{"xy", "x", "y"}) || math.Abs(results[0].Distance-(1-math.Sqrt(0.5))) > 1e-9 {
		t.Fatalf("multi-i8 search = %+v", results)
	}
	prefilter := options
	prefilter.CandidateIDs = []string{"xy", "y"}
	prefilter.Mode = VectorMultiI8SearchCBMPrefilterMinCosine
	prefilter.PrefilterQueryIndex = 1
	prefilter.PrefilterLimit = 1
	results, err = db.SearchVectorsMultiI8("codes", prefilter)
	if err != nil || len(results) != 1 || results[0].ID != "y" {
		t.Fatalf("prefilter search = %+v, %v", results, err)
	}
	bad := options
	bad.QueryCount = 3
	if _, err := db.SearchVectorsMultiI8("codes", bad); !errorStatusIs(err, StatusInvalidArgument) {
		t.Fatalf("bad query count = %v", err)
	}
}
