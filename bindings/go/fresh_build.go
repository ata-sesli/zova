package zova

/*
#include <stdlib.h>
#include "zova.h"
*/
import "C"

import (
	"fmt"
	"unsafe"
)

// FreshBuild loads predeclared, initially empty targets and publishes them
// together. Begin requires foreign keys on, empty object, vector, and graph
// stores, and no open statements or object writers. While the session is
// active, other calls on its DB fail with StatusInvalidArgument.
//
// A failed step rolls the session back; later steps then fail with
// StatusMisuse. Close an unfinished session to roll it back.
type FreshBuild struct {
	db           *DB
	ptr          *C.zova_fresh_build
	active       bool
	nodeKeyCount int
	edgeKeyCount int
}

// FreshBuildProfile holds timings and counts for one finished fresh build.
type FreshBuildProfile struct {
	ValidationMS         float64
	TableLoadMS          float64
	FTSLoadMS            float64
	GraphLoadMS          float64
	GraphValidationMS    float64
	GraphKeyGenerationMS float64
	GraphNodeLoadMS      float64
	GraphEdgeLoadMS      float64
	VectorLoadMS         float64
	IndexBuildMS         float64
	CommitMS             float64
	TableRows            uint64
	FTSRows              uint64
	VectorRows           uint64
	PayloadBytes         uint64
}

// FreshBuildResult reports the graph keys assigned by the session's graph
// step, aligned with its inputs, and the build profile.
type FreshBuildResult struct {
	NodeKeys []int64
	EdgeKeys []int64
	Profile  FreshBuildProfile
}

// BeginFreshBuild starts a fresh-build session on db.
func (db *DB) BeginFreshBuild() (*FreshBuild, error) {
	out := (**C.zova_fresh_build)(C.calloc(1, C.size_t(unsafe.Sizeof(uintptr(0)))))
	defer C.free(unsafe.Pointer(out))
	err := db.withLock(func() error {
		request := C.zova_fresh_build_begin_request{db: db.ptr, out_build: out}
		return statusFromDB(db, C.zova_fresh_build_begin(&request))
	})
	if err != nil {
		return nil, err
	}
	if *out == nil {
		return nil, newError(StatusMisuse, "fresh build begin returned no session")
	}
	build := &FreshBuild{db: db, ptr: *out, active: true}
	db.mu.Lock()
	if db.freshBuilds == nil {
		db.freshBuilds = make(map[*FreshBuild]struct{})
	}
	db.freshBuilds[build] = struct{}{}
	db.mu.Unlock()
	return build, nil
}

// TableRows loads rows into an ordinary table. values holds the rows one
// after another, len(columns) values per row. Each value is nil, int, int64,
// float64, string, or []byte.
func (b *FreshBuild) TableRows(table string, columns []string, values []any) error {
	return b.rows(table, columns, values, false)
}

// FTSRows loads rows into an FTS5 table. Values follow TableRows.
func (b *FreshBuild) FTSRows(table string, columns []string, values []any) error {
	return b.rows(table, columns, values, true)
}

func (b *FreshBuild) rows(table string, columns []string, values []any, fts bool) error {
	return b.step(func(db *DB, arena *cArena) error {
		cTable, err := arena.str("fresh build table name", table)
		if err != nil {
			return err
		}
		cColumns, err := arena.strs("fresh build column name", columns)
		if err != nil {
			return err
		}
		rowCount := 0
		if len(columns) > 0 {
			if len(values)%len(columns) != 0 {
				return newError(StatusInvalidArgument, "fresh build values are not a whole number of rows")
			}
			rowCount = len(values) / len(columns)
		}
		cValues, err := arena.freshValues(values)
		if err != nil {
			return err
		}
		request := C.zova_fresh_build_rows_request{
			build: b.ptr, table_name: cTable,
			column_names: cColumns, column_count: C.size_t(len(columns)),
			values: cValues, row_count: C.size_t(rowCount),
		}
		if fts {
			return statusFromDB(db, C.zova_fresh_build_fts_rows(&request))
		}
		return statusFromDB(db, C.zova_fresh_build_table_rows(&request))
	})
}

