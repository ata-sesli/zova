package zova

import (
	"bytes"
	"math"
	"path/filepath"
	"testing"
)

func TestVectorCollectionCRUDAndBatch(t *testing.T) {
	db, err := Create(tempZovaPath(t, "vector-crud"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	must(t, db.Exec("create table chunks(id integer primary key, vector_id text not null)"))
	must(t, db.CreateVectorCollection("chunks", VectorCollectionOptions{Dimensions: 2, Metric: VectorMetricL2}))
	must(t, db.CreateVectorCollection("docs", VectorCollectionOptions{Dimensions: 3, Metric: VectorMetricDot}))

	exists, err := db.HasVectorCollection("chunks")
	if err != nil || !exists {
		t.Fatalf("HasVectorCollection = %v, %v", exists, err)
	}
	info, err := db.VectorCollectionInfo("chunks")
	if err != nil {
		t.Fatal(err)
	}
	if info.Name != "chunks" || info.Dimensions != 2 || info.Metric != VectorMetricL2 || info.VectorCount != 0 {
		t.Fatalf("bad collection info: %#v", info)
	}
	list, err := db.ListVectorCollections()
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 2 || list[0].Name != "chunks" || list[1].Name != "docs" {
		t.Fatalf("collections not sorted: %#v", list)
	}

	must(t, db.PutVectors("chunks", []VectorInput{
		{ID: "a", Values: []float32{99, 99}},
		{ID: "b", Values: []float32{1, 0}},
		{ID: "a", Values: []float32{0, 0}},
		{ID: "c", Values: []float32{2, 0}},
	}))
	must(t, db.PutVectors("chunks", nil))
	vector, err := db.GetVector("chunks", "a")
	if err != nil {
		t.Fatal(err)
	}
	if vector.ID != "a" || !sameFloat32s(vector.Values, []float32{0, 0}) {
		t.Fatalf("last batch entry did not win: %#v", vector)
	}
	must(t, db.PutVector("chunks", "b", []float32{1, 1}))
	vector, err = db.GetVector("chunks", "b")
	if err != nil {
		t.Fatal(err)
	}
	if !sameFloat32s(vector.Values, []float32{1, 1}) {
		t.Fatalf("PutVector upsert = %#v", vector)
	}
	has, err := db.HasVector("chunks", "b")
	if err != nil || !has {
		t.Fatalf("HasVector = %v, %v", has, err)
	}
	must(t, db.Exec("insert into chunks(vector_id) values ('b')"))
	must(t, db.DeleteVector("chunks", "b"))
	has, err = db.HasVector("chunks", "b")
	if err != nil || has {
		t.Fatalf("deleted vector exists = %v, %v", has, err)
	}
	if got := scalarInt(t, db, "select count(*) from chunks where vector_id = 'b'"); got != 1 {
		t.Fatalf("user metadata rows were mutated: %d", got)
	}
	must(t, db.DeleteVectorCollection("chunks"))
	if got := scalarInt(t, db, "select count(*) from chunks where vector_id = 'b'"); got != 1 {
		t.Fatalf("collection delete mutated user rows: %d", got)
	}
	if _, err := db.GetVector("chunks", "a"); !hasStatus(err, StatusVectorCollectionNotFound) {
		t.Fatalf("GetVector after collection delete err=%v", err)
	}
}

func TestVectorSearchVariants(t *testing.T) {
	db, err := Create(tempZovaPath(t, "vector-search"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	must(t, db.CreateVectorCollection("l2", VectorCollectionOptions{Dimensions: 2, Metric: VectorMetricL2}))
	must(t, db.PutVectors("l2", []VectorInput{
		{ID: "a", Values: []float32{0, 0}},
		{ID: "b", Values: []float32{1, 0}},
		{ID: "c", Values: []float32{2, 0}},
		{ID: "d", Values: []float32{0, 2}},
	}))
	results, err := db.SearchVectors("l2", []float32{0, 0}, 3)
	if err != nil {
		t.Fatal(err)
	}
	assertIDs(t, results, []string{"a", "b", "c"})
	assertDistance(t, results[1].Distance, 1)

	results, err = db.SearchVectorsIn("l2", []float32{0, 0}, []string{"missing", "c", "b", "b"}, 10)
	if err != nil {
		t.Fatal(err)
	}
	assertIDs(t, results, []string{"b", "c"})

	results, err = db.SearchVectorsByID("l2", "a", 10)
	if err != nil {
		t.Fatal(err)
	}
	assertIDs(t, results, []string{"b", "c", "d"})

	results, err = db.SearchVectorsByIDIn("l2", "a", []string{"a", "c", "b", "missing", "b"}, 10)
	if err != nil {
		t.Fatal(err)
	}
	assertIDs(t, results, []string{"b", "c"})

	results, err = db.SearchVectorsWithin("l2", []float32{0, 0}, 1, 10)
	if err != nil {
		t.Fatal(err)
	}
	assertIDs(t, results, []string{"a", "b"})

	results, err = db.SearchVectorsInWithin("l2", []float32{0, 0}, []string{"c", "b"}, 1, 10)
	if err != nil {
		t.Fatal(err)
	}
	assertIDs(t, results, []string{"b"})

	results, err = db.SearchVectorsByIDWithin("l2", "a", 1, 10)
	if err != nil {
		t.Fatal(err)
	}
	assertIDs(t, results, []string{"b"})

	results, err = db.SearchVectorsByIDInWithin("l2", "a", []string{"b", "c", "d"}, 2, 10)
	if err != nil {
		t.Fatal(err)
	}
	assertIDs(t, results, []string{"b", "c", "d"})

	if _, err := db.SearchVectors("l2", []float32{0}, 1); !hasStatus(err, StatusVectorDimensionMismatch) {
		t.Fatalf("wrong dimension err=%v", err)
	}
	if _, err := db.SearchVectorsIn("l2", []float32{0, 0}, []string{"bad\x00id"}, 1); err == nil {
		t.Fatal("SearchVectorsIn accepted candidate id with NUL")
	}

	must(t, db.CreateVectorCollection("cosine", VectorCollectionOptions{Dimensions: 2, Metric: VectorMetricCosine}))
	must(t, db.PutVectors("cosine", []VectorInput{
		{ID: "x", Values: []float32{1, 0}},
		{ID: "y", Values: []float32{0, 1}},
	}))
	results, err = db.SearchVectors("cosine", []float32{1, 0}, 2)
	if err != nil {
		t.Fatal(err)
	}
	assertIDs(t, results, []string{"x", "y"})
	assertDistance(t, results[0].Distance, 0)
	assertDistance(t, results[1].Distance, 1)

	must(t, db.CreateVectorCollection("dot", VectorCollectionOptions{Dimensions: 2, Metric: VectorMetricDot}))
	must(t, db.PutVectors("dot", []VectorInput{
		{ID: "low", Values: []float32{1, 0}},
		{ID: "high", Values: []float32{3, 0}},
	}))
	results, err = db.SearchVectorsWithin("dot", []float32{1, 0}, -2, 10)
	if err != nil {
		t.Fatal(err)
	}
	assertIDs(t, results, []string{"high"})
	assertDistance(t, results[0].Distance, -3)
}

func TestVectorsReopenConversionSQLNativeAndMixedWorkflow(t *testing.T) {
	path := tempZovaPath(t, "vector-sql-native")
	db, err := Create(path)
	if err != nil {
		t.Fatal(err)
	}
	must(t, db.Exec("create table chunks(id integer primary key, object_id blob not null, vector_id text not null, body text not null)"))
	objectID, err := db.PutObject([]byte("records + objects + vectors"))
	if err != nil {
		t.Fatal(err)
	}
	must(t, db.CreateVectorCollection("chunks", VectorCollectionOptions{Dimensions: 2, Metric: VectorMetricL2}))
	must(t, db.PutVectors("chunks", []VectorInput{
		{ID: "v1", Values: []float32{0, 0}},
		{ID: "v2", Values: []float32{1, 0}},
		{ID: "v3", Values: []float32{3, 0}},
	}))
	insert, err := db.Prepare("insert into chunks(object_id, vector_id, body) values (?1, ?2, ?3)")
	if err != nil {
		t.Fatal(err)
	}
	for _, row := range []struct {
		vectorID string
		body     string
	}{
		{"v1", "first"},
		{"v2", "second"},
		{"v3", "third"},
	} {
		must(t, insert.Reset())
		must(t, insert.BindBlob(1, objectID[:]))
		must(t, insert.BindText(2, row.vectorID))
		must(t, insert.BindText(3, row.body))
		if step, err := insert.Step(); err != nil || step != StepDone {
			t.Fatalf("insert chunk row = %v, %v", step, err)
		}
	}
	must(t, insert.Close())

	const wantBlobHex = "\x00\x00\x80?\x00\x00\x00@"
	if got := EncodeVectorBlob([]float32{1, 2}); !bytes.Equal(got, []byte(wantBlobHex)) {
		t.Fatalf("EncodeVectorBlob = %v", got)
	}

	assertSQLDistance(t, db, "v2", []float32{0, 0}, 1)
	assertSQLDistanceByID(t, db, "v3", "v2", 2)
	assertSQLSearchOrder(t, db, []float32{0, 0}, []string{"v1", "v2"})

	must(t, db.Close())
	db, err = Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	info, err := db.VectorCollectionInfo("chunks")
	if err != nil {
		t.Fatal(err)
	}
	if info.VectorCount != 3 {
		t.Fatalf("reopened vector count = %d", info.VectorCount)
	}
	gotObject, err := db.GetObject(objectID)
	if err != nil {
		t.Fatal(err)
	}
	if string(gotObject) != "records + objects + vectors" {
		t.Fatalf("object bytes = %q", gotObject)
	}

	dir := t.TempDir()
	source := filepath.Join(dir, "source.db")
	destination := filepath.Join(dir, "converted.zova")
	createPlainSQLite(t, source)
	if err := ConvertSqliteToZova(source, destination); err != nil {
		t.Fatal(err)
	}
	converted, err := Open(destination)
	if err != nil {
		t.Fatal(err)
	}
	defer converted.Close()
	must(t, converted.CreateVectorCollection("converted", VectorCollectionOptions{Dimensions: 2, Metric: VectorMetricL2}))
	must(t, converted.PutVector("converted", "row-1", []float32{4, 5}))
	vector, err := converted.GetVector("converted", "row-1")
	if err != nil {
		t.Fatal(err)
	}
	if vector.ID != "row-1" || !sameFloat32s(vector.Values, []float32{4, 5}) {
		t.Fatalf("converted vector = %#v", vector)
	}
	if got := scalarInt(t, converted, "select count(*) from source_rows"); got != 1 {
		t.Fatalf("converted source row count = %d", got)
	}
}

func assertSQLDistance(t *testing.T, db *DB, vectorID string, query []float32, want float64) {
	t.Helper()
	stmt, err := db.Prepare("select zova_vector_distance('chunks', ?1, ?2)")
	if err != nil {
		t.Fatal(err)
	}
	defer stmt.Close()
	must(t, stmt.BindText(1, vectorID))
	must(t, stmt.BindBlob(2, EncodeVectorBlob(query)))
	if step, err := stmt.Step(); err != nil || step != StepRow {
		t.Fatalf("distance step = %v, %v", step, err)
	}
	got, err := stmt.ColumnFloat64(0)
	if err != nil {
		t.Fatal(err)
	}
	assertDistance(t, got, want)
}

func assertSQLDistanceByID(t *testing.T, db *DB, vectorID, sourceID string, want float64) {
	t.Helper()
	stmt, err := db.Prepare("select zova_vector_distance_by_id('chunks', ?1, ?2)")
	if err != nil {
		t.Fatal(err)
	}
	defer stmt.Close()
	must(t, stmt.BindText(1, vectorID))
	must(t, stmt.BindText(2, sourceID))
	if step, err := stmt.Step(); err != nil || step != StepRow {
		t.Fatalf("distance by id step = %v, %v", step, err)
	}
	got, err := stmt.ColumnFloat64(0)
	if err != nil {
		t.Fatal(err)
	}
	assertDistance(t, got, want)
}

func assertSQLSearchOrder(t *testing.T, db *DB, query []float32, want []string) {
	t.Helper()
	stmt, err := db.Prepare(`
select c.vector_id
from zova_vector_search as s
join chunks as c on c.vector_id = s.vector_id
where s.collection = ?1
  and s.query_vector = ?2
  and s.top_k = ?3
order by s.rank`)
	if err != nil {
		t.Fatal(err)
	}
	defer stmt.Close()
	must(t, stmt.BindText(1, "chunks"))
	must(t, stmt.BindBlob(2, EncodeVectorBlob(query)))
	must(t, stmt.BindInt64(3, int64(len(want))))
	var got []string
	for {
		step, err := stmt.Step()
		if err != nil {
			t.Fatal(err)
		}
		if step == StepDone {
			break
		}
		id, ok, err := stmt.ColumnText(0)
		if err != nil || !ok {
			t.Fatalf("search vector id = %q %v, %v", id, ok, err)
		}
		got = append(got, id)
	}
	assertStringSlice(t, got, want)
}

func assertIDs(t *testing.T, results []VectorSearchResult, want []string) {
	t.Helper()
	got := make([]string, len(results))
	for i, result := range results {
		got[i] = result.ID
	}
	assertStringSlice(t, got, want)
}

func assertStringSlice(t *testing.T, got, want []string) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("ids = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("ids = %v, want %v", got, want)
		}
	}
}

func assertDistance(t *testing.T, got, want float64) {
	t.Helper()
	if math.Abs(got-want) > 1e-6 {
		t.Fatalf("distance = %.12f, want %.12f", got, want)
	}
}

func sameFloat32s(got, want []float32) bool {
	if len(got) != len(want) {
		return false
	}
	for i := range want {
		if got[i] != want[i] {
			return false
		}
	}
	return true
}
