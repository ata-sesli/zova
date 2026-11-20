package zova

/*
#include <stdlib.h>
#include "zova.h"
*/
import "C"

import (
	"unsafe"
)

// KvEntry is a key-value pair for a batch key-value put.
type KvEntry struct {
	Key   []byte
	Value []byte
}

// KvGet returns the value stored for key in namespace, or (nil, nil) when the
// key is absent.
func (db *DB) KvGet(namespace, key []byte) ([]byte, error) {
	ns, cleanupNS := cBytes(namespace)
	defer cleanupNS()
	keyData, cleanupKey := cBytes(key)
	defer cleanupKey()

	result := (*C.zova_kv_get_result)(C.calloc(1, C.size_t(unsafe.Sizeof(C.zova_kv_get_result{}))))
	defer func() {
		C.zova_kv_get_result_free(result)
		C.free(unsafe.Pointer(result))
	}()
	err := db.withLock(func() error {
		request := C.zova_kv_get_request{
			db:         db.ptr,
			ns:         C.zova_kv_bytes{data: ns, len: C.size_t(len(namespace))},
			key:        C.zova_kv_bytes{data: keyData, len: C.size_t(len(key))},
			out_result: result,
		}
		return statusFromDB(db, C.zova_kv_get(&request))
	})
	if err != nil {
		return nil, err
	}
	if result.found == 0 {
		return nil, nil
	}
	return copyBuffer(&result.value), nil
}

// KvGetMany returns values for keys in namespace, preserving input order and
// duplicates. Missing keys map to nil.
func (db *DB) KvGetMany(namespace []byte, keys [][]byte) ([]*[]byte, error) {
	ns, cleanupNS := cBytes(namespace)
	defer cleanupNS()

	cKeys, cleanupKeys := cKvKeys(keys)
	defer cleanupKeys()

	results := (*C.zova_kv_get_many_results)(C.calloc(1, C.size_t(unsafe.Sizeof(C.zova_kv_get_many_results{}))))
	defer func() {
		C.zova_kv_get_many_results_free(results)
		C.free(unsafe.Pointer(results))
	}()
	err := db.withLock(func() error {
		request := C.zova_kv_get_many_request{
			db:          db.ptr,
			ns:          C.zova_kv_bytes{data: ns, len: C.size_t(len(namespace))},
			keys:        cKeys,
			keys_len:    C.size_t(len(keys)),
			out_results: results,
		}
		return statusFromDB(db, C.zova_kv_get_many(&request))
	})
	if err != nil {
		return nil, err
	}

	out := make([]*[]byte, int(results.len))
	for i := 0; i < int(results.len); i++ {
		item := (*C.zova_kv_get_result)(unsafe.Pointer(uintptr(unsafe.Pointer(results.items)) + uintptr(i)*unsafe.Sizeof(C.zova_kv_get_result{})))
		if item.found == 0 {
			out[i] = nil
			continue
		}
		value := copyBuffer(&item.value)
		out[i] = &value
	}
	return out, nil
}

// KvPut inserts or replaces key in namespace with value.
func (db *DB) KvPut(namespace, key, value []byte) error {
	ns, cleanupNS := cBytes(namespace)
	defer cleanupNS()
	keyData, cleanupKey := cBytes(key)
	defer cleanupKey()
	valueData, cleanupValue := cBytes(value)
	defer cleanupValue()

	return db.withLock(func() error {
		request := C.zova_kv_put_request{
			db:    db.ptr,
			ns:    C.zova_kv_bytes{data: ns, len: C.size_t(len(namespace))},
			key:   C.zova_kv_bytes{data: keyData, len: C.size_t(len(key))},
			value: C.zova_kv_bytes{data: valueData, len: C.size_t(len(value))},
		}
		return statusFromDB(db, C.zova_kv_put(&request))
	})
}

