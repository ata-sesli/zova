package main

import (
	"fmt"
	"log"
	"os"
	"path/filepath"

	zova "github.com/atasesli/zova/bindings/go"
)

func main() {
	path := filepath.Join(os.TempDir(), "zova-go-vectors.zova")
	_ = os.Remove(path)
	defer os.Remove(path)

	db, err := zova.Create(path)
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()

	if err := db.Exec("create table chunks(id integer primary key, vector_id text not null, text text not null, source text not null)"); err != nil {
		log.Fatal(err)
	}
	if err := db.CreateVectorCollection("chunks", zova.VectorCollectionOptions{
		Dimensions: 2,
		Metric:     zova.VectorMetricL2,
	}); err != nil {
		log.Fatal(err)
	}
	if err := db.PutVectors("chunks", []zova.VectorInput{
		{ID: "intro", Values: []float32{0, 0}},
		{ID: "api", Values: []float32{1, 0}},
		{ID: "release", Values: []float32{3, 0}},
	}); err != nil {
		log.Fatal(err)
	}

	insert, err := db.Prepare("insert into chunks(vector_id, text, source) values (?1, ?2, ?3)")
	if err != nil {
		log.Fatal(err)
	}
	for _, row := range []struct {
		vectorID string
		text     string
		source   string
	}{
		{"intro", "Zova stores records, objects, and vectors together.", "docs"},
		{"api", "The Go binding wraps the C ABI.", "docs"},
		{"release", "Release packages stay source-only.", "notes"},
	} {
		if err := insert.Reset(); err != nil {
			log.Fatal(err)
		}
		if err := insert.BindText(1, row.vectorID); err != nil {
			log.Fatal(err)
		}
		if err := insert.BindText(2, row.text); err != nil {
			log.Fatal(err)
		}
		if err := insert.BindText(3, row.source); err != nil {
			log.Fatal(err)
		}
		if step, err := insert.Step(); err != nil || step != zova.StepDone {
			log.Fatalf("insert step = %v, %v", step, err)
		}
	}
	if err := insert.Close(); err != nil {
		log.Fatal(err)
	}

	results, err := db.SearchVectors("chunks", []float32{0.2, 0}, 2)
	if err != nil {
		log.Fatal(err)
	}
	for _, result := range results {
		text := lookupText(db, result.ID)
		fmt.Printf("%s %.3f %s\n", result.ID, result.Distance, text)
	}

	distance := scalarDistance(db, "api", []float32{0, 0})
	fmt.Printf("api distance: %.3f\n", distance)

	sqlSearch(db, []float32{0, 0})
}

func lookupText(db *zova.DB, vectorID string) string {
	query, err := db.Prepare("select text from chunks where vector_id = ?1")
	if err != nil {
		log.Fatal(err)
	}
	defer query.Close()
	if err := query.BindText(1, vectorID); err != nil {
		log.Fatal(err)
	}
	if step, err := query.Step(); err != nil || step != zova.StepRow {
		log.Fatalf("lookup step = %v, %v", step, err)
	}
	text, ok, err := query.ColumnText(0)
	if err != nil {
		log.Fatal(err)
	}
	if !ok {
		log.Fatal("text is NULL")
	}
	return text
}

func scalarDistance(db *zova.DB, vectorID string, queryVector []float32) float64 {
	stmt, err := db.Prepare("select zova_vector_distance('chunks', ?1, ?2)")
	if err != nil {
		log.Fatal(err)
	}
	defer stmt.Close()
	if err := stmt.BindText(1, vectorID); err != nil {
		log.Fatal(err)
	}
	if err := stmt.BindBlob(2, zova.EncodeVectorBlob(queryVector)); err != nil {
		log.Fatal(err)
	}
	if step, err := stmt.Step(); err != nil || step != zova.StepRow {
		log.Fatalf("distance step = %v, %v", step, err)
	}
	value, err := stmt.ColumnFloat64(0)
	if err != nil {
		log.Fatal(err)
	}
	return value
}

func sqlSearch(db *zova.DB, queryVector []float32) {
	stmt, err := db.Prepare(`
select c.vector_id, c.source, s.distance
from zova_vector_search as s
join chunks as c on c.vector_id = s.vector_id
where s.collection = ?1
  and s.query_vector = ?2
  and s.top_k = ?3
order by s.rank`)
	if err != nil {
		log.Fatal(err)
	}
	defer stmt.Close()
	if err := stmt.BindText(1, "chunks"); err != nil {
		log.Fatal(err)
	}
	if err := stmt.BindBlob(2, zova.EncodeVectorBlob(queryVector)); err != nil {
		log.Fatal(err)
	}
	if err := stmt.BindInt64(3, 2); err != nil {
		log.Fatal(err)
	}
	for {
		step, err := stmt.Step()
		if err != nil {
			log.Fatal(err)
		}
		if step == zova.StepDone {
			return
		}
		id, _, err := stmt.ColumnText(0)
		if err != nil {
			log.Fatal(err)
		}
		source, _, err := stmt.ColumnText(1)
		if err != nil {
			log.Fatal(err)
		}
		distance, err := stmt.ColumnFloat64(2)
		if err != nil {
			log.Fatal(err)
		}
		fmt.Printf("sql %s %s %.3f\n", id, source, distance)
	}
}
