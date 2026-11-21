package zova

/*
#include <stdint.h>
#include <stdlib.h>
#include "zova.h"

extern void zovaGoSQLFunction(void *user_data, zova_sql_function_call *call, zova_sql_result *out_result);
extern void zovaGoSQLDestroy(void *user_data);

static zova_sql_scalar_callback zova_go_sql_callback(void) {
	return (zova_sql_scalar_callback)zovaGoSQLFunction;
}

static zova_sql_destroy_callback zova_go_sql_destroy(void) {
	return (zova_sql_destroy_callback)zovaGoSQLDestroy;
}
*/
import "C"

import (
	"fmt"
	"runtime/cgo"
	"unsafe"
)

// SQLFunction implements an application-defined scalar SQL function.
//
// Each argument is nil, int64, float64, string, or []byte. The function
// returns nil, int, int64, float64, string, or []byte, or a non-nil error to
// fail the statement with that message. A panic also fails the statement.
//
// The function runs while the DB's lock is held, on the goroutine stepping
// the statement, so it must not call methods on the same DB.
type SQLFunction func(args []any) (any, error)

// SQLFunctionFlags declares SQLite function properties.
type SQLFunctionFlags struct {
	// Deterministic: the same arguments always produce the same result.
	Deterministic bool
	// DirectOnly: callable only from top-level SQL, not from views,
	// triggers, or schema expressions.
	DirectOnly bool
	// Innocuous: no side effects; safe in any context.
	Innocuous bool
}

// RegisterFunction registers a scalar SQL function on this connection.
//
// name is an ASCII identifier of 1-64 bytes without a zova_ or _zova_
// prefix. arity is -1 for any argument count, or 0-127. A name and arity pair
// can be registered once per connection. The function is released when the
// DB closes.
func (db *DB) RegisterFunction(name string, arity int, flags SQLFunctionFlags, fn SQLFunction) error {
	if fn == nil {
		return newError(StatusInvalidArgument, "SQL function is nil")
	}
	cName, err := cString("SQL function name", name)
	if err != nil {
		return err
	}
	defer freeCString(cName)
	if arity < -1 || arity > 127 {
		return newError(StatusInvalidArgument, "SQL function arity must be -1..127")
	}
	state := &sqlFunctionState{fn: fn}
	state.handle = cgo.NewHandle(state)
	state.userData = C.malloc(C.size_t(unsafe.Sizeof(C.uintptr_t(0))))
	*(*C.uintptr_t)(state.userData) = C.uintptr_t(state.handle)

	var cFlags C.uint32_t
	if flags.Deterministic {
		cFlags |= C.ZOVA_SQL_FUNCTION_DETERMINISTIC
	}
	if flags.DirectOnly {
		cFlags |= C.ZOVA_SQL_FUNCTION_DIRECT_ONLY
	}
	if flags.Innocuous {
		cFlags |= C.ZOVA_SQL_FUNCTION_INNOCUOUS
	}
	err = db.withLock(func() error {
		request := C.zova_sql_function_register_request{
			db:        db.ptr,
			name:      cName,
			arity:     C.int(arity),
			flags:     cFlags,
			user_data: state.userData,
			callback:  C.zova_go_sql_callback(),
			destroy:   C.zova_go_sql_destroy(),
		}
		return statusFromDB(db, C.zova_database_register_function(&request))
	})
	if err != nil && !state.released {
		// Validation failures return before Zova takes ownership.
		state.release()
	}
	return err
}

// sqlFunctionState is the Go side of one registered function. Zova owns it
// through a cgo.Handle stored in C memory until the destroy callback.
type sqlFunctionState struct {
	fn       SQLFunction
	handle   cgo.Handle
	userData unsafe.Pointer
	// result holds the bytes of the last result until Zova copies them after
	// the callback returns.
	result   unsafe.Pointer
	released bool
}

func (s *sqlFunctionState) call(call *C.zova_sql_function_call, out *C.zova_sql_result) {
	value, err := s.invoke(sqlArgs(call))
	if s.result != nil {
		C.free(s.result)
		s.result = nil
	}
	*out = C.zova_sql_result{}
	if err == nil {
		err = s.setResult(value, out)
	}
	if err != nil {
		message := err.Error()
		s.result = C.CBytes([]byte(message))
		*out = C.zova_sql_result{
			result_type:       C.ZOVA_SQL_RESULT_ERROR,
			error_message:     (*C.char)(s.result),
			error_message_len: C.size_t(len(message)),
		}
	}
}

func (s *sqlFunctionState) invoke(args []any) (value any, err error) {
	defer func() {
		if recovered := recover(); recovered != nil {
			value = nil
			err = fmt.Errorf("Go SQL function panicked: %v", recovered)
		}
	}()
	return s.fn(args)
}

func (s *sqlFunctionState) setResult(value any, out *C.zova_sql_result) error {
	switch v := value.(type) {
	case nil:
		out.result_type = C.ZOVA_SQL_RESULT_NULL
	case int:
		out.result_type = C.ZOVA_SQL_RESULT_INTEGER
		out.int64_value = C.int64_t(v)
	case int64:
		out.result_type = C.ZOVA_SQL_RESULT_INTEGER
		out.int64_value = C.int64_t(v)
	case float64:
		out.result_type = C.ZOVA_SQL_RESULT_FLOAT
		out.double_value = C.double(v)
	case string:
		out.result_type = C.ZOVA_SQL_RESULT_TEXT
		s.setBytes([]byte(v), out)
	case []byte:
		out.result_type = C.ZOVA_SQL_RESULT_BLOB
		s.setBytes(v, out)
	default:
		return fmt.Errorf("unsupported SQL function result type %T", value)
	}
	return nil
}

func (s *sqlFunctionState) setBytes(value []byte, out *C.zova_sql_result) {
	if len(value) == 0 {
		return
	}
	s.result = C.CBytes(value)
	out.data = s.result
	out.data_len = C.size_t(len(value))
}

func (s *sqlFunctionState) release() {
	if s.released {
		return
	}
	s.released = true
	if s.result != nil {
		C.free(s.result)
		s.result = nil
	}
	C.free(s.userData)
	s.userData = nil
	s.handle.Delete()
}

func sqlArgs(call *C.zova_sql_function_call) []any {
	if call.argc == 0 || call.argv == nil {
		return []any{}
	}
	raw := unsafe.Slice(call.argv, int(call.argc))
	args := make([]any, len(raw))
	for i, value := range raw {
		switch value.value_type {
		case C.ZOVA_SQL_VALUE_INTEGER:
			args[i] = int64(value.int64_value)
		case C.ZOVA_SQL_VALUE_FLOAT:
			args[i] = float64(value.double_value)
		case C.ZOVA_SQL_VALUE_TEXT:
			args[i] = C.GoStringN((*C.char)(value.data), C.int(value.data_len))
		case C.ZOVA_SQL_VALUE_BLOB:
			args[i] = C.GoBytes(value.data, C.int(value.data_len))
		default:
			args[i] = nil
		}
	}
	return args
}
