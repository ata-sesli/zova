package zova

import (
	"math"
	"os"
	"testing"
)

func TestNetworKitPageRankSQL(t *testing.T) {
	if os.Getenv("ZOVA_PAGERANK_BUNDLE") == "" {
		t.Skip("requires NetworKit reference fixture")
	}
	db, err := OpenWithExtensions(os.Getenv("ZOVA_PAGERANK_DATABASE"), OpenOptions{ReadOnly: true},
		ExtensionOptions{BundlePaths: []string{os.Getenv("ZOVA_PAGERANK_BUNDLE")}, TrustStorePath: os.Getenv("ZOVA_PAGERANK_TRUST")})
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	stmt, err := db.Prepare("SELECT node_key,node_id,score FROM zova_networkit_pagerank('cycle',0.85,1e-10,200,10,10)")
	if err != nil {
		t.Fatal(err)
	}
	defer stmt.Close()
	count, sum := 0, 0.0
	for {
		step, err := stmt.Step()
		if err != nil {
			t.Fatal(err)
		}
		if step == StepDone {
			break
		}
		key, err := stmt.ColumnInt64(0)
		if err != nil || key <= 0 {
			t.Fatal(key, err)
		}
		score, err := stmt.ColumnFloat64(2)
		if err != nil {
			t.Fatal(err)
		}
		sum += score
		count++
	}
	if count != 4 || math.Abs(sum-1) > 1e-10 {
		t.Fatal(count, sum)
	}
}
