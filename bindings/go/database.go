package zova

/*
#include <stdlib.h>
#include "zova.h"
*/
import "C"

import (
	"sync"
	"unsafe"
)

// DB owns one Zova database handle.
//
// DB serializes calls with an internal mutex. Open multiple DB handles to the
// same file for parallel work and let SQLite locking decide concurrency.
type DB struct {
	mu         sync.Mutex
	ptr        *C.zova_database
	closed     bool
	statements map[*Stmt]struct{}
	writers    map[*ObjectWriter]struct{}
}

// OpenOptions controls optional behavior for opening an existing .zova file.
type OpenOptions struct {
	ReadOnly      bool
	BusyTimeoutMS uint32
}

// BackupOptions controls backup behavior.
//
// The zero value verifies the copied destination after backup. Set NoVerify to
// skip that validation.
type BackupOptions struct {
	NoVerify bool
}

// CompactOptions controls compact-copy behavior.
//
// The zero value verifies the compact destination after copying. Set NoVerify
// to skip that validation.
type CompactOptions struct {
	NoVerify bool
}

// RestoreOptions controls restore behavior.
//
// The zero value verifies the restored destination after copying. Set NoVerify
// to skip that validation.
type RestoreOptions struct {
	NoVerify bool
}

// Create creates a new .zova database.
func Create(path string) (*DB, error) {
	return openOrCreate(path, true)
}

// Open opens an existing .zova database.
func Open(path string) (*DB, error) {
	return openOrCreate(path, false)
}

// OpenWithOptions opens an existing .zova database with explicit options.
func OpenWithOptions(path string, options OpenOptions) (*DB, error) {
	return openWithOptions(path, options)
}

// ConvertSqliteToZova converts an existing SQLite database into a new .zova file.
func ConvertSqliteToZova(source, destination string) error {
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

	message := newCMessage()
	defer freeCMessage(message)
	request := C.zova_convert_sqlite_to_zova_request{
		source_path:       cSource,
		dest_path:         cDestination,
		out_error_message: message,
	}
	status := C.zova_convert_sqlite_to_zova(&request)
	return statusWithMessage(status, takeMessage(message))
}

// RestoreBackup copies a backup .zova file into a new destination .zova file.
func RestoreBackup(source, destination string, options ...RestoreOptions) error {
	option, err := singleRestoreOptions(options)
	if err != nil {
		return err
	}
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

	message := newCMessage()
	defer freeCMessage(message)
	request := C.zova_database_restore_request{
		source_path:       cSource,
		destination_path:  cDestination,
		flags:             restoreFlags(option),
		out_error_message: message,
	}
	status := C.zova_database_restore(&request)
	return statusWithMessage(status, takeMessage(message))
}

func openOrCreate(path string, create bool) (*DB, error) {
	cPath, err := cString("path", path)
	if err != nil {
		return nil, err
	}
	defer freeCString(cPath)

	outRaw := (**C.zova_database)(C.calloc(1, C.size_t(unsafe.Sizeof(uintptr(0)))))
	defer C.free(unsafe.Pointer(outRaw))
	message := newCMessage()
	defer freeCMessage(message)
	request := C.zova_database_open_request{
		path:              cPath,
		out_db:            outRaw,
		out_error_message: message,
	}

	var status C.zova_status
	if create {
		status = C.zova_database_create(&request)
	} else {
		status = C.zova_database_open(&request)
	}
	if status != C.ZOVA_OK {
		return nil, statusWithMessage(status, takeMessage(message))
	}
	raw := *outRaw
	if raw == nil {
		return nil, newError(StatusInvalidArgument, "Zova returned a nil database handle")
	}
	return &DB{
		ptr:        raw,
		statements: make(map[*Stmt]struct{}),
		writers:    make(map[*ObjectWriter]struct{}),
	}, nil
}

func openWithOptions(path string, options OpenOptions) (*DB, error) {
	cPath, err := cString("path", path)
	if err != nil {
		return nil, err
	}
	defer freeCString(cPath)

	outRaw := (**C.zova_database)(C.calloc(1, C.size_t(unsafe.Sizeof(uintptr(0)))))
	defer C.free(unsafe.Pointer(outRaw))
	message := newCMessage()
	defer freeCMessage(message)
	var flags C.uint32_t
	if options.ReadOnly {
		flags = C.ZOVA_OPEN_READ_ONLY
	}
	request := C.zova_database_open_options_request{
		path:              cPath,
		flags:             flags,
		busy_timeout_ms:   C.uint32_t(options.BusyTimeoutMS),
		out_db:            outRaw,
		out_error_message: message,
	}

	status := C.zova_database_open_with_options(&request)
	if status != C.ZOVA_OK {
		return nil, statusWithMessage(status, takeMessage(message))
	}
	raw := *outRaw
	if raw == nil {
		return nil, newError(StatusInvalidArgument, "Zova returned a nil database handle")
	}
	return &DB{
		ptr:        raw,
		statements: make(map[*Stmt]struct{}),
		writers:    make(map[*ObjectWriter]struct{}),
	}, nil
}

