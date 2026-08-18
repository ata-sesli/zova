package zova

import (
	"fmt"
	"sort"
	"testing"
	"time"
)

const (
	benchEvents   = 256
	benchKVBatch  = 4096
	benchWarmups  = 20
	benchSamples  = 100
)

func benchMedian(values []float64) float64 {
	sorted := make([]float64, len(values))
	copy(sorted, values)
	sort.Float64s(sorted)
	return sorted[len(sorted)/2]
}

func benchMAD(values []float64, med float64) float64 {
	deviations := make([]float64, len(values))
	for i, v := range values {
		d := v - med
		if d < 0 {
			d = -d
		}
		deviations[i] = d
	}
	return benchMedian(deviations)
}

func benchP95(values []float64) float64 {
	sorted := make([]float64, len(values))
	copy(sorted, values)
	sort.Float64s(sorted)
	return sorted[int(float64(len(sorted))*0.95)]
}

func benchReport(label string, values []float64) {
	med := benchMedian(values)
	fmt.Printf("%s median_ms=%.6f mad_ms=%.6f p95_ms=%.6f\n", label, med, benchMAD(values, med), benchP95(values))
}

func BenchmarkNotifications(b *testing.B) {
	db, err := CreateMemory()
	if err != nil {
		b.Fatal(err)
	}
	defer db.Close()

	payloads := make([]string, benchEvents)
	for i := range payloads {
		payloads[i] = fmt.Sprintf("event-%d", i)
	}
	samples := make([]float64, 0, benchSamples)

	b.Run("commit_no_notify", func(b *testing.B) {
		samples = samples[:0]
		for i := 0; i < benchWarmups+benchSamples; i++ {
			start := time.Now()
			if err := db.BeginImmediate(); err != nil {
				b.Fatal(err)
			}
			if err := db.Commit(); err != nil {
				b.Fatal(err)
			}
			if i >= benchWarmups {
				samples = append(samples, float64(time.Since(start).Microseconds())/1000.0)
			}
		}
		benchReport("commit_no_notify", samples)
	})

	oneSub, err := db.Listen("bench:one")
	if err != nil {
		b.Fatal(err)
	}
	defer oneSub.Close()
	b.Run("commit_one_notify", func(b *testing.B) {
		samples = samples[:0]
		for i := 0; i < benchWarmups+benchSamples; i++ {
			start := time.Now()
			if err := db.BeginImmediate(); err != nil {
				b.Fatal(err)
			}
			if err := db.Notify("bench:one", payloads[0]); err != nil {
				b.Fatal(err)
			}
			if err := db.Commit(); err != nil {
				b.Fatal(err)
			}
			note, err := oneSub.TryReceive()
			if err != nil {
				b.Fatal(err)
			}
			if note == nil {
				b.Fatal("expected notification")
			}
			if i >= benchWarmups {
				samples = append(samples, float64(time.Since(start).Microseconds())/1000.0)
			}
		}
		benchReport("commit_one_notify", samples)
	})

	var multiSubs [4]*Subscription
	for i := range multiSubs {
		multiSubs[i], err = db.Listen("bench:multi")
		if err != nil {
			b.Fatal(err)
		}
		defer multiSubs[i].Close()
	}
	b.Run("commit_256_four_listeners", func(b *testing.B) {
		samples = samples[:0]
		for i := 0; i < benchWarmups+benchSamples; i++ {
			start := time.Now()
			if err := db.BeginImmediate(); err != nil {
				b.Fatal(err)
			}
			for _, payload := range payloads {
				if err := db.Notify("bench:multi", payload); err != nil {
					b.Fatal(err)
				}
			}
			if err := db.Commit(); err != nil {
				b.Fatal(err)
			}
			for _, sub := range multiSubs {
				for j := 0; j < benchEvents; j++ {
					note, err := sub.TryReceive()
					if err != nil {
						b.Fatal(err)
					}
					if note == nil {
						b.Fatal("expected notification")
					}
				}
			}
			if i >= benchWarmups {
				samples = append(samples, float64(time.Since(start).Microseconds())/1000.0)
			}
		}
		benchReport("commit_256_four_listeners", samples)
	})

	entries := make([]KvEntry, benchKVBatch)
	for i := range entries {
		entries[i] = KvEntry{Key: []byte(fmt.Sprintf("k-%d", i)), Value: []byte("v")}
	}
	ns := []byte("bench:kv")
	b.Run("kv_batch_4096_commit_no_notify", func(b *testing.B) {
		samples = samples[:0]
		for i := 0; i < benchWarmups+benchSamples; i++ {
			start := time.Now()
			if err := db.BeginImmediate(); err != nil {
				b.Fatal(err)
			}
			if err := db.KvPutMany(ns, entries); err != nil {
				b.Fatal(err)
			}
			if err := db.Commit(); err != nil {
				b.Fatal(err)
			}
			if i >= benchWarmups {
				samples = append(samples, float64(time.Since(start).Microseconds())/1000.0)
			}
		}
		benchReport("kv_batch_4096_commit_no_notify", samples)
	})

	aggSub, err := db.Listen("cache:search-results")
	if err != nil {
		b.Fatal(err)
	}
	defer aggSub.Close()
	b.Run("kv_batch_4096_commit_one_notify", func(b *testing.B) {
		samples = samples[:0]
		for i := 0; i < benchWarmups+benchSamples; i++ {
			start := time.Now()
			if err := db.BeginImmediate(); err != nil {
				b.Fatal(err)
			}
			if err := db.KvPutMany(ns, entries); err != nil {
				b.Fatal(err)
			}
			if err := db.Notify("cache:search-results", "generation:42"); err != nil {
				b.Fatal(err)
			}
			if err := db.Commit(); err != nil {
				b.Fatal(err)
			}
			note, err := aggSub.TryReceive()
			if err != nil {
				b.Fatal(err)
			}
			if note == nil {
				b.Fatal("expected notification")
			}
			if i >= benchWarmups {
				samples = append(samples, float64(time.Since(start).Microseconds())/1000.0)
			}
		}
		benchReport("kv_batch_4096_commit_one_notify", samples)
	})

	receiveSub, err := db.Listen("bench:receive")
	if err != nil {
		b.Fatal(err)
	}
	defer receiveSub.Close()
	b.Run("receive_256_prefilled", func(b *testing.B) {
		samples = samples[:0]
		for i := 0; i < benchWarmups+benchSamples; i++ {
			for _, payload := range payloads {
				if err := db.Notify("bench:receive", payload); err != nil {
					b.Fatal(err)
				}
			}
			start := time.Now()
			for j := 0; j < benchEvents; j++ {
				note, err := receiveSub.TryReceive()
				if err != nil {
					b.Fatal(err)
				}
				if note == nil {
					b.Fatal("expected notification")
				}
			}
			if i >= benchWarmups {
				samples = append(samples, float64(time.Since(start).Microseconds())/1000.0)
			}
		}
		benchReport("receive_256_prefilled", samples)
	})
}