// KvPutMany inserts or replaces entries in namespace in one atomic operation.
func (db *DB) KvPutMany(namespace []byte, entries []KvEntry) error {
	ns, cleanupNS := cBytes(namespace)
	defer cleanupNS()

	cEntries, cleanupEntries := cKvEntries(entries)
	defer cleanupEntries()

	return db.withLock(func() error {
		request := C.zova_kv_put_many_request{
			db:          db.ptr,
			ns:          C.zova_kv_bytes{data: ns, len: C.size_t(len(namespace))},
			entries:     cEntries,
			entries_len: C.size_t(len(entries)),
		}
		return statusFromDB(db, C.zova_kv_put_many(&request))
	})
}

// KvDelete deletes key in namespace. Deleting a missing key is not an error.
func (db *DB) KvDelete(namespace, key []byte) error {
	ns, cleanupNS := cBytes(namespace)
	defer cleanupNS()
	keyData, cleanupKey := cBytes(key)
	defer cleanupKey()

	return db.withLock(func() error {
		request := C.zova_kv_delete_request{
			db:  db.ptr,
			ns:  C.zova_kv_bytes{data: ns, len: C.size_t(len(namespace))},
			key: C.zova_kv_bytes{data: keyData, len: C.size_t(len(key))},
		}
		return statusFromDB(db, C.zova_kv_delete(&request))
	})
}

// KvDeleteMany deletes keys in namespace in one atomic operation. Missing keys
// are ignored.
func (db *DB) KvDeleteMany(namespace []byte, keys [][]byte) error {
	ns, cleanupNS := cBytes(namespace)
	defer cleanupNS()

	cKeys, cleanupKeys := cKvKeys(keys)
	defer cleanupKeys()

	return db.withLock(func() error {
		request := C.zova_kv_delete_many_request{
			db:       db.ptr,
			ns:       C.zova_kv_bytes{data: ns, len: C.size_t(len(namespace))},
			keys:     cKeys,
			keys_len: C.size_t(len(keys)),
		}
		return statusFromDB(db, C.zova_kv_delete_many(&request))
	})
}

// KvCount returns the number of entries in namespace.
func (db *DB) KvCount(namespace []byte) (uint64, error) {
	ns, cleanupNS := cBytes(namespace)
	defer cleanupNS()

	out := (*C.uint64_t)(C.calloc(1, C.size_t(unsafe.Sizeof(C.uint64_t(0)))))
	defer C.free(unsafe.Pointer(out))
	err := db.withLock(func() error {
		request := C.zova_kv_count_request{
			db:        db.ptr,
			ns:        C.zova_kv_bytes{data: ns, len: C.size_t(len(namespace))},
			out_count: out,
		}
		return statusFromDB(db, C.zova_kv_count(&request))
	})
	if err != nil {
		return 0, err
	}
	return uint64(*out), nil
}

// KvClearNamespace deletes every entry in namespace. An empty namespace is not
// an error.
func (db *DB) KvClearNamespace(namespace []byte) error {
	ns, cleanupNS := cBytes(namespace)
	defer cleanupNS()

	return db.withLock(func() error {
		request := C.zova_kv_clear_namespace_request{
			db: db.ptr,
			ns: C.zova_kv_bytes{data: ns, len: C.size_t(len(namespace))},
		}
		return statusFromDB(db, C.zova_kv_clear_namespace(&request))
	})
}

// KvScanOptions selects one page of a namespace for KvScan. Keys compare as
// raw bytes: a shorter key sorts before every longer key it prefixes. Every
// given bound applies. For Start, End and After, nil means no bound, while an
// empty non-nil slice is the empty key.
type KvScanOptions struct {
	// Prefix limits the page to keys that begin with these bytes.
	Prefix []byte
	// Start is an inclusive lower bound.
	Start []byte
	// End is an exclusive upper bound.
	End []byte
	// After continues strictly after this key: pass the last key of the
	// previous page.
	After []byte
	// Limit is the most entries returned; it must be greater than zero.
	Limit int
	// KeysOnly returns keys only; every Value is then empty.
	KeysOnly bool
}

// KvScanPage is one scan page in ascending key byte order. HasMore is true
// when at least one further entry matches the same options.
type KvScanPage struct {
	Entries []KvEntry
	HasMore bool
}

