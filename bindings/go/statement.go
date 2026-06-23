package zova

/*
#include <stdlib.h>
#include "zova.h"
*/
import "C"

import "unsafe"

// Stmt owns one prepared statement.
type Stmt struct {
	db     *DB
	ptr    *C.zova_statement
	closed bool
}

// Close finalizes the statement.
func (s *Stmt) Close() error {
	db, err := s.lock()
	if err != nil {
		return err
	}
	defer db.mu.Unlock()

	status := C.zova_statement_finalize(s.ptr)
	s.ptr = nil
	s.closed = true
	delete(db.statements, s)
	return statusFromDB(db, status)
}

// Step advances the statement.
func (s *Stmt) Step() (Step, error) {
	result := (*C.zova_step_result)(C.calloc(1, C.size_t(unsafe.Sizeof(C.zova_step_result(0)))))
	defer C.free(unsafe.Pointer(result))
	err := s.withLock(func(db *DB) error {
		request := C.zova_statement_step_request{
			statement:  s.ptr,
			out_result: result,
		}
		return statusFromDB(db, C.zova_statement_step(&request))
	})
	return Step(*result), err
}

// Reset resets the statement while preserving bindings.
func (s *Stmt) Reset() error {
	return s.withLock(func(db *DB) error {
		return statusFromDB(db, C.zova_statement_reset(s.ptr))
	})
}

// ClearBindings clears all bound parameters.
func (s *Stmt) ClearBindings() error {
	return s.withLock(func(db *DB) error {
		return statusFromDB(db, C.zova_statement_clear_bindings(s.ptr))
	})
}

// BindNull binds SQL NULL to a 1-based parameter index.
func (s *Stmt) BindNull(index int) error {
	cIndex, err := checkedParameterIndex(index)
	if err != nil {
		return err
	}
	return s.withLock(func(db *DB) error {
		request := C.zova_statement_bind_null_request{
			statement: s.ptr,
			index:     cIndex,
		}
		return statusFromDB(db, C.zova_statement_bind_null(&request))
	})
}

// BindInt64 binds an int64 to a 1-based parameter index.
func (s *Stmt) BindInt64(index int, value int64) error {
	cIndex, err := checkedParameterIndex(index)
	if err != nil {
		return err
	}
	return s.withLock(func(db *DB) error {
		request := C.zova_statement_bind_int64_request{
			statement: s.ptr,
			index:     cIndex,
			value:     C.int64_t(value),
		}
		return statusFromDB(db, C.zova_statement_bind_int64(&request))
	})
}

// BindFloat64 binds a float64 to a 1-based parameter index.
func (s *Stmt) BindFloat64(index int, value float64) error {
	cIndex, err := checkedParameterIndex(index)
	if err != nil {
		return err
	}
	return s.withLock(func(db *DB) error {
		request := C.zova_statement_bind_double_request{
			statement: s.ptr,
			index:     cIndex,
			value:     C.double(value),
		}
		return statusFromDB(db, C.zova_statement_bind_double(&request))
	})
}

// BindText binds UTF-8 text to a 1-based parameter index.
func (s *Stmt) BindText(index int, value string) error {
	cIndex, err := checkedParameterIndex(index)
	if err != nil {
		return err
	}
	if err := validateNoNUL("text", value); err != nil {
		return err
	}
	var data *C.uint8_t
	if len(value) != 0 {
		data = (*C.uint8_t)(C.CBytes([]byte(value)))
		defer C.free(unsafe.Pointer(data))
	}
	return s.withLock(func(db *DB) error {
		request := C.zova_statement_bind_text_request{
			statement: s.ptr,
			index:     cIndex,
			data:      data,
			len:       C.size_t(len(value)),
		}
		return statusFromDB(db, C.zova_statement_bind_text(&request))
	})
}

// BindBlob binds bytes to a 1-based parameter index.
func (s *Stmt) BindBlob(index int, value []byte) error {
	cIndex, err := checkedParameterIndex(index)
	if err != nil {
		return err
	}
	var data *C.uint8_t
	if len(value) != 0 {
		data = (*C.uint8_t)(C.CBytes(value))
		defer C.free(unsafe.Pointer(data))
	}
	return s.withLock(func(db *DB) error {
		request := C.zova_statement_bind_blob_request{
			statement: s.ptr,
			index:     cIndex,
			data:      data,
			len:       C.size_t(len(value)),
		}
		return statusFromDB(db, C.zova_statement_bind_blob(&request))
	})
}

