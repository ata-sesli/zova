package zova

import (
	"errors"
	"fmt"
	"strings"
	"testing"
)

func stringPtr(value string) *string {
	return &value
}

func hex32(bytes [32]byte) string {
	return fmt.Sprintf("%x", bytes[:])
}

func graphNodeInput(nodeID string, targetType GraphTargetType, namespace, ref *string) GraphNodeInput {
	return GraphNodeInput{
		GraphName:       DefaultGraphName,
		NodeID:          nodeID,
		Kind:            "message",
		TargetType:      targetType,
		TargetNamespace: namespace,
		TargetRef:       ref,
	}
}

func graphEdgeInput(fromNodeID, edgeType, toNodeID string) GraphEdgeInput {
	return GraphEdgeInput{
		GraphName:  DefaultGraphName,
		FromNodeID: fromNodeID,
		EdgeType:   edgeType,
		ToNodeID:   toNodeID,
	}
}

func TestGraphLifecycleNodeEdgeTraversalAndTargets(t *testing.T) {
	path := tempZovaPath(t, "graphs")
	db, err := Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	must(t, db.Exec("create table messages(id text primary key, body text not null)"))
	must(t, db.Exec("insert into messages(id, body) values ('m1', 'hello')"))
	if has, err := db.HasGraph("app"); err != nil || has {
		t.Fatalf("HasGraph before create = %v, %v", has, err)
	}
	must(t, db.CreateGraph(DefaultGraphName))
	must(t, db.CreateGraph("knowledge"))
	if err := db.CreateGraph(DefaultGraphName); !errorStatusIs(err, StatusGraphExists) {
		t.Fatalf("duplicate CreateGraph error = %v, want StatusGraphExists", err)
	}

	graphs, err := db.ListGraphs()
	if err != nil {
		t.Fatal(err)
	}
	if len(graphs) != 2 || graphs[0].Name != "default" || graphs[1].Name != "knowledge" {
		t.Fatalf("ListGraphs = %#v", graphs)
	}

	objectID, err := db.PutObject([]byte("graph target object"))
	if err != nil {
		t.Fatal(err)
	}
	manifest, err := db.ObjectManifest(objectID)
	if err != nil {
		t.Fatal(err)
	}
	must(t, db.CreateVectorCollection("chunks", VectorCollectionOptions{Dimensions: 2, Metric: VectorMetricL2}))
	must(t, db.PutVector("chunks", "chunk-vector", []float32{1, 0}))

	targets := []GraphNodeInput{
		graphNodeInput("record:m1", GraphTargetRecord, stringPtr("messages"), stringPtr("m1")),
		graphNodeInput("object:1", GraphTargetObject, stringPtr("sha256"), stringPtr(hex32(objectID))),
		graphNodeInput("chunk:1", GraphTargetObjectChunk, stringPtr("sha256"), stringPtr(hex32(manifest.Chunks[0].Hash))),
		graphNodeInput("vector:1", GraphTargetVector, stringPtr("chunks"), stringPtr("chunk-vector")),
		graphNodeInput("entity:1", GraphTargetEntity, nil, stringPtr("person:ata")),
		graphNodeInput("fact:1", GraphTargetFact, nil, stringPtr("fact:alpha")),
		graphNodeInput("concept:1", GraphTargetConcept, nil, stringPtr("storage")),
		graphNodeInput("external:1", GraphTargetExternal, nil, stringPtr("https://example.test")),
		graphNodeInput("none:1", GraphTargetNone, nil, nil),
		graphNodeInput("empty-target", GraphTargetExternal, stringPtr(""), stringPtr("")),
	}
	for _, input := range targets {
		must(t, db.PutGraphNode(input))
		stored, err := db.GetGraphNode(DefaultGraphName, input.NodeID)
		if err != nil {
			t.Fatal(err)
		}
		if stored.TargetType != input.TargetType {
			t.Fatalf("target type for %s = %v, want %v", input.NodeID, stored.TargetType, input.TargetType)
		}
		if (stored.TargetNamespace == nil) != (input.TargetNamespace == nil) {
			t.Fatalf("target namespace nil mismatch for %s", input.NodeID)
		}
		if stored.TargetNamespace != nil && *stored.TargetNamespace != *input.TargetNamespace {
			t.Fatalf("target namespace for %s = %q, want %q", input.NodeID, *stored.TargetNamespace, *input.TargetNamespace)
		}
		if (stored.TargetRef == nil) != (input.TargetRef == nil) {
			t.Fatalf("target ref nil mismatch for %s", input.NodeID)
		}
		if stored.TargetRef != nil && *stored.TargetRef != *input.TargetRef {
			t.Fatalf("target ref for %s = %q, want %q", input.NodeID, *stored.TargetRef, *input.TargetRef)
		}
	}

	must(t, db.PutGraphEdge(graphEdgeInput("record:m1", "mentions", "entity:1")))
	must(t, db.PutGraphEdge(graphEdgeInput("record:m1", "has_attachment", "object:1")))
	must(t, db.PutGraphEdge(graphEdgeInput("record:m1", "has_attachment", "object:1")))
	if err := db.PutGraphEdge(graphEdgeInput("record:m1", "missing", "missing-node")); !errorStatusIs(err, StatusGraphNodeNotFound) {
		t.Fatalf("missing endpoint error = %v, want StatusGraphNodeNotFound", err)
	}

	edge, err := db.GetGraphEdge(DefaultGraphName, "record:m1", "has_attachment", "object:1")
	if err != nil {
		t.Fatal(err)
	}
	if edge.EdgeType != "has_attachment" || edge.ToNodeID != "object:1" {
		t.Fatalf("GetGraphEdge = %#v", edge)
	}
	if has, err := db.HasGraphEdge(DefaultGraphName, "record:m1", "has_attachment", "object:1"); err != nil || !has {
		t.Fatalf("HasGraphEdge = %v, %v", has, err)
	}

	outgoing, err := db.GraphNeighbors(GraphNeighborsOptions{
		GraphName: DefaultGraphName,
		NodeID:    "record:m1",
		Direction: GraphNeighborOutgoing,
		Limit:     10,
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(outgoing) != 2 || outgoing[0].NodeID != "entity:1" || outgoing[1].NodeID != "object:1" {
		t.Fatalf("outgoing neighbors = %#v", outgoing)
	}
	incoming, err := db.GraphNeighbors(GraphNeighborsOptions{
		GraphName: DefaultGraphName,
		NodeID:    "object:1",
		Direction: GraphNeighborIncoming,
		EdgeType:  stringPtr("has_attachment"),
		Limit:     10,
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(incoming) != 1 || incoming[0].NodeID != "record:m1" {
		t.Fatalf("incoming neighbors = %#v", incoming)
	}
	limited, err := db.GraphNeighbors(GraphNeighborsOptions{
		GraphName: DefaultGraphName,
		NodeID:    "record:m1",
		Direction: GraphNeighborOutgoing,
		Limit:     0,
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(limited) != 0 {
		t.Fatalf("limit zero neighbors = %#v", limited)
	}

	walk, err := db.GraphWalk(GraphWalkOptions{
		GraphName:   DefaultGraphName,
		StartNodeID: "record:m1",
		MaxDepth:    2,
		Limit:       10,
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(walk) < 3 || walk[0].NodeID != "record:m1" || walk[1].Depth != 1 || walk[1].PredecessorNodeID == nil || *walk[1].PredecessorNodeID != "record:m1" {
		t.Fatalf("GraphWalk = %#v", walk)
	}

	must(t, db.DeleteGraphEdge(graphEdgeInput("record:m1", "has_attachment", "object:1")))
	if _, err := db.GetGraphEdge(DefaultGraphName, "record:m1", "has_attachment", "object:1"); !errorStatusIs(err, StatusGraphEdgeNotFound) {
		t.Fatalf("deleted edge error = %v, want StatusGraphEdgeNotFound", err)
	}
	must(t, db.DeleteGraphNode(DefaultGraphName, "entity:1"))
	if _, err := db.GetGraphEdge(DefaultGraphName, "record:m1", "mentions", "entity:1"); !errorStatusIs(err, StatusGraphEdgeNotFound) {
		t.Fatalf("incident edge error = %v, want StatusGraphEdgeNotFound", err)
	}
	must(t, db.DeleteGraph("knowledge"))
	if has, err := db.HasGraph("knowledge"); err != nil || has {
		t.Fatalf("HasGraph after delete = %v, %v", has, err)
	}
}

func TestSQLNativeGraphHelpersJoinAppRows(t *testing.T) {
	path := tempZovaPath(t, "graph-sql")
	db, err := Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	must(t, db.Exec(`
create table messages(graph_node_id text primary key, body text);
insert into messages(graph_node_id, body) values
  ('message:1', 'root'),
  ('message:2', 'reply'),
  ('message:3', 'mentioned')`))
	must(t, db.CreateGraph(DefaultGraphName))
	for _, nodeID := range []string{"message:1", "message:2", "message:3"} {
		input := graphNodeInput(nodeID, GraphTargetRecord, stringPtr("messages"), stringPtr(nodeID))
		must(t, db.PutGraphNode(input))
	}
	must(t, db.PutGraphEdge(graphEdgeInput("message:1", "replies_to", "message:2")))
	must(t, db.PutGraphEdge(graphEdgeInput("message:2", "mentions", "message:3")))

	neighbors, err := db.Prepare(`
select m.body, g.edge_type
from zova_graph_neighbors as g
join messages as m on m.graph_node_id = g.node_id
where g.graph_name = 'default'
  and g.source_node_id = 'message:1'
  and g."limit" = 10
order by g.rank`)
	if err != nil {
		t.Fatal(err)
	}
	defer neighbors.Close()
	step, err := neighbors.Step()
	if err != nil || step != StepRow {
		t.Fatalf("neighbors step = %v, %v", step, err)
	}
	body, ok, err := neighbors.ColumnText(0)
	if err != nil || !ok || body != "reply" {
		t.Fatalf("neighbor body = %q, %v, %v", body, ok, err)
	}
	edgeType, ok, err := neighbors.ColumnText(1)
	if err != nil || !ok || edgeType != "replies_to" {
		t.Fatalf("neighbor edge type = %q, %v, %v", edgeType, ok, err)
	}

	walk, err := db.Prepare(`
select node_id, depth, predecessor_node_id, edge_type
from zova_graph_walk
where graph_name = 'default'
  and start_node_id = 'message:1'
  and max_depth = 2
  and "limit" = 10
order by rank`)
	if err != nil {
		t.Fatal(err)
	}
	defer walk.Close()
	step, err = walk.Step()
	if err != nil || step != StepRow {
		t.Fatalf("walk step 1 = %v, %v", step, err)
	}
	nodeID, ok, err := walk.ColumnText(0)
	if err != nil || !ok || nodeID != "message:1" {
		t.Fatalf("walk node 1 = %q, %v, %v", nodeID, ok, err)
	}
	depth, err := walk.ColumnInt64(1)
	if err != nil || depth != 0 {
		t.Fatalf("walk depth 1 = %d, %v", depth, err)
	}
	step, err = walk.Step()
	if err != nil || step != StepRow {
		t.Fatalf("walk step 2 = %v, %v", step, err)
	}
	nodeID, ok, err = walk.ColumnText(0)
	if err != nil || !ok || nodeID != "message:2" {
		t.Fatalf("walk node 2 = %q, %v, %v", nodeID, ok, err)
	}
	predecessor, ok, err := walk.ColumnText(2)
	if err != nil || !ok || predecessor != "message:1" {
		t.Fatalf("walk predecessor 2 = %q, %v, %v", predecessor, ok, err)
	}
	edgeType, ok, err = walk.ColumnText(3)
	if err != nil || !ok || edgeType != "replies_to" {
		t.Fatalf("walk edge type 2 = %q, %v, %v", edgeType, ok, err)
	}
}

func TestGraphTransactionsReadOnlyValidationAndVectorMetadata(t *testing.T) {
	path := tempZovaPath(t, "graph-transactions")
	db, err := Create(path)
	if err != nil {
		t.Fatal(err)
	}
	must(t, db.CreateGraph(DefaultGraphName))
	must(t, db.BeginImmediate())
	must(t, db.PutGraphNode(graphNodeInput("rolled-back", GraphTargetNone, nil, nil)))
	must(t, db.Rollback())
	if has, err := db.HasGraphNode(DefaultGraphName, "rolled-back"); err != nil || has {
		t.Fatalf("rolled-back node = %v, %v", has, err)
	}

	must(t, db.BeginImmediate())
	must(t, db.Savepoint("sp_graph"))
	must(t, db.PutGraphNode(graphNodeInput("savepoint-rolled-back", GraphTargetNone, nil, nil)))
	must(t, db.RollbackToSavepoint("sp_graph"))
	must(t, db.ReleaseSavepoint("sp_graph"))
	must(t, db.Commit())
	if has, err := db.HasGraphNode(DefaultGraphName, "savepoint-rolled-back"); err != nil || has {
		t.Fatalf("savepoint node = %v, %v", has, err)
	}

	must(t, db.CreateVectorCollection("chunks", VectorCollectionOptions{Dimensions: 2, Metric: VectorMetricL2}))
	must(t, db.PutVector("chunks", "v1", []float32{1, 0}))
	must(t, db.PutGraphNode(graphNodeInput("vector:v1", GraphTargetVector, stringPtr("chunks"), stringPtr("v1"))))
	must(t, db.DeleteVector("chunks", "v1"))
	node, err := db.GetGraphNode(DefaultGraphName, "vector:v1")
	if err != nil {
		t.Fatal(err)
	}
	if node.TargetRef == nil || *node.TargetRef != "v1" {
		t.Fatalf("graph metadata after vector delete = %#v", node)
	}

	if err := db.CreateGraph("_zova_private"); !errorStatusIs(err, StatusGraphInvalid) {
		t.Fatalf("invalid graph name error = %v, want StatusGraphInvalid", err)
	}
	if err := db.PutGraphNode(graphNodeInput("bad\x00node", GraphTargetNone, nil, nil)); !errorStatusIs(err, StatusInvalidArgument) {
		t.Fatalf("NUL node id error = %v, want StatusInvalidArgument", err)
	}
	if err := db.PutGraphEdge(graphEdgeInput("vector:v1", "missing", "missing-node")); !errorStatusIs(err, StatusGraphNodeNotFound) {
		t.Fatalf("missing edge endpoint error = %v, want StatusGraphNodeNotFound", err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	readonly, err := OpenWithOptions(path, OpenOptions{ReadOnly: true})
	if err != nil {
		t.Fatal(err)
	}
	defer readonly.Close()
	if has, err := readonly.HasGraphNode(DefaultGraphName, "vector:v1"); err != nil || !has {
		t.Fatalf("readonly graph read = %v, %v", has, err)
	}
	err = readonly.PutGraphNode(graphNodeInput("readonly-write", GraphTargetNone, nil, nil))
	if !errorStatusIs(err, StatusReadOnly) {
		t.Fatalf("readonly graph write error = %v, want StatusReadOnly", err)
	}

	err = readonly.Close()
	if err != nil {
		t.Fatal(err)
	}
	_, err = readonly.ListGraphs()
	if !errorStatusIs(err, StatusMisuse) {
		t.Fatalf("ListGraphs after close error = %v, want StatusMisuse", err)
	}

	var zerr *Error
	if !errors.As(err, &zerr) || !strings.Contains(zerr.Name, "MISUSE") {
		t.Fatalf("closed graph error = %#v", err)
	}
}
