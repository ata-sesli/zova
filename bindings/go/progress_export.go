package zova

// The exported callback lives apart from progress.go because cgo forbids C
// definitions in the preamble of a file that uses //export.

/*
#include <stdint.h>
#include "zova.h"
*/
import "C"

import (
	"runtime/cgo"
	"unsafe"
)

//export zovaGoProgress
func zovaGoProgress(userData unsafe.Pointer, progress *C.zova_progress) (result C.int32_t) {
	state := cgo.Handle(*(*C.uintptr_t)(userData)).Value().(*progressState)
	if state.panicked || state.err != nil {
		return 1
	}
	defer func() {
		if value := recover(); value != nil {
			state.panicked = true
			state.panicVal = value
			result = 1
		}
	}()
	state.err = state.fn(Progress{
		Phase:  ProgressPhase(progress.phase),
		Member: ProgressMember(progress.member),
		Done:   uint64(progress.done),
		Total:  uint64(progress.total),
	})
	if state.err != nil {
		return 1
	}
	return 0
}
