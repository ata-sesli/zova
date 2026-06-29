package main

import (
	"fmt"
	"log"
	"os"
	"path/filepath"

	zova "github.com/atasesli/zova/bindings/go"
)

func main() {
	path := filepath.Join(os.TempDir(), "zova-go-notifications.zova")
	_ = os.Remove(path)
	defer os.Remove(path)

	db, err := zova.Create(path)
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()

	if err := db.Exec("create table attachments(id integer primary key, filename text not null, object_id blob not null)"); err != nil {
		log.Fatal(err)
	}

	listener, err := db.Listen("message:1:attachments")
	if err != nil {
		log.Fatal(err)
	}
	defer listener.Close()

	objectID, err := db.PutObject([]byte("hello from a Go notification"))
	if err != nil {
		log.Fatal(err)
	}

	if err := db.BeginImmediate(); err != nil {
		log.Fatal(err)
	}
	insert, err := db.Prepare("insert into attachments(filename, object_id) values (?1, ?2)")
	if err != nil {
		log.Fatal(err)
	}
	if err := insert.BindText(1, "hello.txt"); err != nil {
		log.Fatal(err)
	}
	if err := insert.BindBlob(2, objectID[:]); err != nil {
		log.Fatal(err)
	}
	if step, err := insert.Step(); err != nil || step != zova.StepDone {
		log.Fatalf("insert step = %v, %v", step, err)
	}
	if err := insert.Close(); err != nil {
		log.Fatal(err)
	}
	if err := db.Notify("message:1:attachments", "changed"); err != nil {
		log.Fatal(err)
	}
	if note, err := listener.TryReceive(); err != nil || note != nil {
		log.Fatalf("notification before commit = %#v, %v", note, err)
	}
	if err := db.Commit(); err != nil {
		log.Fatal(err)
	}

	note, err := listener.TryReceive()
	if err != nil {
		log.Fatal(err)
	}
	fmt.Printf("%s %s\n", note.Channel, note.Payload)

	if err := db.Exec("create table chunks(id text primary key, vector_id text not null)"); err != nil {
		log.Fatal(err)
	}
	if err := db.CreateVectorCollection("chunks", zova.VectorCollectionOptions{
		Dimensions: 2,
		Metric:     zova.VectorMetricL2,
	}); err != nil {
		log.Fatal(err)
	}
	if err := db.PutVector("chunks", "chunk:1", []float32{0, 0}); err != nil {
		log.Fatal(err)
	}
	vectorListener, err := db.Listen("vectors:chunks")
	if err != nil {
		log.Fatal(err)
	}
	defer vectorListener.Close()
	if err := db.BeginImmediate(); err != nil {
		log.Fatal(err)
	}
	if err := db.Exec("insert into chunks(id, vector_id) values ('c1', 'chunk:1')"); err != nil {
		log.Fatal(err)
	}
	if err := db.Notify("vectors:chunks", "changed"); err != nil {
		log.Fatal(err)
	}
	if err := db.Commit(); err != nil {
		log.Fatal(err)
	}
	vectorNote, err := vectorListener.TryReceive()
	if err != nil {
		log.Fatal(err)
	}
	results, err := db.SearchVectors("chunks", []float32{0, 0}, 1)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Printf("%s %s\n", vectorNote.Channel, results[0].ID)
}
