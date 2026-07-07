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

// VectorElementType is the raw element type stored by a vector collection.
type VectorElementType int

const (
	VectorElementTypeF32 VectorElementType = C.ZOVA_VECTOR_ELEMENT_TYPE_F32
	VectorElementTypeF16 VectorElementType = C.ZOVA_VECTOR_ELEMENT_TYPE_F16
	VectorElementTypeI8  VectorElementType = C.ZOVA_VECTOR_ELEMENT_TYPE_I8
)

// VectorCollectionOptions configures a vector collection.
type VectorCollectionOptions struct {
	Dimensions  uint32
	Metric      VectorMetric
	ElementType VectorElementType
}

// VectorCollectionInfo describes one vector collection.
type VectorCollectionInfo struct {
	Name        string
	Dimensions  uint32
	Metric      VectorMetric
	ElementType VectorElementType
	VectorCount uint64
}

// VectorInput is one vector row for batch writes.
type VectorInput struct {
	ID     string
	Values VectorValues
}

// VectorValues is a borrowed typed vector value set. The active slice is
// selected by ElementType.
type VectorValues struct {
	ElementType VectorElementType
	F32         []float32
	F16         []uint16
	I8          []int8
}

// Vector is one owned vector row returned by Zova.
type Vector struct {
	ID     string
	Values VectorValues
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
				dimensions:   C.uint32_t(options.Dimensions),
				metric:       C.int(options.Metric),
				element_type: C.int(options.ElementType),
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
func (db *DB) PutVector(collectionName, vectorID string, values VectorValues) error {
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
	cValues, cleanup := cVectorValues(values)
	defer cleanup()

	return db.withLock(func() error {
		request := C.zova_vector_put_request{
			db:              db.ptr,
			collection_name: cCollection,
			vector_id:       cID,
			values:          cValues,
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
func (db *DB) SearchVectors(collectionName string, query VectorValues, limit int) ([]VectorSearchResult, error) {
	cLimit, err := checkedLimit(limit)
	if err != nil {
		return nil, err
	}
	cCollection, err := cString("vector collection name", collectionName)
	if err != nil {
		return nil, err
	}
	defer freeCString(cCollection)
	cQuery, cleanup := cVectorValues(query)
	defer cleanup()
	return db.withSearchResults(func(out *C.zova_vector_search_results) error {
		request := C.zova_vector_search_request{
			db:              db.ptr,
			collection_name: cCollection,
			query:           cQuery,
			limit:           cLimit,
			out_results:     out,
		}
		return statusFromDB(db, C.zova_vector_search(&request))
	})
}

// SearchVectorsIn ranks only the supplied candidate ids. Missing candidates
// are skipped and duplicate candidates are deduplicated by Zova.
func (db *DB) SearchVectorsIn(collectionName string, query VectorValues, candidateIDs []string, limit int) ([]VectorSearchResult, error) {
	cLimit, err := checkedLimit(limit)
	if err != nil {
		return nil, err
	}
	cCollection, err := cString("vector collection name", collectionName)
	if err != nil {
		return nil, err
	}
	defer freeCString(cCollection)
	cQuery, queryCleanup := cVectorValues(query)
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
			candidate_ids:   cCandidates,
			candidate_count: C.size_t(len(candidateIDs)),
			limit:           cLimit,
			out_results:     out,
		}
		return statusFromDB(db, C.zova_vector_search_in(&request))
	})
}

// SearchVectorsWithin ranks vectors whose distance is <= maxDistance.
func (db *DB) SearchVectorsWithin(collectionName string, query VectorValues, maxDistance float64, limit int) ([]VectorSearchResult, error) {
	cLimit, err := checkedLimit(limit)
	if err != nil {
		return nil, err
	}
	cCollection, err := cString("vector collection name", collectionName)
	if err != nil {
		return nil, err
	}
	defer freeCString(cCollection)
	cQuery, cleanup := cVectorValues(query)
	defer cleanup()
	return db.withSearchResults(func(out *C.zova_vector_search_results) error {
		request := C.zova_vector_search_within_request{
			db:              db.ptr,
			collection_name: cCollection,
			query:           cQuery,
			max_distance:    C.double(maxDistance),
			limit:           cLimit,
			out_results:     out,
		}
		return statusFromDB(db, C.zova_vector_search_within(&request))
	})
}

// SearchVectorsInWithin ranks only candidates whose distance is <= maxDistance.
func (db *DB) SearchVectorsInWithin(collectionName string, query VectorValues, candidateIDs []string, maxDistance float64, limit int) ([]VectorSearchResult, error) {
	cLimit, err := checkedLimit(limit)
	if err != nil {
		return nil, err
	}
	cCollection, err := cString("vector collection name", collectionName)
	if err != nil {
		return nil, err
	}
	defer freeCString(cCollection)
	cQuery, queryCleanup := cVectorValues(query)
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

func cUint16Array(values []uint16) (*C.uint16_t, func()) {
	if len(values) == 0 {
		return nil, func() {}
	}
	ptr := C.malloc(C.size_t(len(values)) * C.size_t(unsafe.Sizeof(C.uint16_t(0))))
	out := unsafe.Slice((*C.uint16_t)(ptr), len(values))
	for i, value := range values {
		out[i] = C.uint16_t(value)
	}
	return (*C.uint16_t)(ptr), func() { C.free(ptr) }
}

func cInt8Array(values []int8) (*C.int8_t, func()) {
	if len(values) == 0 {
		return nil, func() {}
	}
	ptr := C.malloc(C.size_t(len(values)) * C.size_t(unsafe.Sizeof(C.int8_t(0))))
	out := unsafe.Slice((*C.int8_t)(ptr), len(values))
	for i, value := range values {
		out[i] = C.int8_t(value)
	}
	return (*C.int8_t)(ptr), func() { C.free(ptr) }
}

func cVectorValues(values VectorValues) (C.zova_vector_values, func()) {
	switch values.ElementType {
	case VectorElementTypeF16:
		cValues, cleanup := cUint16Array(values.F16)
		return C.zova_vector_values{
			element_type: C.int(values.ElementType),
			f16_values:   cValues,
			values_len:   C.size_t(len(values.F16)),
		}, cleanup
	case VectorElementTypeI8:
		cValues, cleanup := cInt8Array(values.I8)
		return C.zova_vector_values{
			element_type: C.int(values.ElementType),
			i8_values:    cValues,
			values_len:   C.size_t(len(values.I8)),
		}, cleanup
	default:
		cValues, cleanup := cFloatArray(values.F32)
		return C.zova_vector_values{
			element_type: C.int(VectorElementTypeF32),
			f32_values:   cValues,
			values_len:   C.size_t(len(values.F32)),
		}, cleanup
	}
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

func copyUint16Array(values *C.uint16_t, length C.size_t) []uint16 {
	if values == nil || length == 0 {
		return []uint16{}
	}
	cValues := unsafe.Slice(values, int(length))
	out := make([]uint16, len(cValues))
	for i, value := range cValues {
		out[i] = uint16(value)
	}
	return out
}

func copyInt8Array(values *C.int8_t, length C.size_t) []int8 {
	if values == nil || length == 0 {
		return []int8{}
	}
	cValues := unsafe.Slice(values, int(length))
	out := make([]int8, len(cValues))
	for i, value := range cValues {
		out[i] = int8(value)
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
		cValues, valuesCleanup := cVectorValues(input.Values)
		cleanups = append(cleanups, valuesCleanup)
		rows[i] = C.zova_vector_input{
			id:     cID,
			values: cValues,
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
	values := VectorValues{ElementType: VectorElementType(vector.element_type)}
	switch values.ElementType {
	case VectorElementTypeF16:
		values.F16 = copyUint16Array(vector.f16_values, vector.values_len)
	case VectorElementTypeI8:
		values.I8 = copyInt8Array(vector.i8_values, vector.values_len)
	default:
		values.ElementType = VectorElementTypeF32
		values.F32 = copyFloatArray(vector.f32_values, vector.values_len)
	}
	return Vector{
		ID:     cStringN(vector.id, vector.id_len),
		Values: values,
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
		ElementType: VectorElementType(info.element_type),
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