// Close closes the database handle and finalizes any open statements owned by it.
func (db *DB) Close() error {
	if db == nil {
		return closedError("database")
	}
	db.mu.Lock()
	defer db.mu.Unlock()

	if db.closed {
		return closedError("database")
	}

	for stmt := range db.statements {
		if !stmt.closed && stmt.ptr != nil {
			_ = C.zova_statement_finalize(stmt.ptr)
			stmt.ptr = nil
			stmt.closed = true
		}
		delete(db.statements, stmt)
	}
	for writer := range db.writers {
		if !writer.closed && writer.ptr != nil {
			_ = C.zova_object_writer_destroy(writer.ptr)
			writer.ptr = nil
			writer.closed = true
		}
		delete(db.writers, writer)
	}

	status := C.zova_database_close(db.ptr)
	db.ptr = nil
	db.closed = true
	return statusWithMessage(status, "")
}

// Exec executes SQL through the Zova database handle.
func (db *DB) Exec(sql string) error {
	cSQL, err := cString("sql", sql)
	if err != nil {
		return err
	}
	defer freeCString(cSQL)

	return db.withLock(func() error {
		request := C.zova_database_exec_request{
			db:  db.ptr,
			sql: cSQL,
		}
		return statusFromDB(db, C.zova_database_exec(&request))
	})
}

// Prepare prepares SQL for repeated execution.
func (db *DB) Prepare(sql string) (*Stmt, error) {
	cSQL, err := cString("sql", sql)
	if err != nil {
		return nil, err
	}
	defer freeCString(cSQL)

	var stmt *Stmt
	err = db.withLock(func() error {
		outRaw := (**C.zova_statement)(C.calloc(1, C.size_t(unsafe.Sizeof(uintptr(0)))))
		defer C.free(unsafe.Pointer(outRaw))
		request := C.zova_database_prepare_request{
			db:            db.ptr,
			sql:           cSQL,
			out_statement: outRaw,
		}
		if err := statusFromDB(db, C.zova_database_prepare(&request)); err != nil {
			return err
		}
		raw := *outRaw
		if raw == nil {
			return newError(StatusInvalidArgument, "Zova returned a nil statement handle")
		}
		stmt = &Stmt{db: db, ptr: raw}
		db.statements[stmt] = struct{}{}
		return nil
	})
	return stmt, err
}

// Begin starts a deferred transaction.
func (db *DB) Begin() error {
	return db.simple(func(request *C.zova_database_simple_request) C.zova_status {
		return C.zova_database_begin(request)
	})
}

// BeginImmediate starts an immediate transaction.
func (db *DB) BeginImmediate() error {
	return db.simple(func(request *C.zova_database_simple_request) C.zova_status {
		return C.zova_database_begin_immediate(request)
	})
}

// Commit commits the active transaction.
func (db *DB) Commit() error {
	return db.simple(func(request *C.zova_database_simple_request) C.zova_status {
		return C.zova_database_commit(request)
	})
}

// Rollback rolls back the active transaction.
func (db *DB) Rollback() error {
	return db.simple(func(request *C.zova_database_simple_request) C.zova_status {
		return C.zova_database_rollback(request)
	})
}

// Savepoint creates a named SQLite savepoint.
//
// Names must be ASCII identifiers: 1-64 bytes, first byte [A-Za-z_],
// remaining bytes [A-Za-z0-9_], and no case-insensitive _zova_ prefix.
func (db *DB) Savepoint(name string) error {
	return db.savepoint(name, func(request *C.zova_database_savepoint_request) C.zova_status {
		return C.zova_database_savepoint(request)
	})
}

// RollbackToSavepoint rolls back changes made after a named savepoint.
//
// SQLite keeps the savepoint active after ROLLBACK TO; call ReleaseSavepoint
// when the checkpoint should be removed.
func (db *DB) RollbackToSavepoint(name string) error {
	return db.savepoint(name, func(request *C.zova_database_savepoint_request) C.zova_status {
		return C.zova_database_rollback_to_savepoint(request)
	})
}

// ReleaseSavepoint releases a named SQLite savepoint.
func (db *DB) ReleaseSavepoint(name string) error {
	return db.savepoint(name, func(request *C.zova_database_savepoint_request) C.zova_status {
		return C.zova_database_release_savepoint(request)
	})
}

// Vacuum runs an explicit in-place SQLite VACUUM.
func (db *DB) Vacuum() error {
	return db.simple(func(request *C.zova_database_simple_request) C.zova_status {
		return C.zova_database_vacuum(request)
	})
}

// BackupTo creates a faithful snapshot copy at destination.
func (db *DB) BackupTo(destination string, options ...BackupOptions) error {
	option, err := singleBackupOptions(options)
	if err != nil {
		return err
	}
	cDestination, err := cString("destination path", destination)
	if err != nil {
		return err
	}
	defer freeCString(cDestination)

	return db.withLock(func() error {
		request := C.zova_database_backup_request{
			db:               db.ptr,
			destination_path: cDestination,
			flags:            backupFlags(option),
		}
		return statusFromDB(db, C.zova_database_backup(&request))
	})
}

