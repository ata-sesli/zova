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

func TestSetCommitProtocolSwitchesAWALSetOrReportsAnUnsupportedLibrary(t *testing.T) {
	for status, name := range map[Status]string{
		StatusCommitSetBroken:      "ZOVA_COMMIT_SET_BROKEN",
		StatusCommitSetNeedsRepair: "ZOVA_COMMIT_SET_NEEDS_REPAIR",
		StatusMemberOwned:          "ZOVA_MEMBER_OWNED",
	} {
		if got := StatusName(status); got != name {
			t.Fatalf("status %d name: got %q, want %q", status, got, name)
		}
	}

	path := tempZovaPath(t, "commit-protocol")
	db, err := Create(path)
	must(t, err)
	defer db.Close()
	if err := db.SetCommitProtocol(CommitProtocol(2)); !errorStatusIs(err, StatusInvalidArgument) {
		t.Fatalf("unknown protocol: got %v", err)
	}

	err = db.SetCommitProtocol(CommitProtocolCWAL)
	if errorStatusIs(err, StatusUnsupportedZovaVersion) {
		// A library built without -Dexperimental-cwal refuses either protocol.
		if err := db.SetCommitProtocol(CommitProtocolNone); !errorStatusIs(err, StatusUnsupportedZovaVersion) {
			t.Fatalf("none on an unsupported library: got %v", err)
		}
		return
	}
	if !errorStatusIs(err, StatusMisuse) {
		t.Fatalf("CWAL outside WAL mode: got %v", err)
	}

	_, err = db.SetJournalMode(JournalModeWAL)
	must(t, err)
	must(t, db.Exec("create table rows(x)"))
	must(t, db.Begin())
	if err := db.SetCommitProtocol(CommitProtocolCWAL); !errorStatusIs(err, StatusObjectTransactionActive) {
		t.Fatalf("switch in transaction: got %v", err)
	}
	must(t, db.Rollback())
	must(t, db.SetCommitProtocol(CommitProtocolCWAL))
	must(t, db.SetCommitProtocol(CommitProtocolCWAL))

	if second, err := Open(path); !errorStatusIs(err, StatusBusy) {
		if second != nil {
			second.Close()
		}
		t.Fatalf("second writer: got %v", err)
	}
	reader, err := OpenWithOptions(path, OpenOptions{ReadOnly: true})
	must(t, err)
	if err := reader.SetCommitProtocol(CommitProtocolNone); !errorStatusIs(err, StatusReadOnly) {
		t.Fatalf("switch on a reader: got %v", err)
	}
	must(t, reader.Close())

	must(t, db.Exec("insert into rows values(1)"))
	must(t, db.SetCommitProtocol(CommitProtocolNone))
	must(t, db.Exec("insert into rows values(2)"))
}
