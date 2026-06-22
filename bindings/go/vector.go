package zova

/*
#include <stdlib.h>
#include "zova.h"
*/
import "C"

import (
	"encoding/binary"
	"math"
	"unsafe"
)

// VectorMetric is the distance metric configured for a vector collection.
type VectorMetric int

const (
	VectorMetricCosine VectorMetric = C.ZOVA_VECTOR_METRIC_COSINE
	VectorMetricL2     VectorMetric = C.ZOVA_VECTOR_METRIC_L2
	VectorMetricDot    VectorMetric = C.ZOVA_VECTOR_METRIC_DOT
)

// VectorCollectionOptions configures a vector collection.
type VectorCollectionOptions struct {
	Dimensions uint32
	Metric     VectorMetric
}

// VectorCollectionInfo describes one vector collection.
type VectorCollectionInfo struct {
	Name        string
	Dimensions  uint32
	Metric      VectorMetric
	VectorCount uint64
}

// VectorInput is one vector row for batch writes.
type VectorInput struct {
	ID     string
	Values []float32
}

// Vector is one owned vector row returned by Zova.
type Vector struct {
	ID     string
	Values []float32
}

// VectorSearchResult is one exact-search hit. Lower distance is better.
type VectorSearchResult struct {
	ID       string
	Distance float64
}

// EncodeVectorBlob encodes f32 values as little-endian bytes for SQL-native
// vector functions and zova_vector_search query_vector bindings.
func EncodeVectorBlob(values []float32) []byte {
	out := make([]byte, len(values)*4)
	for i, value := range values {
		binary.LittleEndian.PutUint32(out[i*4:], math.Float32bits(value))
	}
	return out
}

// CreateVectorCollection creates a native vector collection.
func (db *DB) CreateVectorCollection(name string, options VectorCollectionOptions) error {
	cName, err := cString("vector collection name", name)
	if err != nil {
		return err
	}
	defer freeCString(cName)

	return db.withLock(func() error {
		request := C.zova_vector_collection_create_request{
			db:   db.ptr,
			name: cName,
			options: C.zova_vector_collection_options{
				dimensions: C.uint32_t(options.Dimensions),
				metric:     C.int(options.Metric),
			},
		}
		return statusFromDB(db, C.zova_vector_collection_create(&request))
	})
}

// HasVectorCollection reports whether a collection exists.
func (db *DB) HasVectorCollection(name string) (bool, error) {
	cName, err := cString("vector collection name", name)
	if err != nil {
		return false, err
	}
	defer freeCString(cName)

	out := (*C.uint8_t)(C.calloc(1, C.size_t(unsafe.Sizeof(C.uint8_t(0)))))
	defer C.free(unsafe.Pointer(out))
	err = db.withLock(func() error {
		request := C.zova_vector_collection_exists_request{
			db:         db.ptr,
			name:       cName,
			out_exists: out,
		}
		return statusFromDB(db, C.zova_vector_collection_exists(&request))
	})
	return *out != 0, err
}

// VectorCollectionInfo returns metadata for one collection.
func (db *DB) VectorCollectionInfo(name string) (VectorCollectionInfo, error) {
	cName, err := cString("vector collection name", name)
	if err != nil {
		return VectorCollectionInfo{}, err
	}
	defer freeCString(cName)

	info := newCVectorCollectionInfo()
	defer freeCVectorCollectionInfo(info)
	err = db.withLock(func() error {
		request := C.zova_vector_collection_info_get_request{
			db:       db.ptr,
			name:     cName,
			out_info: info,
		}
		return statusFromDB(db, C.zova_vector_collection_info_get(&request))
	})
	if err != nil {
		return VectorCollectionInfo{}, err
	}
	return copyVectorCollectionInfo(info), nil
}

