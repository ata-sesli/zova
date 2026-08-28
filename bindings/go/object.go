package zova

/*
#include <stdlib.h>
#include "zova.h"
*/
import "C"

import (
	"crypto/sha256"
	"unsafe"
)

// ObjectID is the SHA-256 identity of complete object bytes.
type ObjectID [32]byte

// ObjectChunkID is the SHA-256 identity of one stored object chunk.
type ObjectChunkID [32]byte

// ObjectChunk describes one object manifest row.
type ObjectChunk struct {
	Index     uint64
	Hash      ObjectChunkID
	Offset    uint64
	SizeBytes uint64
}

// ObjectManifest describes a complete Zova object manifest.
type ObjectManifest struct {
	ObjectID   ObjectID
	SizeBytes  uint64
	ChunkCount uint64
	Chunker    string
	Chunks     []ObjectChunk
}

// ObjectStorageProfile selects the physical representation used for an object.
type ObjectStorageProfile int

const (
	// ObjectStorageProfileDeduplication uses the existing FastCDC representation.
	ObjectStorageProfileDeduplication ObjectStorageProfile = C.ZOVA_OBJECT_PROFILE_DEDUPLICATION
	// ObjectStorageProfileStreaming selects fixed 1 MiB chunks in format 11.
	ObjectStorageProfileStreaming ObjectStorageProfile = C.ZOVA_OBJECT_PROFILE_STREAMING
)

// ObjectPutOptions configures a profile-aware object operation.
type ObjectPutOptions struct {
	Profile ObjectStorageProfile
}

// ObjectWriter streams bytes into Zova as a content-addressed object.
type ObjectWriter struct {
	db     *DB
	ptr    *C.zova_object_writer
	closed bool
}

// ObjectReader sequentially reads one stored object. The reader owns a native
// resource registered with its DB and must be closed when no longer needed.
type ObjectReader struct {
	db     *DB
	ptr    *C.zova_object_reader
	closed bool
}

// ObjectIDFor returns the Zova object id for bytes.
func ObjectIDFor(bytes []byte) ObjectID {
	return ObjectID(sha256.Sum256(bytes))
}

// ObjectChunkIDFor returns the Zova chunk id for bytes.
func ObjectChunkIDFor(bytes []byte) ObjectChunkID {
	return ObjectChunkID(sha256.Sum256(bytes))
}

// PutObject stores bytes as a complete content-addressed object.
func (db *DB) PutObject(bytes []byte) (ObjectID, error) {
	data, cleanup := cBytes(bytes)
	defer cleanup()

	out := (*C.zova_object_id)(C.calloc(1, C.size_t(unsafe.Sizeof(C.zova_object_id{}))))
	defer C.free(unsafe.Pointer(out))
	err := db.withLock(func() error {
		request := C.zova_object_put_request{
			db:     db.ptr,
			data:   data,
			len:    C.size_t(len(bytes)),
			out_id: out,
		}
		return statusFromDB(db, C.zova_object_put(&request))
	})
	return objectIDFromC(*out), err
}

// PutObjectWithOptions stores bytes using an explicitly selected profile.
func (db *DB) PutObjectWithOptions(bytes []byte, options ObjectPutOptions) (ObjectID, error) {
	data, cleanup := cBytes(bytes)
	defer cleanup()

	out := (*C.zova_object_id)(C.calloc(1, C.size_t(unsafe.Sizeof(C.zova_object_id{}))))
	defer C.free(unsafe.Pointer(out))
	err := db.withLock(func() error {
		request := C.zova_object_put_with_options_request{
			db:   db.ptr,
			data: data,
			len:  C.size_t(len(bytes)),
			options: C.zova_object_put_options{
				profile: C.int(options.Profile),
			},
			out_id: out,
		}
		return statusFromDB(db, C.zova_object_put_with_options(&request))
	})
	return objectIDFromC(*out), err
}

// GetObject returns full object bytes.
func (db *DB) GetObject(id ObjectID) ([]byte, error) {
	buffer := newCBuffer()
	defer freeCBuffer(buffer)
	err := db.withLock(func() error {
		request := C.zova_object_get_request{
			db:         db.ptr,
			id:         id.toC(),
			out_buffer: buffer,
		}
		return statusFromDB(db, C.zova_object_get(&request))
	})
	if err != nil {
		return nil, err
	}
	return copyBuffer(buffer), nil
}

