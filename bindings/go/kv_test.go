package zova

import (
	"bytes"
	"reflect"
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

func TestKvScanPagesInKeyByteOrder(t *testing.T) {
	db, err := Create(tempZovaPath(t, "kv-scan"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	for _, key := range []string{"b", "", "a\xff", "a", "ab", "a\x00", "c"} {
		if err := db.KvPut([]byte("ns"), []byte(key), []byte(key)); err != nil {
			t.Fatal(err)
		}
	}
	if err := db.KvPut([]byte("other"), []byte("a"), []byte("elsewhere")); err != nil {
		t.Fatal(err)
	}
	keys := func(page KvScanPage) []string {
		out := make([]string, len(page.Entries))
		for i, entry := range page.Entries {
			out[i] = string(entry.Key)
		}
		return out
	}

	all, err := db.KvScan([]byte("ns"), KvScanOptions{Limit: 100})
	if err != nil {
		t.Fatal(err)
	}
	if got, want := keys(all), []string{"", "a", "a\x00", "ab", "a\xff", "b", "c"}; !reflect.DeepEqual(got, want) || all.HasMore {
		t.Fatalf("all = %q more=%v, want %q", got, all.HasMore, want)
	}
	first, err := db.KvScan([]byte("ns"), KvScanOptions{Prefix: []byte("a"), Limit: 2, KeysOnly: true})
	if err != nil {
		t.Fatal(err)
	}
	if got := keys(first); !reflect.DeepEqual(got, []string{"a", "a\x00"}) || !first.HasMore || len(first.Entries[0].Value) != 0 {
		t.Fatalf("first page = %q more=%v", got, first.HasMore)
	}
	next, err := db.KvScan([]byte("ns"), KvScanOptions{Prefix: []byte("a"), After: first.Entries[1].Key, Limit: 2})
	if err != nil {
		t.Fatal(err)
	}
	if got := keys(next); !reflect.DeepEqual(got, []string{"ab", "a\xff"}) || next.HasMore || string(next.Entries[0].Value) != "ab" {
		t.Fatalf("next page = %q more=%v", got, next.HasMore)
	}
	// An empty non-nil After is the empty key, so the scan skips it.
	afterEmpty, err := db.KvScan([]byte("ns"), KvScanOptions{After: []byte{}, Limit: 1})
	if err != nil {
		t.Fatal(err)
	}
	if got := keys(afterEmpty); !reflect.DeepEqual(got, []string{"a"}) {
		t.Fatalf("after empty key = %q", got)
	}
	bounded, err := db.KvScan([]byte("ns"), KvScanOptions{Start: []byte("a\x00"), End: []byte("b"), Limit: 10})
	if err != nil {
		t.Fatal(err)
	}
	if len(bounded.Entries) != 3 {
		t.Fatalf("bounded = %q", keys(bounded))
	}
	if _, err := db.KvScan([]byte("ns"), KvScanOptions{}); !errorStatusIs(err, StatusInvalidArgument) {
		t.Fatalf("zero limit error = %v", err)
	}
}

func TestKvConditionalWritesReportWhetherTheyApplied(t *testing.T) {
	db, err := Create(tempZovaPath(t, "kv-cas"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	ns, key := []byte("ns"), []byte("k")
	check := func(name string, applied bool, err error, want bool) {
		t.Helper()
		if err != nil || applied != want {
			t.Fatalf("%s = %v, %v; want %v", name, applied, err, want)
		}
	}
	applied, err := db.KvPutIfAbsent(ns, key, []byte("v1"))
	check("first put if absent", applied, err, true)
	applied, err = db.KvPutIfAbsent(ns, key, []byte("other"))
	check("second put if absent", applied, err, false)
	applied, err = db.KvCompareAndPut(ns, key, []byte("stale"), []byte("v2"))
	check("stale compare and put", applied, err, false)
	applied, err = db.KvCompareAndPut(ns, key, []byte("v1"), []byte("v2"))
	check("compare and put", applied, err, true)
	applied, err = db.KvCompareAndDelete(ns, key, []byte("v1"))
	check("stale compare and delete", applied, err, false)
	applied, err = db.KvCompareAndDelete(ns, key, []byte("v2"))
	check("compare and delete", applied, err, true)
	if value, err := db.KvGet(ns, key); err != nil || value != nil {
		t.Fatalf("after delete = %q, %v", value, err)
	}
}
