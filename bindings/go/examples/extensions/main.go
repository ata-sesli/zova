package main

import (
	"fmt"
	"log"
	"os"
	"path/filepath"

	zova "github.com/ata-sesli/zova/bindings/go"
)

func strptr(value string) *string {
	return &value
}

func must(err error) {
	if err != nil {
		log.Fatal(err)
	}
}

func execOne(db *zova.DB, sql string) {
	stmt, err := db.Prepare(sql)
	must(err)
	defer stmt.Close()
	step, err := stmt.Step()
	must(err)
	if step != zova.StepRow {
		log.Fatalf("step = %v, want row", step)
	}
}

func trgmPut(db *zova.DB, index, documentID, targetType string, targetNamespace, targetRef *string, text string) {
	stmt, err := db.Prepare("select zova_trgm_put(?1, ?2, ?3, ?4, ?5, ?6)")
	must(err)
	defer stmt.Close()
	must(stmt.BindText(1, index))
	must(stmt.BindText(2, documentID))
	must(stmt.BindText(3, targetType))
	if targetNamespace == nil {
		must(stmt.BindNull(4))
	} else {
		must(stmt.BindText(4, *targetNamespace))
	}
	if targetRef == nil {
		must(stmt.BindNull(5))
	} else {
		must(stmt.BindText(5, *targetRef))
	}
	must(stmt.BindText(6, text))
	step, err := stmt.Step()
	must(err)
	if step != zova.StepRow {
		log.Fatalf("trgm put step = %v, want row", step)
	}
}

func main() {
	path := filepath.Join(os.TempDir(), fmt.Sprintf("zova-go-extensions-example-%d.zova", os.Getpid()))
	_ = os.Remove(path)
	defer os.Remove(path)

	db, err := zova.Create(path)
	must(err)
	defer db.Close()

	must(db.InstallExtension("trgm"))
	must(db.CheckExtensions())
	execOne(db, "select zova_trgm_create_index('targets')")

	must(db.Exec("create table messages(id text primary key, graph_node_id text not null, body text not null)"))
	must(db.Exec("insert into messages(id, graph_node_id, body) values ('m1', 'message:m1', 'Receipt attachment failed to upload')"))

	objectID, err := db.PutObject([]byte("receipt attachment bytes"))
	must(err)
	objectHex := fmt.Sprintf("%x", objectID[:])
	must(db.CreateVectorCollection("chunks", zova.VectorCollectionOptions{
		Dimensions:  2,
		Metric:      zova.VectorMetricL2,
		ElementType: zova.VectorElementTypeF32,
	}))
	must(db.PutVector("chunks", "chunk:m1", zova.VectorValues{ElementType: zova.VectorElementTypeF32, F32: []float32{0, 1}}))
	must(db.CreateGraph(zova.DefaultGraphName))
	must(db.PutGraphNode(zova.GraphNodeInput{
		GraphName:       zova.DefaultGraphName,
		NodeID:          "message:m1",
		Kind:            "message",
		TargetType:      zova.GraphTargetRecord,
		TargetNamespace: strptr("messages"),
		TargetRef:       strptr("m1"),
	}))
	must(db.PutGraphNode(zova.GraphNodeInput{
		GraphName:  zova.DefaultGraphName,
		NodeID:     "entity:receipt",
		Kind:       "entity",
		TargetType: zova.GraphTargetEntity,
		TargetRef:  strptr("receipt"),
	}))
	must(db.PutGraphEdge(zova.GraphEdgeInput{
		GraphName:  zova.DefaultGraphName,
		FromNodeID: "message:m1",
		EdgeType:   "mentions",
		ToNodeID:   "entity:receipt",
	}))

	listener, err := db.Listen("search:indexed")
	must(err)
	defer listener.Close()
	must(db.BeginImmediate())
	trgmPut(db, "targets", "message:m1", "record", strptr("messages"), strptr("m1"), "Receipt attachment failed to upload")
	trgmPut(db, "targets", "attachment:m1", "object", nil, strptr(objectHex), "receipt.pdf")
	trgmPut(db, "targets", "chunk:m1", "vector", strptr("chunks"), strptr("chunk:m1"), "receipt upload chunk")
	trgmPut(db, "targets", "entity:receipt", "graph", strptr(zova.DefaultGraphName), strptr("entity:receipt"), "receipt")
	must(db.Notify("search:indexed", "targets"))
	if note, err := listener.TryReceive(); err != nil || note != nil {
		log.Fatalf("notification before commit = %#v, %v", note, err)
	}
	must(db.Commit())
	note, err := listener.TryReceive()
	must(err)
	fmt.Println(note.Channel, note.Payload)

	search, err := db.Prepare(`
		select document_id, target_type, target_namespace, target_ref
		from zova_trgm_search
		where index_name = 'targets'
		  and query = ?1
		  and "limit" = 4
		order by rank`)
	must(err)
	defer search.Close()
	must(search.BindText(1, "reciept attachement"))
	for {
		step, err := search.Step()
		must(err)
		if step == zova.StepDone {
			break
		}
		documentID, _, err := search.ColumnText(0)
		must(err)
		targetType, _, err := search.ColumnText(1)
		must(err)
		fmt.Println(documentID, targetType)
	}
}
