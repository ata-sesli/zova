package zova

/*
#include <stdlib.h>
#include <stdint.h>
*/
import "C"

import "unsafe"

// cArena owns C allocations for the inputs and outputs of one synchronous
// call. C cannot keep Go pointers stored inside request arrays, so batch
// inputs are copied into C memory and released together by free.
type cArena struct {
	ptrs []unsafe.Pointer
}

// alloc returns zeroed C memory for count items of size bytes, or nil when
// count is zero.
func (a *cArena) alloc(count int, size uintptr) unsafe.Pointer {
	if count == 0 {
		return nil
	}
	ptr := C.calloc(C.size_t(count), C.size_t(size))
	if ptr == nil {
		panic("zova: C allocation failed")
	}
	a.ptrs = append(a.ptrs, ptr)
	return ptr
}

func (a *cArena) str(context, value string) (*C.char, error) {
	if err := validateNoNUL(context, value); err != nil {
		return nil, err
	}
	ptr := C.CString(value)
	a.ptrs = append(a.ptrs, unsafe.Pointer(ptr))
	return ptr, nil
}

func (a *cArena) optionalStr(context string, value *string) (*C.char, error) {
	if value == nil {
		return nil, nil
	}
	return a.str(context, *value)
}

func (a *cArena) strs(context string, values []string) (**C.char, error) {
	ptr := a.alloc(len(values), unsafe.Sizeof(uintptr(0)))
	if ptr == nil {
		return nil, nil
	}
	slots := unsafe.Slice((**C.char)(ptr), len(values))
	for i, value := range values {
		cValue, err := a.str(context, value)
		if err != nil {
			return nil, err
		}
		slots[i] = cValue
	}
	return (**C.char)(ptr), nil
}

func (a *cArena) bytes(value []byte) *C.uint8_t {
	if len(value) == 0 {
		return nil
	}
	ptr := C.CBytes(value)
	a.ptrs = append(a.ptrs, ptr)
	return (*C.uint8_t)(ptr)
}

func (a *cArena) int64s(values []int64) *C.int64_t {
	ptr := a.alloc(len(values), unsafe.Sizeof(C.int64_t(0)))
	if ptr == nil {
		return nil
	}
	slots := unsafe.Slice((*C.int64_t)(ptr), len(values))
	for i, value := range values {
		slots[i] = C.int64_t(value)
	}
	return (*C.int64_t)(ptr)
}

func (a *cArena) free() {
	for i := len(a.ptrs) - 1; i >= 0; i-- {
		C.free(a.ptrs[i])
	}
	a.ptrs = nil
}

func copyInt64s(values *C.int64_t, length int) []int64 {
	out := make([]int64, length)
	if values == nil || length == 0 {
		return out
	}
	for i, value := range unsafe.Slice(values, length) {
		out[i] = int64(value)
	}
	return out
}