// Graph creates and loads one graph. It may run once per session; Finish
// returns the assigned keys.
func (b *FreshBuild) Graph(graphName string, nodes []GraphFreshNodeInput, edges []GraphFreshEdgePayloadInput) error {
	err := b.step(func(db *DB, arena *cArena) error {
		cGraph, err := arena.str("graph name", graphName)
		if err != nil {
			return err
		}
		cNodes, err := arena.graphFreshNodeInputs(nodes)
		if err != nil {
			return err
		}
		cEdges, err := arena.graphFreshEdgePayloadInputs(edges)
		if err != nil {
			return err
		}
		request := C.zova_fresh_build_graph_request{
			build: b.ptr, graph_name: cGraph,
			nodes: cNodes, nodes_len: C.size_t(len(nodes)),
			edges: cEdges, edges_len: C.size_t(len(edges)),
		}
		return statusFromDB(db, C.zova_fresh_build_graph(&request))
	})
	if err == nil {
		b.nodeKeyCount = len(nodes)
		b.edgeKeyCount = len(edges)
	}
	return err
}

// Vectors loads rows into an existing, empty vector collection.
func (b *FreshBuild) Vectors(collectionName string, vectors []VectorInput) error {
	return b.step(func(db *DB, arena *cArena) error {
		cCollection, err := arena.str("vector collection name", collectionName)
		if err != nil {
			return err
		}
		cVectors, cleanup, err := cVectorInputs(vectors)
		if err != nil {
			return err
		}
		defer cleanup()
		request := C.zova_fresh_build_vectors_request{
			build: b.ptr, collection_name: cCollection,
			vectors: cVectors, vectors_len: C.size_t(len(vectors)),
		}
		return statusFromDB(db, C.zova_fresh_build_vectors(&request))
	})
}

// Finish builds indexes and commits everything the session loaded.
func (b *FreshBuild) Finish() (FreshBuildResult, error) {
	var nodeKeys, edgeKeys *C.int64_t
	var profile *C.zova_fresh_build_profile
	var arena cArena
	defer arena.free()
	err := b.step(func(db *DB, _ *cArena) error {
		nodeKeys = (*C.int64_t)(arena.alloc(b.nodeKeyCount, unsafe.Sizeof(C.int64_t(0))))
		edgeKeys = (*C.int64_t)(arena.alloc(b.edgeKeyCount, unsafe.Sizeof(C.int64_t(0))))
		profile = (*C.zova_fresh_build_profile)(arena.alloc(1, unsafe.Sizeof(C.zova_fresh_build_profile{})))
		request := C.zova_fresh_build_finish_request{
			build:         b.ptr,
			out_node_keys: nodeKeys, out_node_keys_capacity: C.size_t(b.nodeKeyCount),
			out_edge_keys: edgeKeys, out_edge_keys_capacity: C.size_t(b.edgeKeyCount),
			out_profile: profile,
		}
		return statusFromDB(db, C.zova_fresh_build_finish(&request))
	})
	if err != nil {
		return FreshBuildResult{}, err
	}
	b.active = false
	return FreshBuildResult{
		NodeKeys: copyInt64s(nodeKeys, b.nodeKeyCount),
		EdgeKeys: copyInt64s(edgeKeys, b.edgeKeyCount),
		Profile: FreshBuildProfile{
			ValidationMS:         float64(profile.validation_ms),
			TableLoadMS:          float64(profile.table_load_ms),
			FTSLoadMS:            float64(profile.fts_load_ms),
			GraphLoadMS:          float64(profile.graph_load_ms),
			GraphValidationMS:    float64(profile.graph_validation_ms),
			GraphKeyGenerationMS: float64(profile.graph_key_generation_ms),
			GraphNodeLoadMS:      float64(profile.graph_node_load_ms),
			GraphEdgeLoadMS:      float64(profile.graph_edge_load_ms),
			VectorLoadMS:         float64(profile.vector_load_ms),
			IndexBuildMS:         float64(profile.index_build_ms),
			CommitMS:             float64(profile.commit_ms),
			TableRows:            uint64(profile.table_rows),
			FTSRows:              uint64(profile.fts_rows),
			VectorRows:           uint64(profile.vector_rows),
			PayloadBytes:         uint64(profile.payload_bytes),
		},
	}, nil
}

