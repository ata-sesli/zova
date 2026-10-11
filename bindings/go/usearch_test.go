package zova

import (
	"os"
	"testing"
)

func TestUSearchSQL(t *testing.T) {
	if os.Getenv("ZOVA_USEARCH_BUNDLE") == "" {
		t.Skip("requires USearch reference fixture")
	}
	db, err := OpenWithExtensions(os.Getenv("ZOVA_USEARCH_DATABASE"), OpenOptions{ReadOnly: true},
		ExtensionOptions{BundlePaths: []string{os.Getenv("ZOVA_USEARCH_BUNDLE")}, TrustStorePath: os.Getenv("ZOVA_USEARCH_TRUST")})
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	stmt, err := db.Prepare("SELECT vector_id,distance FROM zova_usearch_search('points',x'0000000000000000',2,64)")
	if err != nil {
		t.Fatal(err)
	}
	defer stmt.Close()
	count := 0
	for {
		step, err := stmt.Step()
		if err != nil {
			t.Fatal(err)
		}
		if step == StepDone {
			break
		}
		id, found, err := stmt.ColumnText(0)
		if err != nil || !found {
			t.Fatal(err)
		}
		want := "one"
		if count == 1 {
			want = "two"
		}
		if id != want {
			t.Fatal(id, want)
		}
		distance, err := stmt.ColumnFloat64(1)
		if err != nil || distance != float64(count+1) {
			t.Fatal(distance, err)
		}
		count++
	}
	if count != 2 {
		t.Fatal(count)
	}
}
