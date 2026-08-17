package zova

import (
	"bytes"
	"testing"
)

func TestKvCRUDPreservesExactBytes(t *testing.T) {
	db, err := Create(tempZovaPath(t, "kv"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	if err := db.KvPut([]byte("settings"), []byte("theme"), []byte("dark")); err != nil {
		t.Fatal(err)
	}
	if err := db.KvPut([]byte("settings"), []byte("retries"), []byte{0, 1, 2}); err != nil {
		t.Fatal(err)
	}
	if err := db.KvPut([]byte("settings"), []byte("empty"), nil); err != nil {
		t.Fatal(err)
	}

	value, err := db.KvGet([]byte("settings"), []byte("theme"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(value, []byte("dark")) {
		t.Fatalf("KvGet theme = %q, want dark", value)
	}
	value, err = db.KvGet([]byte("settings"), []byte("retries"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(value, []byte{0, 1, 2}) {
		t.Fatalf("KvGet retries = %v, want binary value", value)
	}
	value, err = db.KvGet([]byte("settings"), []byte("empty"))
	if err != nil {
		t.Fatal(err)
	}
	if value == nil || len(value) != 0 {
		t.Fatalf("KvGet empty = %v, want empty slice", value)
	}
	value, err = db.KvGet([]byte("settings"), []byte("ghost"))
	if err != nil {
		t.Fatal(err)
	}
	if value != nil {
		t.Fatalf("KvGet ghost = %q, want nil", value)
	}
	value, err = db.KvGet([]byte("other"), []byte("theme"))
	if err != nil {
		t.Fatal(err)
	}
	if value != nil {
		t.Fatalf("KvGet other/theme = %q, want nil", value)
	}

	count, err := db.KvCount([]byte("settings"))
	if err != nil {
		t.Fatal(err)
	}
	if count != 3 {
		t.Fatalf("KvCount = %d, want 3", count)
	}

	if err := db.KvPut([]byte("settings"), []byte("theme"), []byte("light")); err != nil {
		t.Fatal(err)
	}
	value, err = db.KvGet([]byte("settings"), []byte("theme"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(value, []byte("light")) {
		t.Fatalf("KvGet theme after put = %q, want light", value)
	}
	count, err = db.KvCount([]byte("settings"))
	if err != nil {
		t.Fatal(err)
	}
	if count != 3 {
		t.Fatalf("KvCount after replace = %d, want 3", count)
	}

	if err := db.KvDelete([]byte("settings"), []byte("theme")); err != nil {
		t.Fatal(err)
	}
	value, err = db.KvGet([]byte("settings"), []byte("theme"))
	if err != nil {
		t.Fatal(err)
	}
	if value != nil {
		t.Fatalf("KvGet theme after delete = %q, want nil", value)
	}
	count, err = db.KvCount([]byte("settings"))
	if err != nil {
		t.Fatal(err)
	}
	if count != 2 {
		t.Fatalf("KvCount after delete = %d, want 2", count)
	}

	if err := db.KvDelete([]byte("settings"), []byte("ghost")); err != nil {
		t.Fatal(err)
	}
	count, err = db.KvCount([]byte("settings"))
	if err != nil {
		t.Fatal(err)
	}
	if count != 2 {
		t.Fatalf("KvCount after missing delete = %d, want 2", count)
	}

	if err := db.KvClearNamespace([]byte("settings")); err != nil {
		t.Fatal(err)
	}
	count, err = db.KvCount([]byte("settings"))
	if err != nil {
		t.Fatal(err)
	}
	if count != 0 {
		t.Fatalf("KvCount after clear = %d, want 0", count)
	}
}

func TestKvGetManyPreservesOrderAndDuplicates(t *testing.T) {
	db, err := Create(tempZovaPath(t, "kv-many"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	for _, entry := range []struct{ key, value string }{
		{"a", "1"}, {"b", "2"}, {"c", "3"},
	} {
		if err := db.KvPut([]byte("ns"), []byte(entry.key), []byte(entry.value)); err != nil {
			t.Fatal(err)
		}
	}

	results, err := db.KvGetMany([]byte("ns"), [][]byte{[]byte("c"), []byte("ghost"), []byte("a"), []byte("c")})
	if err != nil {
		t.Fatal(err)
	}
	if len(results) != 4 {
		t.Fatalf("KvGetMany len = %d, want 4", len(results))
	}
	assertKvResult(t, results[0], "3")
	if results[1] != nil {
		t.Fatalf("KvGetMany ghost = %v, want nil", *results[1])
	}
	assertKvResult(t, results[2], "1")
	assertKvResult(t, results[3], "3")
}

func TestKvPutManyAndDeleteMany(t *testing.T) {
	db, err := Create(tempZovaPath(t, "kv-batch"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	err = db.KvPutMany([]byte("ns"), []KvEntry{
		{Key: []byte("k1"), Value: []byte("v1")},
		{Key: []byte("k2"), Value: []byte("v2")},
		{Key: []byte("k3"), Value: nil},
	})
	if err != nil {
		t.Fatal(err)
	}
	count, err := db.KvCount([]byte("ns"))
	if err != nil {
		t.Fatal(err)
	}
	if count != 3 {
		t.Fatalf("KvCount after put many = %d, want 3", count)
	}

	if err := db.KvDeleteMany([]byte("ns"), [][]byte{[]byte("k1"), []byte("ghost"), []byte("k3")}); err != nil {
		t.Fatal(err)
	}
	count, err = db.KvCount([]byte("ns"))
	if err != nil {
		t.Fatal(err)
	}
	if count != 1 {
		t.Fatalf("KvCount after delete many = %d, want 1", count)
	}
	value, err := db.KvGet([]byte("ns"), []byte("k2"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(value, []byte("v2")) {
		t.Fatalf("KvGet k2 = %q, want v2", value)
	}

	if err := db.KvPutMany([]byte("ns"), nil); err != nil {
		t.Fatal(err)
	}
	if err := db.KvDeleteMany([]byte("ns"), nil); err != nil {
		t.Fatal(err)
	}
	count, err = db.KvCount([]byte("ns"))
	if err != nil {
		t.Fatal(err)
	}
	if count != 1 {
		t.Fatalf("KvCount after empty batches = %d, want 1", count)
	}
}

func TestKvPartitionsByNamespace(t *testing.T) {
	db, err := Create(tempZovaPath(t, "kv-partition"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	if err := db.KvPut([]byte("a"), []byte("key"), []byte("1")); err != nil {
		t.Fatal(err)
	}
	if err := db.KvPut([]byte("b"), []byte("key"), []byte("2")); err != nil {
		t.Fatal(err)
	}

	value, err := db.KvGet([]byte("a"), []byte("key"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(value, []byte("1")) {
		t.Fatalf("KvGet a/key = %q, want 1", value)
	}
	value, err = db.KvGet([]byte("b"), []byte("key"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(value, []byte("2")) {
		t.Fatalf("KvGet b/key = %q, want 2", value)
	}

	if err := db.KvClearNamespace([]byte("a")); err != nil {
		t.Fatal(err)
	}
	countA, err := db.KvCount([]byte("a"))
	if err != nil {
		t.Fatal(err)
	}
	countB, err := db.KvCount([]byte("b"))
	if err != nil {
		t.Fatal(err)
	}
	if countA != 0 || countB != 1 {
		t.Fatalf("after clear: a=%d b=%d, want 0 and 1", countA, countB)
	}
}

func assertKvResult(t *testing.T, result *[]byte, want string) {
	t.Helper()
	if result == nil {
		t.Fatalf("KvGetMany result is nil, want %q", want)
	}
	if !bytes.Equal(*result, []byte(want)) {
		t.Fatalf("KvGetMany result = %q, want %q", *result, want)
	}
}