// ParameterCount returns the number of SQL parameters.
func (s *Stmt) ParameterCount() (int, error) {
	count := (*C.int)(C.calloc(1, C.size_t(unsafe.Sizeof(C.int(0)))))
	defer C.free(unsafe.Pointer(count))
	err := s.withLock(func(db *DB) error {
		request := C.zova_statement_parameter_count_request{
			statement: s.ptr,
			out_count: count,
		}
		return statusFromDB(db, C.zova_statement_parameter_count(&request))
	})
	return int(*count), err
}

// ParameterIndex returns the 1-based parameter index for name, or 0 if missing.
func (s *Stmt) ParameterIndex(name string) (int, error) {
	cName, err := cString("parameter name", name)
	if err != nil {
		return 0, err
	}
	defer freeCString(cName)

	index := (*C.int)(C.calloc(1, C.size_t(unsafe.Sizeof(C.int(0)))))
	defer C.free(unsafe.Pointer(index))
	err = s.withLock(func(db *DB) error {
		request := C.zova_statement_parameter_index_request{
			statement: s.ptr,
			name:      cName,
			out_index: index,
		}
		return statusFromDB(db, C.zova_statement_parameter_index(&request))
	})
	return int(*index), err
}

// ColumnCount returns the number of result columns.
func (s *Stmt) ColumnCount() (int, error) {
	count := (*C.int)(C.calloc(1, C.size_t(unsafe.Sizeof(C.int(0)))))
	defer C.free(unsafe.Pointer(count))
	err := s.withLock(func(db *DB) error {
		request := C.zova_statement_column_count_request{
			statement: s.ptr,
			out_count: count,
		}
		return statusFromDB(db, C.zova_statement_column_count(&request))
	})
	return int(*count), err
}

// ColumnName returns the result-column name for a 0-based column index.
func (s *Stmt) ColumnName(index int) (string, error) {
	cIndex, err := checkedColumnIndex(index)
	if err != nil {
		return "", err
	}
	var value string
	err = s.withLock(func(db *DB) error {
		text := (*C.zova_text)(C.calloc(1, C.size_t(unsafe.Sizeof(C.zova_text{}))))
		defer func() {
			C.zova_text_free(text)
			C.free(unsafe.Pointer(text))
		}()
		request := C.zova_statement_column_name_request{
			statement: s.ptr,
			index:     cIndex,
			out_name:  text,
		}
		if err := statusFromDB(db, C.zova_statement_column_name(&request)); err != nil {
			return err
		}
		bytes := unsafe.Slice((*byte)(unsafe.Pointer(text.data)), int(text.len))
		value = string(bytes)
		return nil
	})
	return value, err
}

// ColumnType returns the runtime type of a result column.
func (s *Stmt) ColumnType(index int) (ColumnType, error) {
	cIndex, err := checkedColumnIndex(index)
	if err != nil {
		return 0, err
	}
	var value C.zova_column_type
	err = s.withLock(func(db *DB) error {
		var err error
		value, err = s.columnTypeLocked(db, cIndex)
		return err
	})
	return ColumnType(value), err
}

// ColumnInt64 reads a column as int64.
func (s *Stmt) ColumnInt64(index int) (int64, error) {
	cIndex, err := checkedColumnIndex(index)
	if err != nil {
		return 0, err
	}
	value := (*C.int64_t)(C.calloc(1, C.size_t(unsafe.Sizeof(C.int64_t(0)))))
	defer C.free(unsafe.Pointer(value))
	err = s.withLock(func(db *DB) error {
		request := C.zova_statement_column_int64_request{
			statement: s.ptr,
			index:     cIndex,
			out_value: value,
		}
		return statusFromDB(db, C.zova_statement_column_int64(&request))
	})
	return int64(*value), err
}