// ListVectorCollections returns all vector collections sorted by name.
func (db *DB) ListVectorCollections() ([]VectorCollectionInfo, error) {
	list := (*C.zova_vector_collection_list)(C.calloc(1, C.size_t(unsafe.Sizeof(C.zova_vector_collection_list{}))))
	defer func() {
		C.zova_vector_collection_list_free(list)
		C.free(unsafe.Pointer(list))
	}()
	err := db.withLock(func() error {
		request := C.zova_vector_collections_list_request{
			db:       db.ptr,
			out_list: list,
		}
		return statusFromDB(db, C.zova_vector_collections_list(&request))
	})
	if err != nil {
		return nil, err
	}
	return copyVectorCollectionList(list), nil
}

// DeleteVectorCollection deletes a vector collection and its private vector rows.
func (db *DB) DeleteVectorCollection(name string) error {
	cName, err := cString("vector collection name", name)
	if err != nil {
		return err
	}
	defer freeCString(cName)

	return db.withLock(func() error {
		request := C.zova_vector_collection_delete_request{
			db:   db.ptr,
			name: cName,
		}
		return statusFromDB(db, C.zova_vector_collection_delete(&request))
	})
}

// PutVector inserts or replaces one vector row.
func (db *DB) PutVector(collectionName, vectorID string, values []float32) error {
	cCollection, err := cString("vector collection name", collectionName)
	if err != nil {
		return err
	}
	defer freeCString(cCollection)
	cID, err := cString("vector id", vectorID)
	if err != nil {
		return err
	}
	defer freeCString(cID)
	cValues, cleanup := cFloatArray(values)
	defer cleanup()

	return db.withLock(func() error {
		request := C.zova_vector_put_request{
			db:              db.ptr,
			collection_name: cCollection,
			vector_id:       cID,
			values:          cValues,
			values_len:      C.size_t(len(values)),
		}
		return statusFromDB(db, C.zova_vector_put(&request))
	})
}

// PutVectors inserts or replaces many vector rows. Duplicate ids are applied
// in input order, so the last entry wins.
func (db *DB) PutVectors(collectionName string, vectors []VectorInput) error {
	cCollection, err := cString("vector collection name", collectionName)
	if err != nil {
		return err
	}
	defer freeCString(cCollection)
	cVectors, cleanup, err := cVectorInputs(vectors)
	if err != nil {
		return err
	}
	defer cleanup()

	return db.withLock(func() error {
		request := C.zova_vector_put_many_request{
			db:              db.ptr,
			collection_name: cCollection,
			vectors:         cVectors,
			vectors_len:     C.size_t(len(vectors)),
		}
		return statusFromDB(db, C.zova_vector_put_many(&request))
	})
}

// GetVector returns one vector row.
func (db *DB) GetVector(collectionName, vectorID string) (Vector, error) {
	cCollection, cID, cleanup, err := cCollectionAndVectorID(collectionName, vectorID)
	if err != nil {
		return Vector{}, err
	}
	defer cleanup()
	vector := newCVector()
	defer freeCVector(vector)
	err = db.withLock(func() error {
		request := C.zova_vector_get_request{
			db:              db.ptr,
			collection_name: cCollection,
			vector_id:       cID,
			out_vector:      vector,
		}
		return statusFromDB(db, C.zova_vector_get(&request))
	})
	if err != nil {
		return Vector{}, err
	}
	return copyVector(vector), nil
}

// HasVector reports whether a vector id exists in a collection.
func (db *DB) HasVector(collectionName, vectorID string) (bool, error) {
	cCollection, cID, cleanup, err := cCollectionAndVectorID(collectionName, vectorID)
	if err != nil {
		return false, err
	}
	defer cleanup()
	out := (*C.uint8_t)(C.calloc(1, C.size_t(unsafe.Sizeof(C.uint8_t(0)))))
	defer C.free(unsafe.Pointer(out))
	err = db.withLock(func() error {
		request := C.zova_vector_exists_request{
			db:              db.ptr,
			collection_name: cCollection,
			vector_id:       cID,
			out_exists:      out,
		}
		return statusFromDB(db, C.zova_vector_exists(&request))
	})
	return *out != 0, err
}

