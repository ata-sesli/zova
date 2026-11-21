package zova

// The exported callbacks live apart from sql_function.go because cgo forbids
// C definitions in the preamble of a file that uses //export.

/*
#include <stdint.h>
#include "zova.h"
*/
import "C"

import (
	"runtime/cgo"
	"unsafe"
)

//export zovaGoSQLFunction
func zovaGoSQLFunction(userData unsafe.Pointer, call *C.zova_sql_function_call, out *C.zova_sql_result) {
	if userData == nil || call == nil || out == nil {
		return
	}
	state := cgo.Handle(*(*C.uintptr_t)(userData)).Value().(*sqlFunctionState)
	state.call(call, out)
}

//export zovaGoSQLDestroy
func zovaGoSQLDestroy(userData unsafe.Pointer) {
	if userData == nil {
		return
	}
	cgo.Handle(*(*C.uintptr_t)(userData)).Value().(*sqlFunctionState).release()
}
