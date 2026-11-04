package zova

import (
	"encoding/binary"
	"errors"
	"os"
	"testing"
)

// progressDB creates a database whose verify pass covers far more items than
// the 101 whole-percent steps Zova forwards.
func progressDB(t *testing.T) *DB {
	t.Helper()
	db, err := Create(tempZovaPath(t, "progress-source"))
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	entries := make([]KvEntry, 1000)
	for i := range entries {
		key := make([]byte, 8)
		binary.BigEndian.PutUint64(key, uint64(i))
		entries[i] = KvEntry{Key: key, Value: []byte("progress")}
	}
	if err := db.KvPutMany([]byte("progress"), entries); err != nil {
		t.Fatalf("kv put many: %v", err)
	}
	return db
}

// checkWellFormed: each phase/member group keeps its total, never decreases,
// and ends at total.
func checkWellFormed(t *testing.T, events []Progress) {
	t.Helper()
	if len(events) == 0 {
		t.Fatal("no progress events")
	}
	for i, event := range events {
		if event.Done > event.Total {
			t.Fatalf("event %d: done > total: %+v", i, event)
		}
		if i+1 < len(events) && events[i+1].Phase == event.Phase && events[i+1].Member == event.Member {
			if events[i+1].Total != event.Total || events[i+1].Done < event.Done {
				t.Fatalf("event %d: group not monotonic: %+v then %+v", i, event, events[i+1])
			}
		} else if event.Done != event.Total {
			t.Fatalf("event %d: group ends incomplete: %+v", i, event)
		}
	}
}

func TestBackupAndCompactReportProgressAndCancel(t *testing.T) {
	db := progressDB(t)
	backup := tempZovaPath(t, "progress-backup")
	compact := tempZovaPath(t, "progress-compact")

	stop := errors.New("stop")
	calls := 0
	err := db.BackupToWithProgress(backup, BackupOptions{}, func(Progress) error {
		calls++
		return stop
	})
	if !errorStatusIs(err, StatusInterrupted) || !errors.Is(err, stop) {
		t.Fatalf("cancelled backup: got %v", err)
	}
	if calls != 1 {
		t.Fatalf("cancelled backup: callback ran %d times", calls)
	}
	if _, statErr := os.Stat(backup); !os.IsNotExist(statErr) {
		t.Fatalf("cancelled backup left a destination: %v", statErr)
	}

	var events []Progress
	if err := db.BackupToWithProgress(backup, BackupOptions{}, func(event Progress) error {
		events = append(events, event)
		return nil
	}); err != nil {
		t.Fatalf("backup: %v", err)
	}
	checkWellFormed(t, events)
	if events[0].Phase != ProgressCopy || events[0].Member != ProgressMemberMain {
		t.Fatalf("first event: %+v", events[0])
	}
	verify := 0
	for _, event := range events {
		if event.Phase == ProgressVerify {
			verify++
			if event.Member != ProgressMemberNone || event.Total < 1000 {
				t.Fatalf("verify event: %+v", event)
			}
		}
	}
	if verify < 2 || verify > 102 {
		t.Fatalf("verify events not throttled: %d", verify)
	}

	err = db.CompactToWithProgress(compact, CompactOptions{}, func(event Progress) error {
		if event.Phase == ProgressVerify && event.Done > 0 {
			return stop
		}
		return nil
	})
	if !errorStatusIs(err, StatusInterrupted) {
		t.Fatalf("cancelled compact: got %v", err)
	}
	if _, statErr := os.Stat(compact); !os.IsNotExist(statErr) {
		t.Fatalf("cancelled compact left a destination: %v", statErr)
	}
	if err := db.CompactToWithProgress(compact, CompactOptions{}, nil); err != nil {
		t.Fatalf("compact without callback: %v", err)
	}
	if err := db.Exec("select 1"); err != nil {
		t.Fatalf("database unusable after cancel: %v", err)
	}
}

func TestProgressCallbackPanicCancelsAndPropagates(t *testing.T) {
	db := progressDB(t)
	backup := tempZovaPath(t, "progress-panic")
	func() {
		defer func() {
			if value := recover(); value != "progress panic" {
				t.Fatalf("recovered %v", value)
			}
		}()
		_ = db.BackupToWithProgress(backup, BackupOptions{}, func(Progress) error { panic("progress panic") })
		t.Fatal("panic did not propagate")
	}()
	if _, statErr := os.Stat(backup); !os.IsNotExist(statErr) {
		t.Fatalf("panicking backup left a destination: %v", statErr)
	}
	if err := db.Exec("select 1"); err != nil {
		t.Fatalf("database unusable after panic: %v", err)
	}
}

func TestMigrateReportsProgressAndCancelLeavesSourceUnchanged(t *testing.T) {
	source := copyMigrationFixture(t, "format-9.zova")
	before := readAllBytes(t, source)
	destination := tempZovaPath(t, "progress-migrated")

	err := MigrateDatabaseWithProgress(source, destination, MigrateOptions{}, ExtensionOptions{}, func(event Progress) error {
		if event.Phase == ProgressMigrate {
			return errors.New("stop")
		}
		return nil
	})
	if !errorStatusIs(err, StatusInterrupted) {
		t.Fatalf("cancelled migrate: got %v", err)
	}
	if _, statErr := os.Stat(destination); !os.IsNotExist(statErr) {
		t.Fatalf("cancelled migrate left a destination: %v", statErr)
	}
	if !sameBytes(before, readAllBytes(t, source)) {
		t.Fatal("cancelled migrate changed the source")
	}

	var events []Progress
	if err := MigrateDatabaseWithProgress(source, destination, MigrateOptions{}, ExtensionOptions{}, func(event Progress) error {
		events = append(events, event)
		return nil
	}); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	checkWellFormed(t, events)
	seen := map[ProgressPhase]bool{}
	for _, event := range events {
		seen[event.Phase] = true
	}
	for _, phase := range []ProgressPhase{ProgressCopy, ProgressMigrate, ProgressVerify, ProgressPublish} {
		if !seen[phase] {
			t.Fatalf("missing phase %d in %+v", phase, events)
		}
	}
	last := events[len(events)-1]
	if last.Phase != ProgressPublish || last.Member != ProgressMemberNone {
		t.Fatalf("last event: %+v", last)
	}
}