// DeleteVector deletes one vector row.
func (db *DB) DeleteVector(collectionName, vectorID string) error {
	cCollection, cID, cleanup, err := cCollectionAndVectorID(collectionName, vectorID)
	if err != nil {
		return err
	}
	defer cleanup()
	return db.withLock(func() error {
		request := C.zova_vector_delete_request{
			db:              db.ptr,
			collection_name: cCollection,
			vector_id:       cID,
		}
		return statusFromDB(db, C.zova_vector_delete(&request))
	})
}

// SearchVectors ranks a whole collection by exact distance to query.
func (db *DB) SearchVectors(collectionName string, query []float32, limit int) ([]VectorSearchResult, error) {
	cLimit, err := checkedLimit(limit)
	if err != nil {
		return nil, err
	}
	cCollection, err := cString("vector collection name", collectionName)
	if err != nil {
		return nil, err
	}
	defer freeCString(cCollection)
	cQuery, cleanup := cFloatArray(query)
	defer cleanup()
	return db.withSearchResults(func(out *C.zova_vector_search_results) error {
		request := C.zova_vector_search_request{
			db:              db.ptr,
			collection_name: cCollection,
			query:           cQuery,
			query_len:       C.size_t(len(query)),
			limit:           cLimit,
			out_results:     out,
		}
		return statusFromDB(db, C.zova_vector_search(&request))
	})
}

// SearchVectorsIn ranks only the supplied candidate ids. Missing candidates
// are skipped and duplicate candidates are deduplicated by Zova.
func (db *DB) SearchVectorsIn(collectionName string, query []float32, candidateIDs []string, limit int) ([]VectorSearchResult, error) {
	cLimit, err := checkedLimit(limit)
	if err != nil {
		return nil, err
	}
	cCollection, err := cString("vector collection name", collectionName)
	if err != nil {
		return nil, err
	}
	defer freeCString(cCollection)
	cQuery, queryCleanup := cFloatArray(query)
	defer queryCleanup()
	cCandidates, candidatesCleanup, err := cCandidateIDs(candidateIDs)
	if err != nil {
		return nil, err
	}
	defer candidatesCleanup()
	return db.withSearchResults(func(out *C.zova_vector_search_results) error {
		request := C.zova_vector_search_in_request{
			db:              db.ptr,
			collection_name: cCollection,
			query:           cQuery,
			query_len:       C.size_t(len(query)),
			candidate_ids:   cCandidates,
			candidate_count: C.size_t(len(candidateIDs)),
			limit:           cLimit,
			out_results:     out,
		}
		return statusFromDB(db, C.zova_vector_search_in(&request))
	})
}

// SearchVectorsWithin ranks vectors whose distance is <= maxDistance.
func (db *DB) SearchVectorsWithin(collectionName string, query []float32, maxDistance float64, limit int) ([]VectorSearchResult, error) {
	cLimit, err := checkedLimit(limit)
	if err != nil {
		return nil, err
	}
	cCollection, err := cString("vector collection name", collectionName)
	if err != nil {
		return nil, err
	}
	defer freeCString(cCollection)
	cQuery, cleanup := cFloatArray(query)
	defer cleanup()
	return db.withSearchResults(func(out *C.zova_vector_search_results) error {
		request := C.zova_vector_search_within_request{
			db:              db.ptr,
			collection_name: cCollection,
			query:           cQuery,
			query_len:       C.size_t(len(query)),
			max_distance:    C.double(maxDistance),
			limit:           cLimit,
			out_results:     out,
		}
		return statusFromDB(db, C.zova_vector_search_within(&request))
	})
}

