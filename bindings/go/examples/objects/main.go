package main

import (
	"fmt"
	"log"
	"os"
	"path/filepath"

	zova "github.com/atasesli/zova/bindings/go"
)

func main() {
	path := filepath.Join(os.TempDir(), "zova-go-objects.zova")
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

	writer, err := db.ObjectWriter()
	if err != nil {
		log.Fatal(err)
	}
	if err := writer.Write([]byte("hello ")); err != nil {
		log.Fatal(err)
	}
	if err := writer.Write([]byte("from Go objects")); err != nil {
		log.Fatal(err)
	}
	objectID, err := writer.Finish()
	if err != nil {
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

	query, err := db.Prepare("select filename, object_id from attachments where id = ?1")
	if err != nil {
		log.Fatal(err)
	}
	defer query.Close()
	if err := query.BindInt64(1, 1); err != nil {
		log.Fatal(err)
	}
	if step, err := query.Step(); err != nil || step != zova.StepRow {
		log.Fatalf("query step = %v, %v", step, err)
	}
	filename, ok, err := query.ColumnText(0)
	if err != nil {
		log.Fatal(err)
	}
	if !ok {
		log.Fatal("filename is NULL")
	}
	stored, ok, err := query.ColumnBlob(1)
	if err != nil {
		log.Fatal(err)
	}
	if !ok {
		log.Fatal("object id is NULL")
	}
	var storedID zova.ObjectID
	copy(storedID[:], stored)

	preview := make([]byte, 5)
	if _, err := db.ReadObjectRange(storedID, 0, preview); err != nil {
		log.Fatal(err)
	}
	fmt.Printf("%s: %s\n", filename, string(preview))
}