// KvScan returns one page of namespace in ascending key byte order. Each call
// holds no statement afterwards; writes between pages are visible to later
// pages.
func (db *DB) KvScan(namespace []byte, options KvScanOptions) (KvScanPage, error) {
	if options.Limit <= 0 {
		return KvScanPage{}, newError(StatusInvalidArgument, "kv scan limit must be greater than zero")
	}
	ns, cleanupNS := cBytes(namespace)
	defer cleanupNS()
	prefix, cleanupPrefix := cBytes(options.Prefix)
	defer cleanupPrefix()
	start, hasStart, cleanupStart := cOptionalKvBytes(options.Start)
	defer cleanupStart()
	end, hasEnd, cleanupEnd := cOptionalKvBytes(options.End)
	defer cleanupEnd()
	after, hasAfter, cleanupAfter := cOptionalKvBytes(options.After)
	defer cleanupAfter()
	keysOnly := C.uint8_t(0)
	if options.KeysOnly {
		keysOnly = 1
	}

	results := (*C.zova_kv_scan_results)(C.calloc(1, C.size_t(unsafe.Sizeof(C.zova_kv_scan_results{}))))
	defer func() {
		C.zova_kv_scan_results_free(results)
		C.free(unsafe.Pointer(results))
	}()
	err := db.withLock(func() error {
		request := C.zova_kv_scan_request{
			db:          db.ptr,
			ns:          C.zova_kv_bytes{data: ns, len: C.size_t(len(namespace))},
			prefix:      C.zova_kv_bytes{data: prefix, len: C.size_t(len(options.Prefix))},
			start:       start,
			has_start:   hasStart,
			end:         end,
			has_end:     hasEnd,
			after:       after,
			has_after:   hasAfter,
			limit:       C.size_t(options.Limit),
			keys_only:   keysOnly,
			out_results: results,
		}
		return statusFromDB(db, C.zova_kv_scan(&request))
	})
	if err != nil {
		return KvScanPage{}, err
	}

	page := KvScanPage{Entries: make([]KvEntry, int(results.len)), HasMore: results.has_more != 0}
	items := unsafe.Slice(results.items, int(results.len))
	for i := range items {
		page.Entries[i] = KvEntry{Key: copyBuffer(&items[i].key), Value: copyBuffer(&items[i].value)}
	}
	return page, nil
}

// KvPutIfAbsent inserts key in namespace only when it is absent and reports
// whether it was written.
func (db *DB) KvPutIfAbsent(namespace, key, value []byte) (bool, error) {
	ns, cleanupNS := cBytes(namespace)
	defer cleanupNS()
	keyData, cleanupKey := cBytes(key)
	defer cleanupKey()
	valueData, cleanupValue := cBytes(value)
	defer cleanupValue()

	return kvApplied(db, func(out *C.uint8_t) C.zova_status {
		request := C.zova_kv_put_if_absent_request{
			db:          db.ptr,
			ns:          C.zova_kv_bytes{data: ns, len: C.size_t(len(namespace))},
			key:         C.zova_kv_bytes{data: keyData, len: C.size_t(len(key))},
			value:       C.zova_kv_bytes{data: valueData, len: C.size_t(len(value))},
			out_applied: out,
		}
		return C.zova_kv_put_if_absent(&request)
	})
}

// KvCompareAndPut replaces the value of key in namespace only when the current
// value equals expected byte for byte, and reports whether it was written. A
// missing key never matches.
func (db *DB) KvCompareAndPut(namespace, key, expected, value []byte) (bool, error) {
	ns, cleanupNS := cBytes(namespace)
	defer cleanupNS()
	keyData, cleanupKey := cBytes(key)
	defer cleanupKey()
	expectedData, cleanupExpected := cBytes(expected)
	defer cleanupExpected()
	valueData, cleanupValue := cBytes(value)
	defer cleanupValue()

	return kvApplied(db, func(out *C.uint8_t) C.zova_status {
		request := C.zova_kv_compare_and_put_request{
			db:          db.ptr,
			ns:          C.zova_kv_bytes{data: ns, len: C.size_t(len(namespace))},
			key:         C.zova_kv_bytes{data: keyData, len: C.size_t(len(key))},
			expected:    C.zova_kv_bytes{data: expectedData, len: C.size_t(len(expected))},
			value:       C.zova_kv_bytes{data: valueData, len: C.size_t(len(value))},
			out_applied: out,
		}
		return C.zova_kv_compare_and_put(&request)
	})
}