// SearchVectorsInWithin ranks only candidates whose distance is <= maxDistance.
func (db *DB) SearchVectorsInWithin(collectionName string, query []float32, candidateIDs []string, maxDistance float64, limit int) ([]VectorSearchResult, error) {
	cLimit, err := checkedLimit(limit)
	if err != nil {
		return nil, err
	}
	cCollection, err := cString("vector collection name", collectionName)
	if err != nil {
		return nil, err
	}
	defer freeCString(cCollection)
	cQuery, queryCleanup := cFloatArray(query)
	defer queryCleanup()
	cCandidates, candidatesCleanup, err := cCandidateIDs(candidateIDs)
	if err != nil {
		return nil, err
	}
	defer candidatesCleanup()
	return db.withSearchResults(func(out *C.zova_vector_search_results) error {
		request := C.zova_vector_search_in_within_request{
			db:              db.ptr,
			collection_name: cCollection,
			query:           cQuery,
			query_len:       C.size_t(len(query)),
			candidate_ids:   cCandidates,
			candidate_count: C.size_t(len(candidateIDs)),
			max_distance:    C.double(maxDistance),
			limit:           cLimit,
			out_results:     out,
		}
		return statusFromDB(db, C.zova_vector_search_in_within(&request))
	})
}

// SearchVectorsByID ranks a collection using an existing vector as the query.
// The source vector is excluded from results.
func (db *DB) SearchVectorsByID(collectionName, sourceVectorID string, limit int) ([]VectorSearchResult, error) {
	cLimit, err := checkedLimit(limit)
	if err != nil {
		return nil, err
	}
	cCollection, cID, cleanup, err := cCollectionAndVectorID(collectionName, sourceVectorID)
	if err != nil {
		return nil, err
	}
	defer cleanup()
	return db.withSearchResults(func(out *C.zova_vector_search_results) error {
		request := C.zova_vector_search_by_id_request{
			db:               db.ptr,
			collection_name:  cCollection,
			source_vector_id: cID,
			limit:            cLimit,
			out_results:      out,
		}
		return statusFromDB(db, C.zova_vector_search_by_id(&request))
	})
}

// SearchVectorsByIDIn ranks candidates using an existing vector as the query.
// The source vector is excluded from results even when passed as a candidate.
func (db *DB) SearchVectorsByIDIn(collectionName, sourceVectorID string, candidateIDs []string, limit int) ([]VectorSearchResult, error) {
	cLimit, err := checkedLimit(limit)
	if err != nil {
		return nil, err
	}
	cCollection, cID, cleanup, err := cCollectionAndVectorID(collectionName, sourceVectorID)
	if err != nil {
		return nil, err
	}
	defer cleanup()
	cCandidates, candidatesCleanup, err := cCandidateIDs(candidateIDs)
	if err != nil {
		return nil, err
	}
	defer candidatesCleanup()
	return db.withSearchResults(func(out *C.zova_vector_search_results) error {
		request := C.zova_vector_search_by_id_in_request{
			db:               db.ptr,
			collection_name:  cCollection,
			source_vector_id: cID,
			candidate_ids:    cCandidates,
			candidate_count:  C.size_t(len(candidateIDs)),
			limit:            cLimit,
			out_results:      out,
		}
		return statusFromDB(db, C.zova_vector_search_by_id_in(&request))
	})
}

// SearchVectorsByIDWithin ranks vectors within maxDistance from a source id.
func (db *DB) SearchVectorsByIDWithin(collectionName, sourceVectorID string, maxDistance float64, limit int) ([]VectorSearchResult, error) {
	cLimit, err := checkedLimit(limit)
	if err != nil {
		return nil, err
	}
	cCollection, cID, cleanup, err := cCollectionAndVectorID(collectionName, sourceVectorID)
	if err != nil {
		return nil, err
	}
	defer cleanup()
	return db.withSearchResults(func(out *C.zova_vector_search_results) error {
		request := C.zova_vector_search_by_id_within_request{
			db:               db.ptr,
			collection_name:  cCollection,
			source_vector_id: cID,
			max_distance:     C.double(maxDistance),
			limit:            cLimit,
			out_results:      out,
		}
		return statusFromDB(db, C.zova_vector_search_by_id_within(&request))
	})
}

