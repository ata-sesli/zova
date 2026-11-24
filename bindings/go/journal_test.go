package zova

import "testing"

func TestSetJournalModeSwitchesAndReportsTheSet(t *testing.T) {
	path := tempZovaPath(t, "journal")
	db, err := Create(path)
	must(t, err)

	modes, err := db.JournalModes()
	must(t, err)
	if len(modes) != 1 || modes[0].Member != ProgressMemberMain || modes[0].JournalMode != JournalModeDelete {
		t.Fatalf("initial modes: got %+v", modes)
	}
	modes, err = db.SetJournalMode(JournalModeWAL)
	must(t, err)
	if modes[0].JournalMode != JournalModeWAL {
		t.Fatalf("switch to WAL: got %+v", modes)
	}
	if _, err := db.SetJournalMode(JournalModeOff); !errorStatusIs(err, StatusInvalidArgument) {
		t.Fatalf("journal mode off: got %v", err)
	}
	must(t, db.Begin())
	if _, err := db.SetJournalMode(JournalModeDelete); !errorStatusIs(err, StatusObjectTransactionActive) {
		t.Fatalf("switch in transaction: got %v", err)
	}
	if _, err := db.Checkpoint(CheckpointPassive); !errorStatusIs(err, StatusObjectTransactionActive) {
		t.Fatalf("checkpoint in transaction: got %v", err)
	}
	must(t, db.Rollback())

	must(t, db.Exec("create table rows(x); insert into rows values(1)"))
	members, err := db.Checkpoint(CheckpointPassive)
	must(t, err)
	if len(members) != 1 || members[0].JournalMode != JournalModeWAL || members[0].Busy ||
		members[0].WALFrames == 0 || members[0].WALFrames != members[0].CheckpointedFrames {
		t.Fatalf("passive checkpoint: got %+v", members)
	}
	members, err = db.Checkpoint(CheckpointTruncate)
	must(t, err)
	if members[0].WALFrames != 0 {
		t.Fatalf("truncate checkpoint: got %+v", members)
	}
	must(t, db.Close())

	// WAL is stored in the file.
	reopened, err := Open(path)
	must(t, err)
	defer reopened.Close()
	modes, err = reopened.JournalModes()
	must(t, err)
	if modes[0].JournalMode != JournalModeWAL {
		t.Fatalf("reopened modes: got %+v", modes)
	}
	modes, err = reopened.SetJournalMode(JournalModeDelete)
	must(t, err)
	if modes[0].JournalMode != JournalModeDelete {
		t.Fatalf("switch back: got %+v", modes)
	}
}

func TestInMemoryDatabaseKeepsMemoryJournalMode(t *testing.T) {
	db, err := CreateMemory()
	must(t, err)
	defer db.Close()
	modes, err := db.JournalModes()
	must(t, err)
	if len(modes) != 1 || modes[0].JournalMode != JournalModeMemory {
		t.Fatalf("memory modes: got %+v", modes)
	}
	if _, err := db.SetJournalMode(JournalModeWAL); !errorStatusIs(err, StatusInvalidArgument) {
		t.Fatalf("memory to WAL: got %v", err)
	}
}