// ReadObjectRange copies object bytes into buffer starting at offset.
func (db *DB) ReadObjectRange(id ObjectID, offset uint64, buffer []byte) (int, error) {
	var data *C.uint8_t
	if len(buffer) != 0 {
		data = (*C.uint8_t)(C.malloc(C.size_t(len(buffer))))
		defer C.free(unsafe.Pointer(data))
	}
	outCopied := (*C.size_t)(C.calloc(1, C.size_t(unsafe.Sizeof(C.size_t(0)))))
	defer C.free(unsafe.Pointer(outCopied))

	err := db.withLock(func() error {
		request := C.zova_object_read_range_request{
			db:         db.ptr,
			id:         id.toC(),
			offset:     C.uint64_t(offset),
			buffer:     data,
			buffer_len: C.size_t(len(buffer)),
			out_copied: outCopied,
		}
		return statusFromDB(db, C.zova_object_read_range(&request))
	})
	if err != nil {
		return 0, err
	}
	copied := int(*outCopied)
	if copied != 0 {
		copy(buffer, unsafe.Slice((*byte)(unsafe.Pointer(data)), copied))
	}
	return copied, nil
}

// HasObject reports whether id exists.
func (db *DB) HasObject(id ObjectID) (bool, error) {
	out := (*C.uint8_t)(C.calloc(1, C.size_t(unsafe.Sizeof(C.uint8_t(0)))))
	defer C.free(unsafe.Pointer(out))
	err := db.withLock(func() error {
		request := C.zova_object_exists_request{
			db:         db.ptr,
			id:         id.toC(),
			out_exists: out,
		}
		return statusFromDB(db, C.zova_object_exists(&request))
	})
	return *out != 0, err
}

// ObjectSize returns the stored logical object size.
func (db *DB) ObjectSize(id ObjectID) (uint64, error) {
	out := (*C.uint64_t)(C.calloc(1, C.size_t(unsafe.Sizeof(C.uint64_t(0)))))
	defer C.free(unsafe.Pointer(out))
	err := db.withLock(func() error {
		request := C.zova_object_size_request{
			db:       db.ptr,
			id:       id.toC(),
			out_size: out,
		}
		return statusFromDB(db, C.zova_object_size(&request))
	})
	return uint64(*out), err
}

// ObjectChunkCount returns the number of manifest chunks for id.
func (db *DB) ObjectChunkCount(id ObjectID) (uint64, error) {
	out := (*C.uint64_t)(C.calloc(1, C.size_t(unsafe.Sizeof(C.uint64_t(0)))))
	defer C.free(unsafe.Pointer(out))
	err := db.withLock(func() error {
		request := C.zova_object_chunk_count_request{
			db:        db.ptr,
			id:        id.toC(),
			out_count: out,
		}
		return statusFromDB(db, C.zova_object_chunk_count(&request))
	})
	return uint64(*out), err
}

// DeleteObject deletes one object and garbage-collects unreferenced chunks.
func (db *DB) DeleteObject(id ObjectID) error {
	return db.withLock(func() error {
		request := C.zova_object_delete_request{
			db: db.ptr,
			id: id.toC(),
		}
		return statusFromDB(db, C.zova_object_delete(&request))
	})
}

// ObjectManifest returns the manifest for id.
func (db *DB) ObjectManifest(id ObjectID) (ObjectManifest, error) {
	manifest := (*C.zova_object_manifest)(C.calloc(1, C.size_t(unsafe.Sizeof(C.zova_object_manifest{}))))
	defer func() {
		C.zova_object_manifest_free(manifest)
		C.free(unsafe.Pointer(manifest))
	}()
	err := db.withLock(func() error {
		request := C.zova_object_manifest_get_request{
			db:           db.ptr,
			id:           id.toC(),
			out_manifest: manifest,
		}
		return statusFromDB(db, C.zova_object_manifest_get(&request))
	})
	if err != nil {
		return ObjectManifest{}, err
	}
	return copyManifest(manifest), nil
}

