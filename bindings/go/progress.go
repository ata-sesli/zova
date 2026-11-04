package zova

/*
#include <stdint.h>
#include <stdlib.h>
#include "zova.h"

extern int32_t zovaGoProgress(void *user_data, zova_progress *progress);

static zova_progress_fn zova_go_progress_fn(void) {
	return (zova_progress_fn)zovaGoProgress;
}
*/
import "C"

import (
	"runtime/cgo"
	"unsafe"
)

// ProgressPhase is the stage of a backup, compact, or migration. It fixes
// the unit of Progress.Done and Progress.Total.
type ProgressPhase uint32

const (
	// ProgressCopy copies one member file. Units: SQLite pages of the source member.
	ProgressCopy ProgressPhase = C.ZOVA_PROGRESS_COPY
	// ProgressMigrate migrates one staged member. Units: format steps.
	ProgressMigrate ProgressPhase = C.ZOVA_PROGRESS_MIGRATE
	// ProgressVerify checks the copied set. Units: stored objects, chunks,
	// vectors, and KV entries.
	ProgressVerify ProgressPhase = C.ZOVA_PROGRESS_VERIFY
	// ProgressPublish publishes migrated member files. Units: files.
	ProgressPublish ProgressPhase = C.ZOVA_PROGRESS_PUBLISH
)

// ProgressMember is the member file a copy or migrate event refers to.
type ProgressMember uint32

const (
	// ProgressMemberNone marks whole-set phases: verify and publish.
	ProgressMemberNone        ProgressMember = C.ZOVA_PROGRESS_MEMBER_NONE
	ProgressMemberMain        ProgressMember = C.ZOVA_PROGRESS_MEMBER_MAIN
	ProgressMemberObjectStore ProgressMember = C.ZOVA_PROGRESS_MEMBER_OBJECT_STORE
	ProgressMemberVectorStore ProgressMember = C.ZOVA_PROGRESS_MEMBER_VECTOR_STORE
	ProgressMemberGraphStore  ProgressMember = C.ZOVA_PROGRESS_MEMBER_GRAPH_STORE
)

// Progress is one progress event. Events for one phase and member keep Total
// fixed, never decrease Done, and end with Done == Total. Zova forwards the
// first event of each phase and member, whole-percent changes, and the event
// that completes the group.
type Progress struct {
	Phase  ProgressPhase
	Member ProgressMember
	Done   uint64
	Total  uint64
}

// ProgressFunc receives progress events on the calling goroutine. Returning
// a non-nil error cancels the operation, which then fails with
// StatusInterrupted; errors.Is and errors.As also match the returned error.
// The function must not use the database the operation runs on.
type ProgressFunc func(Progress) error

// progressState is the Go side of one synchronous progress-reporting call.
type progressState struct {
	fn       ProgressFunc
	err      error
	panicked bool
	panicVal any
}

// progressBridge keeps a cgo.Handle in C memory so the C callback's
// user_data never points into Go memory.
type progressBridge struct {
	state    *progressState
	handle   cgo.Handle
	userData unsafe.Pointer
}

func newProgressBridge(fn ProgressFunc) *progressBridge {
	if fn == nil {
		return &progressBridge{}
	}
	state := &progressState{fn: fn}
	bridge := &progressBridge{state: state, handle: cgo.NewHandle(state)}
	bridge.userData = C.malloc(C.size_t(unsafe.Sizeof(C.uintptr_t(0))))
	*(*C.uintptr_t)(bridge.userData) = C.uintptr_t(bridge.handle)
	return bridge
}

func (b *progressBridge) callback() C.zova_progress_fn {
	if b.state == nil {
		return nil
	}
	return C.zova_go_progress_fn()
}

// finish releases the handle, re-raises a panic from the callback, and joins
// the callback's cancelling error to the Zova error.
func (b *progressBridge) finish(err error) error {
	if b.state == nil {
		return err
	}
	C.free(b.userData)
	b.handle.Delete()
	if b.state.panicked {
		panic(b.state.panicVal)
	}
	if err != nil && b.state.err != nil && errorStatusIs(err, StatusInterrupted) {
		return &progressCancelError{zova: err, cause: b.state.err}
	}
	return err
}

type progressCancelError struct {
	zova  error
	cause error
}

func (e *progressCancelError) Error() string {
	return e.zova.Error() + ": " + e.cause.Error()
}

func (e *progressCancelError) Unwrap() []error {
	return []error{e.zova, e.cause}
}

// BackupToWithProgress is BackupTo that reports progress to fn. A nil fn
// behaves like BackupTo. A cancelled backup leaves no destination.
func (db *DB) BackupToWithProgress(destination string, options BackupOptions, fn ProgressFunc) error {
	cDestination, err := cString("destination path", destination)
	if err != nil {
		return err
	}
	defer freeCString(cDestination)

	return db.withLock(func() error {
		bridge := newProgressBridge(fn)
		request := C.zova_database_backup_progress_request{
			db:                 db.ptr,
			destination_path:   cDestination,
			flags:              backupFlags(options),
			progress:           bridge.callback(),
			progress_user_data: bridge.userData,
		}
		return bridge.finish(statusFromDB(db, C.zova_database_backup_with_progress(&request)))
	})
}

// CompactToWithProgress is CompactTo that reports progress to fn. A nil fn
// behaves like CompactTo. A cancelled compaction leaves no destination.
func (db *DB) CompactToWithProgress(destination string, options CompactOptions, fn ProgressFunc) error {
	cDestination, err := cString("destination path", destination)
	if err != nil {
		return err
	}
	defer freeCString(cDestination)

	return db.withLock(func() error {
		bridge := newProgressBridge(fn)
		request := C.zova_database_compact_progress_request{
			db:                 db.ptr,
			destination_path:   cDestination,
			flags:              compactFlags(options),
			progress:           bridge.callback(),
			progress_user_data: bridge.userData,
		}
		return bridge.finish(statusFromDB(db, C.zova_database_compact_with_progress(&request)))
	})
}

// MigrateDatabaseWithProgress is MigrateDatabaseWithExtensions that reports
// progress to fn. A cancelled migration leaves the source set unchanged and
// creates no destination files. The last ProgressPublish event follows the
// commit, so its return value is ignored.
func MigrateDatabaseWithProgress(source, destination string, options MigrateOptions, extensions ExtensionOptions, fn ProgressFunc) error {
	cSource, err := cString("source path", source)
	if err != nil {
		return err
	}
	defer freeCString(cSource)
	cDestination, err := cString("destination path", destination)
	if err != nil {
		return err
	}
	defer freeCString(cDestination)
	args, err := newExtensionCArgs(extensions)
	if err != nil {
		return err
	}
	defer args.free()
	message := newCMessage()
	defer freeCMessage(message)
	bridge := newProgressBridge(fn)
	request := C.zova_database_migrate_progress_request{
		source_path:            cSource,
		destination_path:       cDestination,
		flags:                  migrateFlags(options),
		extension_bundle_paths: args.paths,
		extension_bundle_count: args.count,
		trust_store_path:       args.trust,
		progress:               bridge.callback(),
		progress_user_data:     bridge.userData,
		out_error_message:      message,
	}
	status := C.zova_database_migrate_with_progress(&request)
	return bridge.finish(statusWithMessage(status, takeMessage(message)))
}
