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

func must(err error) {
	if err != nil {
		panic(err)
	}
}

func main() {
	path := filepath.Join(os.TempDir(), fmt.Sprintf("zova-go-graphs-example-%d.zova", os.Getpid()))
	_ = os.Remove(path)
	defer os.Remove(path)

	db, err := zova.Create(path)
	must(err)
	defer db.Close()

	must(db.Exec("create table messages(id text primary key, body text not null)"))
	must(db.Exec("insert into messages(id, body) values ('m1', 'hello'), ('m2', 'reply')"))
	must(db.CreateGraph(zova.DefaultGraphName))

	for _, id := range []string{"m1", "m2"} {
		must(db.PutGraphNode(zova.GraphNodeInput{
			GraphName:       zova.DefaultGraphName,
			NodeID:          id,
			Kind:            "message",
			TargetType:      zova.GraphTargetRecord,
			TargetNamespace: strptr("messages"),
			TargetRef:       strptr(id),
		}))
	}
	must(db.PutGraphEdge(zova.GraphEdgeInput{
		GraphName:  zova.DefaultGraphName,
		FromNodeID: "m2",
		EdgeType:   "replies_to",
		ToNodeID:   "m1",
	}))

	neighbors, err := db.GraphNeighbors(zova.GraphNeighborsOptions{
		GraphName: zova.DefaultGraphName,
		NodeID:    "m2",
		Direction: zova.GraphNeighborOutgoing,
		EdgeType:  strptr("replies_to"),
		Limit:     10,
	})
	must(err)

	for _, neighbor := range neighbors {
		stmt, err := db.Prepare("select body from messages where id = ?1")
		must(err)
		must(stmt.BindText(1, neighbor.NodeID))
		step, err := stmt.Step()
		must(err)
		if step == zova.StepRow {
			body, _, err := stmt.ColumnText(0)
			must(err)
			fmt.Printf("%s -> %s\n", neighbor.EdgeType, body)
		}
		must(stmt.Close())
	}
}
