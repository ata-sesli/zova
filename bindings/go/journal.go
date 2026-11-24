package zova

/*
#include <stdlib.h>
#include "zova.h"
*/
import "C"

import "unsafe"

// JournalMode is the SQLite journal mode of one member file.
//
// SetJournalMode accepts JournalModeDelete, JournalModeTruncate,
// JournalModePersist and JournalModeWAL. JournalModeMemory is reported by
// in-memory databases; JournalModeOff only when a file was switched outside
// Zova.
type JournalMode uint32

const (
	JournalModeDelete   JournalMode = C.ZOVA_JOURNAL_MODE_DELETE
	JournalModeTruncate JournalMode = C.ZOVA_JOURNAL_MODE_TRUNCATE
	JournalModePersist  JournalMode = C.ZOVA_JOURNAL_MODE_PERSIST
	JournalModeMemory   JournalMode = C.ZOVA_JOURNAL_MODE_MEMORY
	JournalModeWAL      JournalMode = C.ZOVA_JOURNAL_MODE_WAL
	JournalModeOff      JournalMode = C.ZOVA_JOURNAL_MODE_OFF
)

// CheckpointMode is the SQLite WAL checkpoint mode for Checkpoint. The zero
// value is CheckpointPassive.
type CheckpointMode uint32

const (
	// CheckpointPassive copies as many frames as possible without waiting.
	CheckpointPassive CheckpointMode = C.ZOVA_CHECKPOINT_PASSIVE
	// CheckpointFull waits for writers, then copies every frame unless a
	// reader still needs one.
	CheckpointFull CheckpointMode = C.ZOVA_CHECKPOINT_FULL
	// CheckpointRestart also waits for readers so the next writer restarts
	// the WAL.
	CheckpointRestart CheckpointMode = C.ZOVA_CHECKPOINT_RESTART
	// CheckpointTruncate also truncates the WAL file to zero bytes.
	CheckpointTruncate CheckpointMode = C.ZOVA_CHECKPOINT_TRUNCATE
)

// JournalModeMember is the journal mode of one member of a database set.
type JournalModeMember struct {
	Member      ProgressMember
	JournalMode JournalMode
}

// CheckpointedMember reports what Checkpoint did for one member file.
type CheckpointedMember struct {
	Member      ProgressMember
	JournalMode JournalMode
	// Busy is true when another handle kept the checkpoint from finishing.
	Busy bool
	// WALFrames is the number of frames in the WAL file after the
	// checkpoint; 0 when the member is not in WAL mode.
	WALFrames uint64
	// CheckpointedFrames is the number of frames now copied into the
	// database file; 0 when the member is not in WAL mode.
	CheckpointedFrames uint64
}

// SetJournalMode switches every member of this database set (the main
// database and each attached bound store) to mode and returns the modes now
// in effect. Either every member ends in mode, or the members already
// switched are restored and the call fails: StatusBusy when another handle
// keeps a member in WAL mode, StatusInvalidArgument for JournalModeMemory,
// JournalModeOff or an in-memory database. It fails with
// StatusObjectTransactionActive inside a transaction and StatusReadOnly on a
// read-only handle. Only WAL is stored in the file; to create a WAL
// database, call this right after Create.
func (db *DB) SetJournalMode(mode JournalMode) ([]JournalModeMember, error) {
	report := (*C.zova_journal_mode_report)(C.calloc(1, C.size_t(unsafe.Sizeof(C.zova_journal_mode_report{}))))
	defer C.free(unsafe.Pointer(report))
	err := db.withLock(func() error {
		request := C.zova_database_set_journal_mode_request{
			db:           db.ptr,
			journal_mode: C.uint32_t(mode),
			out_report:   report,
		}
		return statusFromDB(db, C.zova_database_set_journal_mode(&request))
	})
	if err != nil {
		return nil, err
	}
	return journalModeMembers(report), nil
}

// JournalModes reports the journal mode of each member: the main database,
// then each attached object, vector and graph store.
func (db *DB) JournalModes() ([]JournalModeMember, error) {
	report := (*C.zova_journal_mode_report)(C.calloc(1, C.size_t(unsafe.Sizeof(C.zova_journal_mode_report{}))))
	defer C.free(unsafe.Pointer(report))
	err := db.withLock(func() error {
		request := C.zova_database_journal_modes_request{db: db.ptr, out_report: report}
		return statusFromDB(db, C.zova_database_journal_modes(&request))
	})
	if err != nil {
		return nil, err
	}
	return journalModeMembers(report), nil
}

// Checkpoint runs a WAL checkpoint on every member, in JournalModes order.
// Members not in WAL mode report zero frames. It fails with
// StatusObjectTransactionActive inside a transaction.
func (db *DB) Checkpoint(mode CheckpointMode) ([]CheckpointedMember, error) {
	// The result lives in C memory: cgo rejects a request holding a Go pointer.
	result := (*C.zova_checkpoint_result)(C.calloc(1, C.size_t(unsafe.Sizeof(C.zova_checkpoint_result{}))))
	defer C.free(unsafe.Pointer(result))
	err := db.withLock(func() error {
		request := C.zova_database_checkpoint_request{
			db:         db.ptr,
			mode:       C.uint32_t(mode),
			out_result: result,
		}
		return statusFromDB(db, C.zova_database_checkpoint(&request))
	})
	if err != nil {
		return nil, err
	}
	count := int(result.member_count)
	if count > len(result.members) {
		count = len(result.members)
	}
	members := make([]CheckpointedMember, count)
	for i := range members {
		entry := result.members[i]
		members[i] = CheckpointedMember{
			Member:             ProgressMember(entry.member),
			JournalMode:        JournalMode(entry.journal_mode),
			Busy:               entry.busy != 0,
			WALFrames:          uint64(entry.wal_frames),
			CheckpointedFrames: uint64(entry.checkpointed_frames),
		}
	}
	return members, nil
}

func journalModeMembers(report *C.zova_journal_mode_report) []JournalModeMember {
	count := int(report.member_count)
	if count > len(report.members) {
		count = len(report.members)
	}
	members := make([]JournalModeMember, count)
	for i := range members {
		entry := report.members[i]
		members[i] = JournalModeMember{
			Member:      ProgressMember(entry.member),
			JournalMode: JournalMode(entry.journal_mode),
		}
	}
	return members
}
