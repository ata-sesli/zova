package zova

/*
#include <stdlib.h>
#include "zova.h"
*/
import "C"

import (
	"errors"
	"fmt"
	"strings"
	"unsafe"
)

// Error is returned for Zova, SQLite, and binding validation failures.
type Error struct {
	Status  Status
	Name    string
	Message string
}

func (e *Error) Error() string {
	if e.Message == "" {
		return e.Name
	}
	return fmt.Sprintf("%s: %s", e.Name, e.Message)
}

func newError(status Status, message string) error {
	if status == StatusOK {
		return nil
	}
	return &Error{
		Status:  status,
		Name:    StatusName(status),
		Message: message,
	}
}

func closedError(kind string) error {
	return newError(StatusMisuse, kind+" is closed")
}

func errorStatusIs(err error, status Status) bool {
	var zerr *Error
	return errors.As(err, &zerr) && zerr.Status == status
}

func statusWithMessage(status C.zova_status, message string) error {
	return newError(Status(status), message)
}

func statusFromDB(db *DB, status C.zova_status) error {
	if status == C.ZOVA_OK {
		return nil
	}
	message := ""
	if db != nil && db.ptr != nil {
		if raw := C.zova_database_last_error_message(db.ptr); raw != nil {
			message = C.GoString(raw)
		}
	}
	return statusWithMessage(status, message)
}

func cString(context, value string) (*C.char, error) {
	if err := validateNoNUL(context, value); err != nil {
		return nil, err
	}
	return C.CString(value), nil
}

func validateNoNUL(context, value string) error {
	if strings.IndexByte(value, 0) >= 0 {
		return newError(StatusInvalidArgument, context+" contains NUL byte")
	}
	return nil
}

func freeCString(value *C.char) {
	C.free(unsafe.Pointer(value))
}

func newCMessage() *C.zova_message {
	return (*C.zova_message)(C.calloc(1, C.size_t(unsafe.Sizeof(C.zova_message{}))))
}

func freeCMessage(message *C.zova_message) {
	if message == nil {
		return
	}
	C.zova_message_free(message)
	C.free(unsafe.Pointer(message))
}

func takeMessage(message *C.zova_message) string {
	if message == nil || message.data == nil {
		return ""
	}
	bytes := unsafe.Slice((*byte)(unsafe.Pointer(message.data)), int(message.len))
	text := string(bytes)
	C.zova_message_free(message)
	return text
}

func checkedParameterIndex(index int) (C.int, error) {
	if index <= 0 || index > int(^uint32(0)>>1) {
		return 0, newError(StatusInvalidArgument, "parameter index out of range")
	}
	return C.int(index), nil
}

func checkedColumnIndex(index int) (C.int, error) {
	if index < 0 || index > int(^uint32(0)>>1) {
		return 0, newError(StatusInvalidArgument, "column index out of range")
	}
	return C.int(index), nil
}
