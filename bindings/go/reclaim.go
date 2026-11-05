package zova

/*
#include <stdlib.h>
#include "zova.h"
*/
import "C"

import "unsafe"

// ReclaimOptions controls ReclaimSpace.
//
// The zero value releases every free page in steps of 1024 pages.
type ReclaimOptions struct {
	// MaxPages bounds the pages released by the call across every member;
	// 0 releases every free page.
	MaxPages uint64
	// StepPages is the number of pages released per write transaction, so
	// other writers can run in between; 0 selects 1024.
	StepPages uint32
}

// AutoVacuum is the SQLite auto_vacuum mode of one member file.
type AutoVacuum uint32

const (
	AutoVacuumNone        AutoVacuum = C.ZOVA_AUTO_VACUUM_NONE
	AutoVacuumFull        AutoVacuum = C.ZOVA_AUTO_VACUUM_FULL
	AutoVacuumIncremental AutoVacuum = C.ZOVA_AUTO_VACUUM_INCREMENTAL
)

// ReclaimedMember reports what ReclaimSpace did for one member file.
type ReclaimedMember struct {
	Member     ProgressMember
	AutoVacuum AutoVacuum
	PageSize   uint32
	// PagesReleased is the number of free pages released back to the
	// filesystem by this call.
	PagesReleased uint64
	// FreePagesLeft is the number of free pages still inside the file. When
	// AutoVacuum is AutoVacuumNone, only CompactTo drops them.
	FreePagesLeft uint64
}

// ReclaimSpace releases free pages of incremental auto-vacuum member files in
// place, each step in its own short write transaction. Members are reported in
// a fixed order: the main database, then each attached object, vector, and
// graph store. It fails with StatusObjectTransactionActive inside an explicit
// transaction; open object readers are allowed.
func (db *DB) ReclaimSpace(options ...ReclaimOptions) ([]ReclaimedMember, error) {
	if len(options) > 1 {
		return nil, newError(StatusInvalidArgument, "ReclaimSpace accepts at most one options value")
	}
	var option ReclaimOptions
	if len(options) == 1 {
		option = options[0]
	}

	// The result lives in C memory: cgo rejects a request holding a Go pointer.
	result := (*C.zova_reclaim_result)(C.calloc(1, C.size_t(unsafe.Sizeof(C.zova_reclaim_result{}))))
	defer C.free(unsafe.Pointer(result))
	err := db.withLock(func() error {
		request := C.zova_database_reclaim_request{
			db:         db.ptr,
			max_pages:  C.uint64_t(option.MaxPages),
			step_pages: C.uint32_t(option.StepPages),
			out_result: result,
		}
		return statusFromDB(db, C.zova_database_reclaim(&request))
	})
	if err != nil {
		return nil, err
	}
	count := int(result.member_count)
	if count > len(result.members) {
		count = len(result.members)
	}
	members := make([]ReclaimedMember, count)
	for i := range members {
		entry := result.members[i]
		members[i] = ReclaimedMember{
			Member:        ProgressMember(entry.member),
			AutoVacuum:    AutoVacuum(entry.auto_vacuum),
			PageSize:      uint32(entry.page_size),
			PagesReleased: uint64(entry.pages_released),
			FreePagesLeft: uint64(entry.free_pages_left),
		}
	}
	return members, nil
}