// CompactTo creates a compact, space-reclaiming copy at destination.
func (db *DB) CompactTo(destination string, options ...CompactOptions) error {
	option, err := singleCompactOptions(options)
	if err != nil {
		return err
	}
	cDestination, err := cString("destination path", destination)
	if err != nil {
		return err
	}
	defer freeCString(cDestination)

	return db.withLock(func() error {
		request := C.zova_database_compact_request{
			db:               db.ptr,
			destination_path: cDestination,
			flags:            compactFlags(option),
		}
		return statusFromDB(db, C.zova_database_compact(&request))
	})
}

// SetBusyTimeout sets SQLite's busy timeout for this database handle.
func (db *DB) SetBusyTimeout(milliseconds uint32) error {
	return db.withLock(func() error {
		request := C.zova_database_busy_timeout_request{
			db:           db.ptr,
			milliseconds: C.uint32_t(milliseconds),
		}
		return statusFromDB(db, C.zova_database_set_busy_timeout(&request))
	})
}

// LastInsertRowID returns SQLite's last insert rowid for this database handle.
func (db *DB) LastInsertRowID() (int64, error) {
	value := (*C.int64_t)(C.calloc(1, C.size_t(unsafe.Sizeof(C.int64_t(0)))))
	defer C.free(unsafe.Pointer(value))
	err := db.withLock(func() error {
		request := C.zova_database_last_insert_rowid_request{
			db:        db.ptr,
			out_rowid: value,
		}
		return statusFromDB(db, C.zova_database_last_insert_rowid(&request))
	})
	return int64(*value), err
}

// Changes returns rows changed by the most recent INSERT, UPDATE, or DELETE.
func (db *DB) Changes() (int64, error) {
	value := (*C.int64_t)(C.calloc(1, C.size_t(unsafe.Sizeof(C.int64_t(0)))))
	defer C.free(unsafe.Pointer(value))
	err := db.withLock(func() error {
		request := C.zova_database_changes_request{
			db:          db.ptr,
			out_changes: value,
		}
		return statusFromDB(db, C.zova_database_changes(&request))
	})
	return int64(*value), err
}

// TotalChanges returns all rows changed by INSERT, UPDATE, or DELETE on this handle.
func (db *DB) TotalChanges() (int64, error) {
	value := (*C.int64_t)(C.calloc(1, C.size_t(unsafe.Sizeof(C.int64_t(0)))))
	defer C.free(unsafe.Pointer(value))
	err := db.withLock(func() error {
		request := C.zova_database_total_changes_request{
			db:                db.ptr,
			out_total_changes: value,
		}
		return statusFromDB(db, C.zova_database_total_changes(&request))
	})
	return int64(*value), err
}

func (db *DB) simple(function func(*C.zova_database_simple_request) C.zova_status) error {
	return db.withLock(func() error {
		request := C.zova_database_simple_request{db: db.ptr}
		return statusFromDB(db, function(&request))
	})
}

func (db *DB) savepoint(name string, function func(*C.zova_database_savepoint_request) C.zova_status) error {
	cName, err := cString("savepoint name", name)
	if err != nil {
		return err
	}
	defer freeCString(cName)

	return db.withLock(func() error {
		request := C.zova_database_savepoint_request{
			db:   db.ptr,
			name: cName,
		}
		return statusFromDB(db, function(&request))
	})
}

func (db *DB) withLock(fn func() error) error {
	if db == nil {
		return closedError("database")
	}
	db.mu.Lock()
	defer db.mu.Unlock()
	if db.closed || db.ptr == nil {
		return closedError("database")
	}
	return fn()
}

func singleBackupOptions(options []BackupOptions) (BackupOptions, error) {
	if len(options) > 1 {
		return BackupOptions{}, newError(StatusInvalidArgument, "BackupTo accepts at most one options value")
	}
	if len(options) == 0 {
		return BackupOptions{}, nil
	}
	return options[0], nil
}

func singleCompactOptions(options []CompactOptions) (CompactOptions, error) {
	if len(options) > 1 {
		return CompactOptions{}, newError(StatusInvalidArgument, "CompactTo accepts at most one options value")
	}
	if len(options) == 0 {
		return CompactOptions{}, nil
	}
	return options[0], nil
}

func singleRestoreOptions(options []RestoreOptions) (RestoreOptions, error) {
	if len(options) > 1 {
		return RestoreOptions{}, newError(StatusInvalidArgument, "RestoreBackup accepts at most one options value")
	}
	if len(options) == 0 {
		return RestoreOptions{}, nil
	}
	return options[0], nil
}

func backupFlags(options BackupOptions) C.uint32_t {
	if options.NoVerify {
		return C.ZOVA_BACKUP_NO_VERIFY
	}
	return 0
}

func compactFlags(options CompactOptions) C.uint32_t {
	if options.NoVerify {
		return C.ZOVA_COMPACT_NO_VERIFY
	}
	return 0
}

func restoreFlags(options RestoreOptions) C.uint32_t {
	if options.NoVerify {
		return C.ZOVA_RESTORE_NO_VERIFY
	}
	return 0
}