// KvCompareAndDelete deletes key in namespace only when its current value
// equals expected byte for byte, and reports whether it was deleted. A missing
// key never matches.
func (db *DB) KvCompareAndDelete(namespace, key, expected []byte) (bool, error) {
	ns, cleanupNS := cBytes(namespace)
	defer cleanupNS()
	keyData, cleanupKey := cBytes(key)
	defer cleanupKey()
	expectedData, cleanupExpected := cBytes(expected)
	defer cleanupExpected()

	return kvApplied(db, func(out *C.uint8_t) C.zova_status {
		request := C.zova_kv_compare_and_delete_request{
			db:          db.ptr,
			ns:          C.zova_kv_bytes{data: ns, len: C.size_t(len(namespace))},
			key:         C.zova_kv_bytes{data: keyData, len: C.size_t(len(key))},
			expected:    C.zova_kv_bytes{data: expectedData, len: C.size_t(len(expected))},
			out_applied: out,
		}
		return C.zova_kv_compare_and_delete(&request)
	})
}

func kvApplied(db *DB, call func(out *C.uint8_t) C.zova_status) (bool, error) {
	out := (*C.uint8_t)(C.calloc(1, 1))
	defer C.free(unsafe.Pointer(out))
	err := db.withLock(func() error {
		return statusFromDB(db, call(out))
	})
	if err != nil {
		return false, err
	}
	return *out != 0, nil
}

func cOptionalKvBytes(bytes []byte) (C.zova_kv_bytes, C.uint8_t, func()) {
	if bytes == nil {
		return C.zova_kv_bytes{}, 0, func() {}
	}
	data, cleanup := cBytes(bytes)
	return C.zova_kv_bytes{data: data, len: C.size_t(len(bytes))}, 1, cleanup
}

func cKvKeys(keys [][]byte) (*C.zova_kv_bytes, func()) {
	if len(keys) == 0 {
		return nil, func() {}
	}
	ptr := C.malloc(C.size_t(len(keys)) * C.size_t(unsafe.Sizeof(C.zova_kv_bytes{})))
	cKeys := unsafe.Slice((*C.zova_kv_bytes)(ptr), len(keys))
	cleanups := make([]func(), 0, len(keys))
	for i, key := range keys {
		data, cleanup := cBytes(key)
		cleanups = append(cleanups, cleanup)
		cKeys[i] = C.zova_kv_bytes{data: data, len: C.size_t(len(key))}
	}
	return (*C.zova_kv_bytes)(ptr), func() {
		for _, cleanup := range cleanups {
			cleanup()
		}
		C.free(ptr)
	}
}

func cKvEntries(entries []KvEntry) (*C.zova_kv_put_entry, func()) {
	if len(entries) == 0 {
		return nil, func() {}
	}
	ptr := C.malloc(C.size_t(len(entries)) * C.size_t(unsafe.Sizeof(C.zova_kv_put_entry{})))
	cEntries := unsafe.Slice((*C.zova_kv_put_entry)(ptr), len(entries))
	cleanups := make([]func(), 0, len(entries)*2)
	for i, entry := range entries {
		keyData, cleanupKey := cBytes(entry.Key)
		cleanups = append(cleanups, cleanupKey)
		valueData, cleanupValue := cBytes(entry.Value)
		cleanups = append(cleanups, cleanupValue)
		cEntries[i] = C.zova_kv_put_entry{
			key:   C.zova_kv_bytes{data: keyData, len: C.size_t(len(entry.Key))},
			value: C.zova_kv_bytes{data: valueData, len: C.size_t(len(entry.Value))},
		}
	}
	return (*C.zova_kv_put_entry)(ptr), func() {
		for _, cleanup := range cleanups {
			cleanup()
		}
		C.free(ptr)
	}
}
