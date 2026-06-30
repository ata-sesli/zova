// Package zova provides Go bindings for Zova's C ABI.
//
// This Go binding covers database lifecycle, prepared SQL statements,
// transactions, SQLite-to-Zova conversion, explicit vacuum,
// backup/compact/restore, objects, and vectors over Zova's C ABI.
package zova

/*
#cgo CFLAGS: -I../../include
#cgo LDFLAGS: -L../../zig-out/lib -lzova_c
#cgo linux LDFLAGS: -lpthread -ldl -lm
#include <stdlib.h>
#include "zova.h"
*/
import "C"

// Status is a Zova C ABI status code.
type Status int

const (
	StatusOK                       Status = C.ZOVA_OK
	StatusInvalidArgument          Status = C.ZOVA_INVALID_ARGUMENT
	StatusOutOfMemory              Status = C.ZOVA_OUT_OF_MEMORY
	StatusBusy                     Status = C.ZOVA_BUSY
	StatusLocked                   Status = C.ZOVA_LOCKED
	StatusConstraint               Status = C.ZOVA_CONSTRAINT
	StatusCantOpen                 Status = C.ZOVA_CANT_OPEN
	StatusReadOnly                 Status = C.ZOVA_READ_ONLY
	StatusCorrupt                  Status = C.ZOVA_CORRUPT
	StatusMisuse                   Status = C.ZOVA_MISUSE
	StatusSQLiteError              Status = C.ZOVA_SQLITE_ERROR
	StatusNotZovaPath              Status = C.ZOVA_NOT_ZOVA_PATH
	StatusNotZovaDatabase          Status = C.ZOVA_NOT_ZOVA_DATABASE
	StatusUnsupportedZovaVersion   Status = C.ZOVA_UNSUPPORTED_ZOVA_VERSION
	StatusDestinationExists        Status = C.ZOVA_DESTINATION_EXISTS
	StatusZovaNameConflict         Status = C.ZOVA_ZOVA_NAME_CONFLICT
	StatusObjectNotFound           Status = C.ZOVA_OBJECT_NOT_FOUND
	StatusObjectAlreadyExists      Status = C.ZOVA_OBJECT_ALREADY_EXISTS
	StatusObjectChunkNotFound      Status = C.ZOVA_OBJECT_CHUNK_NOT_FOUND
	StatusObjectChunkHashMismatch  Status = C.ZOVA_OBJECT_CHUNK_HASH_MISMATCH
	StatusObjectCorrupt            Status = C.ZOVA_OBJECT_CORRUPT
	StatusObjectManifestInvalid    Status = C.ZOVA_OBJECT_MANIFEST_INVALID
	StatusObjectRangeInvalid       Status = C.ZOVA_OBJECT_RANGE_INVALID
	StatusObjectTooLarge           Status = C.ZOVA_OBJECT_TOO_LARGE
	StatusObjectTransactionActive  Status = C.ZOVA_OBJECT_TRANSACTION_ACTIVE
	StatusObjectWriterClosed       Status = C.ZOVA_OBJECT_WRITER_CLOSED
	StatusBoundStoreExists         Status = C.ZOVA_BOUND_STORE_EXISTS
	StatusBoundStoreNotFound       Status = C.ZOVA_BOUND_STORE_NOT_FOUND
	StatusBoundStoreInvalid        Status = C.ZOVA_BOUND_STORE_INVALID
	StatusVectorCollectionExists   Status = C.ZOVA_VECTOR_COLLECTION_EXISTS
	StatusVectorCollectionNotFound Status = C.ZOVA_VECTOR_COLLECTION_NOT_FOUND
	StatusVectorNotFound           Status = C.ZOVA_VECTOR_NOT_FOUND
	StatusVectorDimensionMismatch  Status = C.ZOVA_VECTOR_DIMENSION_MISMATCH
	StatusVectorCorrupt            Status = C.ZOVA_VECTOR_CORRUPT
	StatusVectorInvalid            Status = C.ZOVA_VECTOR_INVALID
)

// Step is the result of advancing a prepared statement.
type Step int

const (
	StepRow  Step = C.ZOVA_STEP_ROW
	StepDone Step = C.ZOVA_STEP_DONE
)

// ColumnType is SQLite's runtime column type.
type ColumnType int

const (
	ColumnInteger ColumnType = C.ZOVA_COLUMN_INTEGER
	ColumnFloat   ColumnType = C.ZOVA_COLUMN_FLOAT
	ColumnText    ColumnType = C.ZOVA_COLUMN_TEXT
	ColumnBlob    ColumnType = C.ZOVA_COLUMN_BLOB
	ColumnNull    ColumnType = C.ZOVA_COLUMN_NULL
)

// ABIVersion returns the Zova C ABI version string.
func ABIVersion() string {
	return C.GoString(C.zova_abi_version_string())
}

// ABIVersionNumbers returns the Zova C ABI version components.
func ABIVersionNumbers() (major, minor, patch uint32) {
	return uint32(C.zova_abi_version_major()), uint32(C.zova_abi_version_minor()), uint32(C.zova_abi_version_patch())
}

// StatusName returns the stable C ABI status name.
func StatusName(status Status) string {
	return C.GoString(C.zova_status_name(C.zova_status(status)))
}