// GetObjectChunk returns stored chunk bytes.
func (db *DB) GetObjectChunk(hash ObjectChunkID) ([]byte, error) {
	buffer := newCBuffer()
	defer freeCBuffer(buffer)
	err := db.withLock(func() error {
		request := C.zova_object_chunk_get_request{
			db:         db.ptr,
			hash:       hash.toC(),
			out_buffer: buffer,
		}
		return statusFromDB(db, C.zova_object_chunk_get(&request))
	})
	if err != nil {
		return nil, err
	}
	return copyBuffer(buffer), nil
}

// HasObjectChunk reports whether hash exists in chunk storage.
func (db *DB) HasObjectChunk(hash ObjectChunkID) (bool, error) {
	_, err := db.GetObjectChunk(hash)
	if err != nil {
		if errorStatusIs(err, StatusObjectChunkNotFound) {
			return false, nil
		}
		return false, err
	}
	return true, nil
}

// PutObjectChunk stores one verified loose chunk.
func (db *DB) PutObjectChunk(hash ObjectChunkID, bytes []byte) error {
	data, cleanup := cBytes(bytes)
	defer cleanup()
	return db.withLock(func() error {
		request := C.zova_object_chunk_put_request{
			db:            db.ptr,
			expected_hash: hash.toC(),
			data:          data,
			len:           C.size_t(len(bytes)),
		}
		return statusFromDB(db, C.zova_object_chunk_put(&request))
	})
}

// PutObjectChunkWithOptions stores one verified loose chunk using an
// explicitly selected profile.
func (db *DB) PutObjectChunkWithOptions(hash ObjectChunkID, bytes []byte, options ObjectPutOptions) error {
	data, cleanup := cBytes(bytes)
	defer cleanup()
	return db.withLock(func() error {
		request := C.zova_object_chunk_put_with_options_request{
			db:            db.ptr,
			expected_hash: hash.toC(),
			data:          data,
			len:           C.size_t(len(bytes)),
			options: C.zova_object_put_options{
				profile: C.int(options.Profile),
			},
		}
		return statusFromDB(db, C.zova_object_chunk_put_with_options(&request))
	})
}

// DeleteObjectChunk deletes one unreferenced loose chunk.
func (db *DB) DeleteObjectChunk(hash ObjectChunkID) (bool, error) {
	out := (*C.uint8_t)(C.calloc(1, C.size_t(unsafe.Sizeof(C.uint8_t(0)))))
	defer C.free(unsafe.Pointer(out))
	err := db.withLock(func() error {
		request := C.zova_object_chunk_delete_request{
			db:          db.ptr,
			hash:        hash.toC(),
			out_deleted: out,
		}
		return statusFromDB(db, C.zova_object_chunk_delete(&request))
	})
	return *out != 0, err
}

// AssembleObjectFromChunks assembles an object from already stored chunks.
func (db *DB) AssembleObjectFromChunks(id ObjectID, sizeBytes uint64, chunks []ObjectChunk) error {
	cChunks, cleanup := cManifestChunks(chunks)
	defer cleanup()
	return db.withLock(func() error {
		request := C.zova_object_assemble_from_chunks_request{
			db:          db.ptr,
			id:          id.toC(),
			size_bytes:  C.uint64_t(sizeBytes),
			chunks:      cChunks,
			chunk_count: C.size_t(len(chunks)),
		}
		return statusFromDB(db, C.zova_object_assemble_from_chunks(&request))
	})
}

// AssembleObjectFromChunksWithOptions assembles an object using an explicitly
// selected profile.
func (db *DB) AssembleObjectFromChunksWithOptions(id ObjectID, sizeBytes uint64, chunks []ObjectChunk, options ObjectPutOptions) error {
	cChunks, cleanup := cManifestChunks(chunks)
	defer cleanup()
	return db.withLock(func() error {
		request := C.zova_object_assemble_from_chunks_with_options_request{
			db:          db.ptr,
			id:          id.toC(),
			size_bytes:  C.uint64_t(sizeBytes),
			chunks:      cChunks,
			chunk_count: C.size_t(len(chunks)),
			options: C.zova_object_put_options{
				profile: C.int(options.Profile),
			},
		}
		return statusFromDB(db, C.zova_object_assemble_from_chunks_with_options(&request))
	})
}

