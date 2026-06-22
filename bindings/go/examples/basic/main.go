package main

import (
	"fmt"
	"log"
	"os"
	"path/filepath"

	zova "github.com/atasesli/zova/bindings/go"
)

func main() {
	path := filepath.Join(os.TempDir(), "zova-go-basic.zova")
	_ = os.Remove(path)
	defer os.Remove(path)

	db, err := zova.Create(path)
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()

	if err := db.Exec("create table notes(id integer primary key, body text not null)"); err != nil {
		log.Fatal(err)
	}

	insert, err := db.Prepare("insert into notes(body) values (?1)")
	if err != nil {
		log.Fatal(err)
	}
	if err := insert.BindText(1, "hello from Go"); err != nil {
		log.Fatal(err)
	}
	if step, err := insert.Step(); err != nil || step != zova.StepDone {
		log.Fatalf("insert step = %v, %v", step, err)
	}
	if err := insert.Close(); err != nil {
		log.Fatal(err)
	}

	query, err := db.Prepare("select body from notes where id = ?1")
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
	body, ok, err := query.ColumnText(0)
	if err != nil {
		log.Fatal(err)
	}
	if !ok {
		log.Fatal("body is NULL")
	}
	fmt.Println(body)
}