// ColumnFloat64 reads a column as float64.
func (s *Stmt) ColumnFloat64(index int) (float64, error) {
	cIndex, err := checkedColumnIndex(index)
	if err != nil {
		return 0, err
	}
	value := (*C.double)(C.calloc(1, C.size_t(unsafe.Sizeof(C.double(0)))))
	defer C.free(unsafe.Pointer(value))
	err = s.withLock(func(db *DB) error {
		request := C.zova_statement_column_double_request{
			statement: s.ptr,
			index:     cIndex,
			out_value: value,
		}
		return statusFromDB(db, C.zova_statement_column_double(&request))
	})
	return float64(*value), err
}

// ColumnText reads a column as text. ok is false for SQL NULL.
func (s *Stmt) ColumnText(index int) (value string, ok bool, err error) {
	cIndex, err := checkedColumnIndex(index)
	if err != nil {
		return "", false, err
	}
	err = s.withLock(func(db *DB) error {
		text := (*C.zova_text)(C.calloc(1, C.size_t(unsafe.Sizeof(C.zova_text{}))))
		defer func() {
			C.zova_text_free(text)
			C.free(unsafe.Pointer(text))
		}()
		request := C.zova_statement_column_text_request{
			statement: s.ptr,
			index:     cIndex,
			out_text:  text,
		}
		if err := statusFromDB(db, C.zova_statement_column_text(&request)); err != nil {
			return err
		}
		if text.data == nil {
			value = ""
			ok = false
			return nil
		}
		bytes := unsafe.Slice((*byte)(unsafe.Pointer(text.data)), int(text.len))
		value = string(bytes)
		ok = true
		return nil
	})
	return value, ok, err
}

// ColumnBlob reads a column as bytes. ok is false for SQL NULL.
func (s *Stmt) ColumnBlob(index int) (value []byte, ok bool, err error) {
	cIndex, err := checkedColumnIndex(index)
	if err != nil {
		return nil, false, err
	}
	err = s.withLock(func(db *DB) error {
		buffer := (*C.zova_buffer)(C.calloc(1, C.size_t(unsafe.Sizeof(C.zova_buffer{}))))
		defer func() {
			C.zova_buffer_free(buffer)
			C.free(unsafe.Pointer(buffer))
		}()
		request := C.zova_statement_column_blob_request{
			statement:  s.ptr,
			index:      cIndex,
			out_buffer: buffer,
		}
		if err := statusFromDB(db, C.zova_statement_column_blob(&request)); err != nil {
			return err
		}
		if buffer.data == nil {
			columnType, err := s.columnTypeLocked(db, cIndex)
			if err != nil {
				return err
			}
			if ColumnType(columnType) == ColumnNull {
				value = nil
				ok = false
				return nil
			}
			value = []byte{}
			ok = true
			return nil
		}
		bytes := unsafe.Slice((*byte)(unsafe.Pointer(buffer.data)), int(buffer.len))
		value = append([]byte(nil), bytes...)
		ok = true
		return nil
	})
	return value, ok, err
}

func (s *Stmt) lock() (*DB, error) {
	if s == nil || s.db == nil {
		return nil, closedError("statement")
	}
	s.db.mu.Lock()
	if s.db.closed || s.db.ptr == nil {
		s.db.mu.Unlock()
		return nil, closedError("database")
	}
	if s.closed || s.ptr == nil {
		s.db.mu.Unlock()
		return nil, closedError("statement")
	}
	return s.db, nil
}

func (s *Stmt) withLock(fn func(*DB) error) error {
	db, err := s.lock()
	if err != nil {
		return err
	}
	defer db.mu.Unlock()
	return fn(db)
}

func (s *Stmt) columnTypeLocked(db *DB, index C.int) (C.zova_column_type, error) {
	out := (*C.zova_column_type)(C.calloc(1, C.size_t(unsafe.Sizeof(C.zova_column_type(0)))))
	defer C.free(unsafe.Pointer(out))
	request := C.zova_statement_column_type_request{
		statement: s.ptr,
		index:     index,
		out_type:  out,
	}
	err := statusFromDB(db, C.zova_statement_column_type(&request))
	return *out, err
}