// SearchVectorsByIDInWithin ranks candidates within maxDistance from a source id.
func (db *DB) SearchVectorsByIDInWithin(collectionName, sourceVectorID string, candidateIDs []string, maxDistance float64, limit int) ([]VectorSearchResult, error) {
	cLimit, err := checkedLimit(limit)
	if err != nil {
		return nil, err
	}
	cCollection, cID, cleanup, err := cCollectionAndVectorID(collectionName, sourceVectorID)
	if err != nil {
		return nil, err
	}
	defer cleanup()
	cCandidates, candidatesCleanup, err := cCandidateIDs(candidateIDs)
	if err != nil {
		return nil, err
	}
	defer candidatesCleanup()
	return db.withSearchResults(func(out *C.zova_vector_search_results) error {
		request := C.zova_vector_search_by_id_in_within_request{
			db:               db.ptr,
			collection_name:  cCollection,
			source_vector_id: cID,
			candidate_ids:    cCandidates,
			candidate_count:  C.size_t(len(candidateIDs)),
			max_distance:     C.double(maxDistance),
			limit:            cLimit,
			out_results:      out,
		}
		return statusFromDB(db, C.zova_vector_search_by_id_in_within(&request))
	})
}

func (db *DB) withSearchResults(fn func(*C.zova_vector_search_results) error) ([]VectorSearchResult, error) {
	results := (*C.zova_vector_search_results)(C.calloc(1, C.size_t(unsafe.Sizeof(C.zova_vector_search_results{}))))
	defer func() {
		C.zova_vector_search_results_free(results)
		C.free(unsafe.Pointer(results))
	}()
	err := db.withLock(func() error {
		return fn(results)
	})
	if err != nil {
		return nil, err
	}
	return copyVectorSearchResults(results), nil
}

func cCollectionAndVectorID(collectionName, vectorID string) (*C.char, *C.char, func(), error) {
	cCollection, err := cString("vector collection name", collectionName)
	if err != nil {
		return nil, nil, func() {}, err
	}
	cID, err := cString("vector id", vectorID)
	if err != nil {
		freeCString(cCollection)
		return nil, nil, func() {}, err
	}
	return cCollection, cID, func() {
		freeCString(cID)
		freeCString(cCollection)
	}, nil
}

func checkedLimit(limit int) (C.size_t, error) {
	if limit < 0 {
		return 0, newError(StatusInvalidArgument, "limit must be non-negative")
	}
	return C.size_t(limit), nil
}

func cFloatArray(values []float32) (*C.float, func()) {
	if len(values) == 0 {
		return nil, func() {}
	}
	ptr := C.malloc(C.size_t(len(values)) * C.size_t(unsafe.Sizeof(C.float(0))))
	out := unsafe.Slice((*C.float)(ptr), len(values))
	for i, value := range values {
		out[i] = C.float(value)
	}
	return (*C.float)(ptr), func() { C.free(ptr) }
}

func copyFloatArray(values *C.float, length C.size_t) []float32 {
	if values == nil || length == 0 {
		return []float32{}
	}
	cValues := unsafe.Slice(values, int(length))
	out := make([]float32, len(cValues))
	for i, value := range cValues {
		out[i] = float32(value)
	}
	return out
}

func cCandidateIDs(ids []string) (**C.char, func(), error) {
	if len(ids) == 0 {
		return nil, func() {}, nil
	}
	ptr := C.calloc(C.size_t(len(ids)), C.size_t(unsafe.Sizeof(uintptr(0))))
	array := unsafe.Slice((**C.char)(ptr), len(ids))
	cleanup := func() {
		for _, value := range array {
			if value != nil {
				freeCString(value)
			}
		}
		C.free(ptr)
	}
	for i, id := range ids {
		cID, err := cString("candidate vector id", id)
		if err != nil {
			cleanup()
			return nil, func() {}, err
		}
		array[i] = cID
	}
	return (**C.char)(ptr), cleanup, nil
}

