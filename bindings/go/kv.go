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
			db:        db.ptr,
			ns:        C.zova_kv_bytes{data: ns, len: C.size_t(len(namespace))},
			key:       C.zova_kv_bytes{data: keyData, len: C.size_t(len(key))},
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
			db:         db.ptr,
			ns:         C.zova_kv_bytes{data: ns, len: C.size_t(len(namespace))},
			keys:       cKeys,
			keys_len:   C.size_t(len(keys)),
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