// ObjectWriter creates a streaming object writer.
func (db *DB) ObjectWriter() (*ObjectWriter, error) {
	var writer *ObjectWriter
	err := db.withLock(func() error {
		outRaw := (**C.zova_object_writer)(C.calloc(1, C.size_t(unsafe.Sizeof(uintptr(0)))))
		defer C.free(unsafe.Pointer(outRaw))
		request := C.zova_object_writer_create_request{
			db:         db.ptr,
			out_writer: outRaw,
		}
		if err := statusFromDB(db, C.zova_object_writer_create(&request)); err != nil {
			return err
		}
		raw := *outRaw
		if raw == nil {
			return newError(StatusInvalidArgument, "Zova returned a nil object writer handle")
		}
		writer = &ObjectWriter{db: db, ptr: raw}
		db.writers[writer] = struct{}{}
		return nil
	})
	return writer, err
}

// ObjectWriterWithOptions creates a streaming writer using an explicitly
// selected profile.
func (db *DB) ObjectWriterWithOptions(options ObjectPutOptions) (*ObjectWriter, error) {
	var writer *ObjectWriter
	err := db.withLock(func() error {
		outRaw := (**C.zova_object_writer)(C.calloc(1, C.size_t(unsafe.Sizeof(uintptr(0)))))
		defer C.free(unsafe.Pointer(outRaw))
		request := C.zova_object_writer_create_with_options_request{
			db: db.ptr,
			options: C.zova_object_put_options{
				profile: C.int(options.Profile),
			},
			out_writer: outRaw,
		}
		if err := statusFromDB(db, C.zova_object_writer_create_with_options(&request)); err != nil {
			return err
		}
		raw := *outRaw
		if raw == nil {
			return newError(StatusInvalidArgument, "Zova returned a nil object writer handle")
		}
		writer = &ObjectWriter{db: db, ptr: raw}
		db.writers[writer] = struct{}{}
		return nil
	})
	return writer, err
}

// ObjectReader opens a sequential reader for one stored object.
func (db *DB) ObjectReader(id ObjectID) (*ObjectReader, error) {
	var reader *ObjectReader
	err := db.withLock(func() error {
		outRaw := (**C.zova_object_reader)(C.calloc(1, C.size_t(unsafe.Sizeof(uintptr(0)))))
		defer C.free(unsafe.Pointer(outRaw))
		request := C.zova_object_reader_create_request{
			db:         db.ptr,
			id:         id.toC(),
			out_reader: outRaw,
		}
		if err := statusFromDB(db, C.zova_object_reader_create(&request)); err != nil {
			return err
		}
		raw := *outRaw
		if raw == nil {
			return newError(StatusInvalidArgument, "Zova returned a nil object reader handle")
		}
		reader = &ObjectReader{db: db, ptr: raw}
		db.readers[reader] = struct{}{}
		return nil
	})
	return reader, err
}

// Write appends bytes to the streaming writer.
func (w *ObjectWriter) Write(bytes []byte) error {
	data, cleanup := cBytes(bytes)
	defer cleanup()
	return w.withLock(func(db *DB) error {
		request := C.zova_object_writer_write_request{
			writer: w.ptr,
			data:   data,
			len:    C.size_t(len(bytes)),
		}
		return statusFromDB(db, C.zova_object_writer_write(&request))
	})
}

// Finish closes the writer and returns the final object id.
func (w *ObjectWriter) Finish() (ObjectID, error) {
	out := (*C.zova_object_id)(C.calloc(1, C.size_t(unsafe.Sizeof(C.zova_object_id{}))))
	defer C.free(unsafe.Pointer(out))
	err := w.withLock(func(db *DB) error {
		request := C.zova_object_writer_finish_request{
			writer: w.ptr,
			out_id: out,
		}
		if err := statusFromDB(db, C.zova_object_writer_finish(&request)); err != nil {
			return err
		}
		w.destroyLocked(db)
		return nil
	})
	return objectIDFromC(*out), err
}

