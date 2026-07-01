package main

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/atasesli/zova/bindings/go"
)

func strptr(value string) *string {
	return &value
}

func hex32(bytes [32]byte) string {
	return fmt.Sprintf("%x", bytes[:])
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}

func main() {
	path := filepath.Join(os.TempDir(), fmt.Sprintf("zova-go-graph-rag-example-%d.zova", os.Getpid()))
	_ = os.Remove(path)
	defer os.Remove(path)

	db, err := zova.Create(path)
	must(err)
	defer db.Close()

	must(db.Exec("create table chunks(id text primary key, body text not null)"))
	must(db.Exec("insert into chunks(id, body) values ('chunk:1', 'Zova stores records, objects, vectors, and graphs together')"))
	must(db.CreateGraph(zova.DefaultGraphName))
	must(db.CreateVectorCollection("chunks", zova.VectorCollectionOptions{
		Dimensions: 2,
		Metric:     zova.VectorMetricL2,
	}))
	must(db.PutVector("chunks", "chunk:1", []float32{0, 1}))

	objectID, err := db.PutObject([]byte("attachment bytes"))
	must(err)
	objectHex := hex32(objectID)

	must(db.PutGraphNode(zova.GraphNodeInput{
		GraphName:       zova.DefaultGraphName,
		NodeID:          "chunk:1",
		Kind:            "chunk",
		TargetType:      zova.GraphTargetVector,
		TargetNamespace: strptr("chunks"),
		TargetRef:       strptr("chunk:1"),
	}))
	must(db.PutGraphNode(zova.GraphNodeInput{
		GraphName:       zova.DefaultGraphName,
		NodeID:          "attachment:1",
		Kind:            "attachment",
		TargetType:      zova.GraphTargetObject,
		TargetNamespace: strptr("sha256"),
		TargetRef:       strptr(objectHex),
	}))
	must(db.PutGraphNode(zova.GraphNodeInput{
		GraphName:  zova.DefaultGraphName,
		NodeID:     "entity:zova",
		Kind:       "entity",
		TargetType: zova.GraphTargetEntity,
		TargetRef:  strptr("zova"),
	}))
	must(db.PutGraphEdge(zova.GraphEdgeInput{
		GraphName:  zova.DefaultGraphName,
		FromNodeID: "chunk:1",
		EdgeType:   "mentions",
		ToNodeID:   "entity:zova",
	}))
	must(db.PutGraphEdge(zova.GraphEdgeInput{
		GraphName:  zova.DefaultGraphName,
		FromNodeID: "chunk:1",
		EdgeType:   "has_attachment",
		ToNodeID:   "attachment:1",
	}))

	hits, err := db.SearchVectors("chunks", []float32{0, 1}, 1)
	must(err)
	for _, hit := range hits {
		neighbors, err := db.GraphNeighbors(zova.GraphNeighborsOptions{
			GraphName: zova.DefaultGraphName,
			NodeID:    hit.ID,
			Direction: zova.GraphNeighborOutgoing,
			Limit:     10,
		})
		must(err)
		for _, neighbor := range neighbors {
			if neighbor.NodeID == "attachment:1" {
				bytes, err := db.GetObject(objectID)
				must(err)
				fmt.Printf("attachment bytes: %d\n", len(bytes))
				continue
			}
			stmt, err := db.Prepare("select body from chunks where id = ?1")
			must(err)
			must(stmt.BindText(1, hit.ID))
			step, err := stmt.Step()
			must(err)
			if step == zova.StepRow {
				body, _, err := stmt.ColumnText(0)
				must(err)
				fmt.Printf("%s: %s\n", neighbor.NodeID, body)
			}
			must(stmt.Close())
		}
	}
}