// Abort rolls the session back. The DB is usable again afterwards.
func (b *FreshBuild) Abort() error {
	db, err := b.lock()
	if err != nil {
		return err
	}
	defer db.mu.Unlock()
	b.active = false
	return statusFromDB(db, C.zova_fresh_build_abort(b.ptr))
}

// Close releases the session, rolling it back if it is still active.
func (b *FreshBuild) Close() error {
	if b == nil || b.db == nil {
		return closedError("fresh build")
	}
	b.db.mu.Lock()
	defer b.db.mu.Unlock()
	if b.ptr == nil {
		return closedError("fresh build")
	}
	b.destroyLocked(b.db)
	return nil
}

func (b *FreshBuild) destroyLocked(db *DB) {
	C.zova_fresh_build_destroy(b.ptr)
	b.ptr = nil
	b.active = false
	delete(db.freshBuilds, b)
}

func (b *FreshBuild) lock() (*DB, error) {
	if b == nil || b.db == nil {
		return nil, closedError("fresh build")
	}
	b.db.mu.Lock()
	if b.db.closed || b.db.ptr == nil {
		b.db.mu.Unlock()
		return nil, closedError("database")
	}
	if b.ptr == nil {
		b.db.mu.Unlock()
		return nil, closedError("fresh build")
	}
	if !b.active {
		b.db.mu.Unlock()
		return nil, newError(StatusMisuse, "fresh build session is no longer active")
	}
	return b.db, nil
}

// step runs one session step. Any failure leaves the session rolled back:
// native failures roll back themselves, and abort covers failures detected
// before the native call.
func (b *FreshBuild) step(fn func(*DB, *cArena) error) error {
	db, err := b.lock()
	if err != nil {
		return err
	}
	defer db.mu.Unlock()
	var arena cArena
	defer arena.free()
	if err := fn(db, &arena); err != nil {
		C.zova_fresh_build_abort(b.ptr)
		b.active = false
		return err
	}
	return nil
}

func (a *cArena) freshValues(values []any) (*C.zova_fresh_value, error) {
	ptr := a.alloc(len(values), unsafe.Sizeof(C.zova_fresh_value{}))
	if ptr == nil {
		return nil, nil
	}
	slots := unsafe.Slice((*C.zova_fresh_value)(ptr), len(values))
	for i, value := range values {
		switch v := value.(type) {
		case nil:
			slots[i].value_type = C.ZOVA_FRESH_VALUE_NULL
		case int:
			slots[i].value_type = C.ZOVA_FRESH_VALUE_INT64
			slots[i].int64_value = C.int64_t(v)
		case int64:
			slots[i].value_type = C.ZOVA_FRESH_VALUE_INT64
			slots[i].int64_value = C.int64_t(v)
		case float64:
			slots[i].value_type = C.ZOVA_FRESH_VALUE_FLOAT64
			slots[i].float64_value = C.double(v)
		case string:
			slots[i].value_type = C.ZOVA_FRESH_VALUE_TEXT
			slots[i].bytes = a.bytes([]byte(v))
			slots[i].bytes_len = C.size_t(len(v))
		case []byte:
			slots[i].value_type = C.ZOVA_FRESH_VALUE_BLOB
			slots[i].bytes = a.bytes(v)
			slots[i].bytes_len = C.size_t(len(v))
		default:
			return nil, newError(StatusInvalidArgument, fmt.Sprintf("unsupported fresh build value type %T", value))
		}
	}
	return (*C.zova_fresh_value)(ptr), nil
}