// Cancel cancels the writer and cleans unreferenced chunks it wrote.
func (w *ObjectWriter) Cancel() error {
	return w.withLock(func(db *DB) error {
		request := C.zova_object_writer_cancel_request{writer: w.ptr}
		if err := statusFromDB(db, C.zova_object_writer_cancel(&request)); err != nil {
			return err
		}
		w.destroyLocked(db)
		return nil
	})
}

// Close destroys the writer. Unfinished writers are cancelled by Zova.
func (w *ObjectWriter) Close() error {
	return w.withLock(func(db *DB) error {
		return w.destroyLocked(db)
	})
}

func (w *ObjectWriter) lock() (*DB, error) {
	if w == nil || w.db == nil {
		return nil, newError(StatusObjectWriterClosed, "object writer is closed")
	}
	w.db.mu.Lock()
	if w.db.closed || w.db.ptr == nil {
		w.db.mu.Unlock()
		return nil, closedError("database")
	}
	if w.closed || w.ptr == nil {
		w.db.mu.Unlock()
		return nil, newError(StatusObjectWriterClosed, "object writer is closed")
	}
	return w.db, nil
}

func (w *ObjectWriter) withLock(fn func(*DB) error) error {
	db, err := w.lock()
	if err != nil {
		return err
	}
	defer db.mu.Unlock()
	return fn(db)
}

func (w *ObjectWriter) destroyLocked(db *DB) error {
	status := C.zova_object_writer_destroy(w.ptr)
	w.ptr = nil
	w.closed = true
	delete(db.writers, w)
	return statusFromDB(db, status)
}

// Read copies up to len(buffer) bytes and advances the reader. A zero return
// with no error indicates verified end-of-object.
func (r *ObjectReader) Read(buffer []byte) (int, error) {
	if r == nil || r.db == nil {
		return 0, newError(StatusObjectReaderClosed, "object reader is closed")
	}
	if r.closed || r.ptr == nil {
		return 0, newError(StatusObjectReaderClosed, "object reader is closed")
	}
	var data *C.uint8_t
	if len(buffer) != 0 {
		data = (*C.uint8_t)(C.malloc(C.size_t(len(buffer))))
		if data == nil {
			return 0, newError(StatusOutOfMemory, "could not allocate object reader buffer")
		}
		defer C.free(unsafe.Pointer(data))
	}
	outRead := (*C.size_t)(C.calloc(1, C.size_t(unsafe.Sizeof(C.size_t(0)))))
	if outRead == nil {
		return 0, newError(StatusOutOfMemory, "could not allocate object reader output")
	}
	defer C.free(unsafe.Pointer(outRead))
	err := r.db.withLock(func() error {
		if r.closed || r.ptr == nil {
			return newError(StatusObjectReaderClosed, "object reader is closed")
		}
		request := C.zova_object_reader_read_request{
			reader:     r.ptr,
			buffer:     data,
			buffer_len: C.size_t(len(buffer)),
			out_read:   outRead,
		}
		return statusFromDB(r.db, C.zova_object_reader_read(&request))
	})
	if err != nil {
		return 0, err
	}
	read := int(*outRead)
	if read != 0 {
		copy(buffer, unsafe.Slice((*byte)(unsafe.Pointer(data)), read))
	}
	return read, nil
}

// Close destroys the reader. Repeated calls are successful no-ops.
func (r *ObjectReader) Close() error {
	if r == nil || r.db == nil || r.closed || r.ptr == nil {
		return nil
	}
	db, err := r.lock()
	if err != nil {
		return err
	}
	defer db.mu.Unlock()
	raw := (**C.zova_object_reader)(C.malloc(C.size_t(unsafe.Sizeof(uintptr(0)))))
	if raw == nil {
		return newError(StatusOutOfMemory, "could not allocate object reader destroy request")
	}
	*raw = r.ptr
	defer C.free(unsafe.Pointer(raw))
	request := C.zova_object_reader_destroy_request{reader: raw}
	status := C.zova_object_reader_destroy(&request)
	if err := statusFromDB(db, status); err != nil {
		return err
	}
	r.ptr = nil
	r.closed = true
	delete(db.readers, r)
	return nil
}

