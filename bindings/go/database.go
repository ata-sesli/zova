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

// Create creates a new .zova database.
func Create(path string) (*DB, error) {
	return openOrCreate(path, true)
}

// Open opens an existing .zova database.
func Open(path string) (*DB, error) {
	return openOrCreate(path, false)
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

// Vacuum runs an explicit in-place SQLite VACUUM.
func (db *DB) Vacuum() error {
	return db.simple(func(request *C.zova_database_simple_request) C.zova_status {
		return C.zova_database_vacuum(request)
	})
}

func (db *DB) simple(function func(*C.zova_database_simple_request) C.zova_status) error {
	return db.withLock(func() error {
		request := C.zova_database_simple_request{db: db.ptr}
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