func cVectorInputs(vectors []VectorInput) (*C.zova_vector_input, func(), error) {
	if len(vectors) == 0 {
		return nil, func() {}, nil
	}
	ptr := C.malloc(C.size_t(len(vectors)) * C.size_t(unsafe.Sizeof(C.zova_vector_input{})))
	rows := unsafe.Slice((*C.zova_vector_input)(ptr), len(vectors))
	cleanups := make([]func(), 0, len(vectors)*2)
	cleanup := func() {
		for i := len(cleanups) - 1; i >= 0; i-- {
			cleanups[i]()
		}
		C.free(ptr)
	}
	for i, input := range vectors {
		cID, err := cString("vector id", input.ID)
		if err != nil {
			cleanup()
			return nil, func() {}, err
		}
		cleanups = append(cleanups, func() { freeCString(cID) })
		cValues, valuesCleanup := cFloatArray(input.Values)
		cleanups = append(cleanups, valuesCleanup)
		rows[i] = C.zova_vector_input{
			id:         cID,
			values:     cValues,
			values_len: C.size_t(len(input.Values)),
		}
	}
	return (*C.zova_vector_input)(ptr), cleanup, nil
}

func newCVector() *C.zova_vector {
	return (*C.zova_vector)(C.calloc(1, C.size_t(unsafe.Sizeof(C.zova_vector{}))))
}

func freeCVector(vector *C.zova_vector) {
	if vector == nil {
		return
	}
	C.zova_vector_free(vector)
	C.free(unsafe.Pointer(vector))
}

func copyVector(vector *C.zova_vector) Vector {
	return Vector{
		ID:     cStringN(vector.id, vector.id_len),
		Values: copyFloatArray(vector.values, vector.values_len),
	}
}

func copyVectorSearchResults(results *C.zova_vector_search_results) []VectorSearchResult {
	if results == nil || results.len == 0 {
		return []VectorSearchResult{}
	}
	items := unsafe.Slice(results.items, int(results.len))
	out := make([]VectorSearchResult, len(items))
	for i, item := range items {
		out[i] = VectorSearchResult{
			ID:       cStringN(item.id, item.id_len),
			Distance: float64(item.distance),
		}
	}
	return out
}

func newCVectorCollectionInfo() *C.zova_vector_collection_info {
	return (*C.zova_vector_collection_info)(C.calloc(1, C.size_t(unsafe.Sizeof(C.zova_vector_collection_info{}))))
}

func freeCVectorCollectionInfo(info *C.zova_vector_collection_info) {
	if info == nil {
		return
	}
	C.zova_vector_collection_info_free(info)
	C.free(unsafe.Pointer(info))
}

func copyVectorCollectionInfo(info *C.zova_vector_collection_info) VectorCollectionInfo {
	return VectorCollectionInfo{
		Name:        cStringN(info.name, info.name_len),
		Dimensions:  uint32(info.dimensions),
		Metric:      VectorMetric(info.metric),
		VectorCount: uint64(info.vector_count),
	}
}

func copyVectorCollectionList(list *C.zova_vector_collection_list) []VectorCollectionInfo {
	if list == nil || list.len == 0 {
		return []VectorCollectionInfo{}
	}
	items := unsafe.Slice(list.items, int(list.len))
	out := make([]VectorCollectionInfo, len(items))
	for i := range items {
		out[i] = copyVectorCollectionInfo(&items[i])
	}
	return out
}

func cStringN(value *C.char, length C.size_t) string {
	if value == nil || length == 0 {
		return ""
	}
	bytes := unsafe.Slice((*byte)(unsafe.Pointer(value)), int(length))
	return string(bytes)
}