func (r *ObjectReader) lock() (*DB, error) {
	if r == nil || r.db == nil || r.closed || r.ptr == nil {
		return nil, newError(StatusObjectReaderClosed, "object reader is closed")
	}
	r.db.mu.Lock()
	if r.db.closed || r.db.ptr == nil {
		r.db.mu.Unlock()
		return nil, closedError("database")
	}
	if r.closed || r.ptr == nil {
		r.db.mu.Unlock()
		return nil, newError(StatusObjectReaderClosed, "object reader is closed")
	}
	return r.db, nil
}

func (id ObjectID) toC() C.zova_object_id {
	var out C.zova_object_id
	for i := 0; i < 32; i++ {
		out.bytes[i] = C.uint8_t(id[i])
	}
	return out
}

func objectIDFromC(id C.zova_object_id) ObjectID {
	var out ObjectID
	for i := 0; i < 32; i++ {
		out[i] = byte(id.bytes[i])
	}
	return out
}

func (id ObjectChunkID) toC() C.zova_object_chunk_id {
	var out C.zova_object_chunk_id
	for i := 0; i < 32; i++ {
		out.bytes[i] = C.uint8_t(id[i])
	}
	return out
}

func chunkIDFromC(id C.zova_object_chunk_id) ObjectChunkID {
	var out ObjectChunkID
	for i := 0; i < 32; i++ {
		out[i] = byte(id.bytes[i])
	}
	return out
}

func cBytes(bytes []byte) (*C.uint8_t, func()) {
	if len(bytes) == 0 {
		return nil, func() {}
	}
	data := C.CBytes(bytes)
	return (*C.uint8_t)(data), func() { C.free(data) }
}

func newCBuffer() *C.zova_buffer {
	return (*C.zova_buffer)(C.calloc(1, C.size_t(unsafe.Sizeof(C.zova_buffer{}))))
}

func freeCBuffer(buffer *C.zova_buffer) {
	if buffer == nil {
		return
	}
	C.zova_buffer_free(buffer)
	C.free(unsafe.Pointer(buffer))
}

func copyBuffer(buffer *C.zova_buffer) []byte {
	if buffer == nil || buffer.len == 0 {
		return []byte{}
	}
	bytes := unsafe.Slice((*byte)(unsafe.Pointer(buffer.data)), int(buffer.len))
	return append([]byte(nil), bytes...)
}

func copyManifest(manifest *C.zova_object_manifest) ObjectManifest {
	out := ObjectManifest{
		ObjectID:   objectIDFromC(manifest.object_id),
		SizeBytes:  uint64(manifest.size_bytes),
		ChunkCount: uint64(manifest.chunk_count),
		Chunker:    C.GoString(manifest.chunker),
	}
	if manifest.chunks_len != 0 {
		cChunks := unsafe.Slice(manifest.chunks, int(manifest.chunks_len))
		out.Chunks = make([]ObjectChunk, len(cChunks))
		for i, chunk := range cChunks {
			out.Chunks[i] = ObjectChunk{
				Index:     uint64(chunk.index),
				Hash:      chunkIDFromC(chunk.hash),
				Offset:    uint64(chunk.offset),
				SizeBytes: uint64(chunk.size_bytes),
			}
		}
	}
	return out
}

func cManifestChunks(chunks []ObjectChunk) (*C.zova_object_manifest_chunk, func()) {
	if len(chunks) == 0 {
		return nil, func() {}
	}
	ptr := C.malloc(C.size_t(len(chunks)) * C.size_t(unsafe.Sizeof(C.zova_object_manifest_chunk{})))
	cChunks := unsafe.Slice((*C.zova_object_manifest_chunk)(ptr), len(chunks))
	for i, chunk := range chunks {
		cChunks[i] = C.zova_object_manifest_chunk{
			index:      C.uint64_t(chunk.Index),
			hash:       chunk.Hash.toC(),
			offset:     C.uint64_t(chunk.Offset),
			size_bytes: C.uint64_t(chunk.SizeBytes),
		}
	}
	return (*C.zova_object_manifest_chunk)(ptr), func() { C.free(ptr) }
}
