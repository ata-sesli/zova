use crate::database::{
    backup_flags, compact_flags, cstring, empty_message, path_to_cstring, take_message,
    BackupOptions, CompactOptions,
};
use crate::error::{Error, Result, Status};
use crate::object::{
    empty_buffer, empty_manifest, from_c_object_id, take_buffer, take_manifest, ObjectChunkId,
    ObjectId, ObjectManifest, ObjectManifestChunk,
};
use crate::statement::{ColumnType, Step};
use crate::vector::{
    candidate_ptrs, empty_collection_info, empty_search_results, empty_vector,
    take_collection_info, take_collection_list, take_search_results, take_vector, values_ptr,
    vector_inputs, Vector, VectorCollectionInfo, VectorCollectionOptions, VectorInput,
    VectorSearchResult,
};
use crate::OpenOptions;
use std::cell::Cell;
use std::ffi::CStr;
use std::fmt;
use std::marker::PhantomData;
use std::path::Path;
use std::ptr::{self, NonNull};
use std::sync::{Arc, Mutex, MutexGuard};

/// Cloneable, thread-safe Rust wrapper for one serialized Zova database handle.
///
/// A `SharedDatabase` is safe to use from multiple Rust threads, but calls on
/// one handle still execute one at a time. Open multiple database handles when
/// you need real SQLite concurrency.
#[derive(Clone)]
pub struct SharedDatabase {
    inner: Arc<SharedDatabaseInner>,
}

/// Owned prepared statement tied to a [`SharedDatabase`].
pub struct SharedStatement {
    raw: Option<NonNull<zova_sys::zova_statement>>,
    database: Arc<SharedDatabaseInner>,
    _not_sync: PhantomData<Cell<()>>,
}

/// Owned streaming object writer tied to a [`SharedDatabase`].
pub struct SharedObjectWriter {
    raw: Option<NonNull<zova_sys::zova_object_writer>>,
    database: Arc<SharedDatabaseInner>,
    _not_sync: PhantomData<Cell<()>>,
}

/// Scoped exclusive access to one shared database handle.
///
/// The guard keeps the Rust mutex for the lifetime of the closure passed to
/// `SharedDatabase::with_exclusive`, `transaction`, or `transaction_immediate`.
pub struct SharedDatabaseGuard<'db> {
    inner: &'db SharedDatabaseInner,
    _guard: MutexGuard<'db, ()>,
}

/// Prepared statement that borrows an exclusive shared-database guard.
pub struct SharedGuardStatement<'db> {
    raw: Option<NonNull<zova_sys::zova_statement>>,
    inner: &'db SharedDatabaseInner,
    _guard: PhantomData<&'db mut SharedDatabaseGuard<'db>>,
}

struct SharedDatabaseInner {
    raw: NonNull<zova_sys::zova_database>,
    mutex: Mutex<()>,
}

// Safety: the C ABI serializes one `zova_database` handle internally. The Rust
// mutex adds a stronger binding-level rule: the FFI call and immediate
// last-error copy happen under one Rust lock, and the raw handle is closed only
// when the last Arc-held shared database, statement, or writer is dropped.
unsafe impl Send for SharedDatabaseInner {}
unsafe impl Sync for SharedDatabaseInner {}

// Safety: methods require `&mut self`, the raw statement is used only while the
// parent database lock is held, and the parent Arc keeps the native handle alive.
unsafe impl Send for SharedStatement {}

// Safety: methods require `&mut self`, the raw writer is used only while the
// parent database lock is held, and the parent Arc keeps the native handle alive.
unsafe impl Send for SharedObjectWriter {}

impl SharedDatabase {
    pub fn create(path: impl AsRef<Path>) -> Result<Self> {
        Self::open_or_create(path, true)
    }

    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        Self::open_or_create(path, false)
    }

    pub fn open_with_options(path: impl AsRef<Path>, options: OpenOptions) -> Result<Self> {
        let path = path_to_cstring(path.as_ref())?;
        let mut db = ptr::null_mut();
        let mut message = empty_message();
        let flags = if options.read_only {
            zova_sys::ZOVA_OPEN_READ_ONLY
        } else {
            0
        };
        let request = zova_sys::zova_database_open_options_request {
            path: path.as_ptr(),
            flags,
            busy_timeout_ms: options.busy_timeout_ms,
            out_db: &mut db,
            out_error_message: &mut message,
        };
        let status = unsafe { zova_sys::zova_database_open_with_options(&request) };
        if status != zova_sys::ZOVA_OK {
            return Err(Error::from_status(status, take_message(&mut message)));
        }
        Self::from_raw(db)
    }

    pub fn convert_sqlite_to_zova(
        source: impl AsRef<Path>,
        destination: impl AsRef<Path>,
    ) -> Result<()> {
        let source = path_to_cstring(source.as_ref())?;
        let destination = path_to_cstring(destination.as_ref())?;
        let mut message = empty_message();
        let request = zova_sys::zova_convert_sqlite_to_zova_request {
            source_path: source.as_ptr(),
            dest_path: destination.as_ptr(),
            out_error_message: &mut message,
        };
        let status = unsafe { zova_sys::zova_convert_sqlite_to_zova(&request) };
        if status == zova_sys::ZOVA_OK {
            return Ok(());
        }
        Err(Error::from_status(status, take_message(&mut message)))
    }

    pub fn exec(&self, sql: &str) -> Result<()> {
        let sql = cstring(sql, "sql")?;
        let _guard = self.inner.lock();
        let request = zova_sys::zova_database_exec_request {
            db: self.inner.raw_ptr(),
            sql: sql.as_ptr(),
        };
        self.inner
            .status_locked(unsafe { zova_sys::zova_database_exec(&request) })
    }

    pub fn prepare(&self, sql: &str) -> Result<SharedStatement> {
        let sql = cstring(sql, "sql")?;
        let _guard = self.inner.lock();
        let mut statement = ptr::null_mut();
        let request = zova_sys::zova_database_prepare_request {
            db: self.inner.raw_ptr(),
            sql: sql.as_ptr(),
            out_statement: &mut statement,
        };
        self.inner
            .status_locked(unsafe { zova_sys::zova_database_prepare(&request) })?;
        let raw = NonNull::new(statement)
            .ok_or_else(|| Error::from_status(zova_sys::ZOVA_INVALID_ARGUMENT, None))?;
        Ok(SharedStatement {
            raw: Some(raw),
            database: self.inner.clone(),
            _not_sync: PhantomData,
        })
    }

    pub fn begin(&self) -> Result<()> {
        self.simple(zova_sys::zova_database_begin)
    }

    pub fn begin_immediate(&self) -> Result<()> {
        self.simple(zova_sys::zova_database_begin_immediate)
    }

    pub fn commit(&self) -> Result<()> {
        self.simple(zova_sys::zova_database_commit)
    }

    pub fn rollback(&self) -> Result<()> {
        self.simple(zova_sys::zova_database_rollback)
    }

    pub fn savepoint(&self, name: &str) -> Result<()> {
        self.savepoint_call(name, zova_sys::zova_database_savepoint)
    }

    pub fn rollback_to_savepoint(&self, name: &str) -> Result<()> {
        self.savepoint_call(name, zova_sys::zova_database_rollback_to_savepoint)
    }

    pub fn release_savepoint(&self, name: &str) -> Result<()> {
        self.savepoint_call(name, zova_sys::zova_database_release_savepoint)
    }

    pub fn vacuum(&self) -> Result<()> {
        self.simple(zova_sys::zova_database_vacuum)
    }

    pub fn backup_to(&self, destination: impl AsRef<Path>, options: BackupOptions) -> Result<()> {
        let destination = path_to_cstring(destination.as_ref())?;
        let _guard = self.inner.lock();
        let request = zova_sys::zova_database_backup_request {
            db: self.inner.raw_ptr(),
            destination_path: destination.as_ptr(),
            flags: backup_flags(options.verify),
        };
        self.inner
            .status_locked(unsafe { zova_sys::zova_database_backup(&request) })
    }

    pub fn compact_to(&self, destination: impl AsRef<Path>, options: CompactOptions) -> Result<()> {
        let destination = path_to_cstring(destination.as_ref())?;
        let _guard = self.inner.lock();
        let request = zova_sys::zova_database_compact_request {
            db: self.inner.raw_ptr(),
            destination_path: destination.as_ptr(),
            flags: compact_flags(options.verify),
        };
        self.inner
            .status_locked(unsafe { zova_sys::zova_database_compact(&request) })
    }

    pub fn set_busy_timeout(&self, milliseconds: u32) -> Result<()> {
        let _guard = self.inner.lock();
        let request = zova_sys::zova_database_busy_timeout_request {
            db: self.inner.raw_ptr(),
            milliseconds,
        };
        self.inner
            .status_locked(unsafe { zova_sys::zova_database_set_busy_timeout(&request) })
    }

    pub fn last_insert_rowid(&self) -> Result<i64> {
        let _guard = self.inner.lock();
        self.inner.last_insert_rowid_locked()
    }

    pub fn changes(&self) -> Result<i64> {
        let _guard = self.inner.lock();
        self.inner.changes_locked()
    }

    pub fn total_changes(&self) -> Result<i64> {
        let _guard = self.inner.lock();
        self.inner.total_changes_locked()
    }

    pub fn with_exclusive<T>(
        &self,
        f: impl FnOnce(&mut SharedDatabaseGuard<'_>) -> Result<T>,
    ) -> Result<T> {
        let guard = self.inner.lock();
        let mut database = SharedDatabaseGuard {
            inner: &self.inner,
            _guard: guard,
        };
        f(&mut database)
    }

    pub fn transaction<T>(
        &self,
        f: impl FnOnce(&mut SharedDatabaseGuard<'_>) -> Result<T>,
    ) -> Result<T> {
        self.transaction_with(zova_sys::zova_database_begin, f)
    }

    pub fn transaction_immediate<T>(
        &self,
        f: impl FnOnce(&mut SharedDatabaseGuard<'_>) -> Result<T>,
    ) -> Result<T> {
        self.transaction_with(zova_sys::zova_database_begin_immediate, f)
    }

    pub fn put_object(&self, bytes: &[u8]) -> Result<ObjectId> {
        let _guard = self.inner.lock();
        let mut out = zova_sys::zova_object_id { bytes: [0; 32] };
        let request = zova_sys::zova_object_put_request {
            db: self.inner.raw_ptr(),
            data: bytes.as_ptr(),
            len: bytes.len(),
            out_id: &mut out,
        };
        self.inner
            .status_locked(unsafe { zova_sys::zova_object_put(&request) })?;
        Ok(from_c_object_id(out))
    }

    pub fn get_object(&self, id: ObjectId) -> Result<Vec<u8>> {
        let _guard = self.inner.lock();
        let mut buffer = empty_buffer();
        let request = zova_sys::zova_object_get_request {
            db: self.inner.raw_ptr(),
            id: id.to_c(),
            out_buffer: &mut buffer,
        };
        self.inner
            .status_locked(unsafe { zova_sys::zova_object_get(&request) })?;
        Ok(take_buffer(&mut buffer))
    }

    pub fn read_object_range(&self, id: ObjectId, offset: u64, buffer: &mut [u8]) -> Result<usize> {
        let _guard = self.inner.lock();
        let mut copied = 0;
        let request = zova_sys::zova_object_read_range_request {
            db: self.inner.raw_ptr(),
            id: id.to_c(),
            offset,
            buffer: buffer.as_mut_ptr(),
            buffer_len: buffer.len(),
            out_copied: &mut copied,
        };
        self.inner
            .status_locked(unsafe { zova_sys::zova_object_read_range(&request) })?;
        Ok(copied)
    }

    pub fn has_object(&self, id: ObjectId) -> Result<bool> {
        let _guard = self.inner.lock();
        let mut exists = 0;
        let request = zova_sys::zova_object_exists_request {
            db: self.inner.raw_ptr(),
            id: id.to_c(),
            out_exists: &mut exists,
        };
        self.inner
            .status_locked(unsafe { zova_sys::zova_object_exists(&request) })?;
        Ok(exists != 0)
    }

    pub fn object_size(&self, id: ObjectId) -> Result<u64> {
        let _guard = self.inner.lock();
        let mut size = 0;
        let request = zova_sys::zova_object_size_request {
            db: self.inner.raw_ptr(),
            id: id.to_c(),
            out_size: &mut size,
        };
        self.inner
            .status_locked(unsafe { zova_sys::zova_object_size(&request) })?;
        Ok(size)
    }

    pub fn object_chunk_count(&self, id: ObjectId) -> Result<u64> {
        let _guard = self.inner.lock();
        let mut count = 0;
        let request = zova_sys::zova_object_chunk_count_request {
            db: self.inner.raw_ptr(),
            id: id.to_c(),
            out_count: &mut count,
        };
        self.inner
            .status_locked(unsafe { zova_sys::zova_object_chunk_count(&request) })?;
        Ok(count)
    }

    pub fn delete_object(&self, id: ObjectId) -> Result<()> {
        let _guard = self.inner.lock();
        let request = zova_sys::zova_object_delete_request {
            db: self.inner.raw_ptr(),
            id: id.to_c(),
        };
        self.inner
            .status_locked(unsafe { zova_sys::zova_object_delete(&request) })
    }

    pub fn object_manifest(&self, id: ObjectId) -> Result<ObjectManifest> {
        let _guard = self.inner.lock();
        let mut manifest = empty_manifest();
        let request = zova_sys::zova_object_manifest_get_request {
            db: self.inner.raw_ptr(),
            id: id.to_c(),
            out_manifest: &mut manifest,
        };
        self.inner
            .status_locked(unsafe { zova_sys::zova_object_manifest_get(&request) })?;
        Ok(take_manifest(&mut manifest))
    }

    pub fn get_object_chunk(&self, hash: ObjectChunkId) -> Result<Vec<u8>> {
        let _guard = self.inner.lock();
        let mut buffer = empty_buffer();
        let request = zova_sys::zova_object_chunk_get_request {
            db: self.inner.raw_ptr(),
            hash: hash.to_c(),
            out_buffer: &mut buffer,
        };
        self.inner
            .status_locked(unsafe { zova_sys::zova_object_chunk_get(&request) })?;
        Ok(take_buffer(&mut buffer))
    }

    pub fn has_object_chunk(&self, hash: ObjectChunkId) -> Result<bool> {
        match self.get_object_chunk(hash) {
            Ok(_) => Ok(true),
            Err(error) if error.status() == Some(Status::ObjectChunkNotFound) => Ok(false),
            Err(error) => Err(error),
        }
    }

    pub fn put_object_chunk(&self, expected_hash: ObjectChunkId, bytes: &[u8]) -> Result<()> {
        let _guard = self.inner.lock();
        let request = zova_sys::zova_object_chunk_put_request {
            db: self.inner.raw_ptr(),
            expected_hash: expected_hash.to_c(),
            data: bytes.as_ptr(),
            len: bytes.len(),
        };
        self.inner
            .status_locked(unsafe { zova_sys::zova_object_chunk_put(&request) })
    }

    pub fn delete_object_chunk(&self, hash: ObjectChunkId) -> Result<bool> {
        let _guard = self.inner.lock();
        let mut deleted = 0;
        let request = zova_sys::zova_object_chunk_delete_request {
            db: self.inner.raw_ptr(),
            hash: hash.to_c(),
            out_deleted: &mut deleted,
        };
        self.inner
            .status_locked(unsafe { zova_sys::zova_object_chunk_delete(&request) })?;
        Ok(deleted != 0)
    }

    pub fn assemble_object_from_chunks(
        &self,
        id: ObjectId,
        size_bytes: u64,
        chunks: &[ObjectManifestChunk],
    ) -> Result<()> {
        let c_chunks: Vec<_> = chunks.iter().map(ObjectManifestChunk::to_c).collect();
        let _guard = self.inner.lock();
        let request = zova_sys::zova_object_assemble_from_chunks_request {
            db: self.inner.raw_ptr(),
            id: id.to_c(),
            size_bytes,
            chunks: c_chunks.as_ptr(),
            chunk_count: c_chunks.len(),
        };
        self.inner
            .status_locked(unsafe { zova_sys::zova_object_assemble_from_chunks(&request) })
    }

    pub fn object_writer(&self) -> Result<SharedObjectWriter> {
        let _guard = self.inner.lock();
        let mut writer = ptr::null_mut();
        let request = zova_sys::zova_object_writer_create_request {
            db: self.inner.raw_ptr(),
            out_writer: &mut writer,
        };
        self.inner
            .status_locked(unsafe { zova_sys::zova_object_writer_create(&request) })?;
        let raw = NonNull::new(writer)
            .ok_or_else(|| Error::from_status(zova_sys::ZOVA_INVALID_ARGUMENT, None))?;
        Ok(SharedObjectWriter {
            raw: Some(raw),
            database: self.inner.clone(),
            _not_sync: PhantomData,
        })
    }

    pub fn create_vector_collection(
        &self,
        name: &str,
        options: VectorCollectionOptions,
    ) -> Result<()> {
        let name = cstring(name, "vector collection name")?;
        let _guard = self.inner.lock();
        let request = zova_sys::zova_vector_collection_create_request {
            db: self.inner.raw_ptr(),
            name: name.as_ptr(),
            options: zova_sys::zova_vector_collection_options {
                dimensions: options.dimensions,
                metric: options.metric.to_c(),
            },
        };
        self.inner
            .status_locked(unsafe { zova_sys::zova_vector_collection_create(&request) })
    }

    pub fn has_vector_collection(&self, name: &str) -> Result<bool> {
        let name = cstring(name, "vector collection name")?;
        let _guard = self.inner.lock();
        let mut exists = 0;
        let request = zova_sys::zova_vector_collection_exists_request {
            db: self.inner.raw_ptr(),
            name: name.as_ptr(),
            out_exists: &mut exists,
        };
        self.inner
            .status_locked(unsafe { zova_sys::zova_vector_collection_exists(&request) })?;
        Ok(exists != 0)
    }

    pub fn vector_collection_info(&self, name: &str) -> Result<VectorCollectionInfo> {
        let name = cstring(name, "vector collection name")?;
        let _guard = self.inner.lock();
        let mut info = empty_collection_info();
        let request = zova_sys::zova_vector_collection_info_get_request {
            db: self.inner.raw_ptr(),
            name: name.as_ptr(),
            out_info: &mut info,
        };
        self.inner
            .status_locked(unsafe { zova_sys::zova_vector_collection_info_get(&request) })?;
        take_collection_info(&mut info)
    }

    pub fn list_vector_collections(&self) -> Result<Vec<VectorCollectionInfo>> {
        let _guard = self.inner.lock();
        let mut list = zova_sys::zova_vector_collection_list {
            items: ptr::null_mut(),
            len: 0,
        };
        let request = zova_sys::zova_vector_collections_list_request {
            db: self.inner.raw_ptr(),
            out_list: &mut list,
        };
        self.inner
            .status_locked(unsafe { zova_sys::zova_vector_collections_list(&request) })?;
        take_collection_list(&mut list)
    }

    pub fn delete_vector_collection(&self, name: &str) -> Result<()> {
        let name = cstring(name, "vector collection name")?;
        let _guard = self.inner.lock();
        let request = zova_sys::zova_vector_collection_delete_request {
            db: self.inner.raw_ptr(),
            name: name.as_ptr(),
        };
        self.inner
            .status_locked(unsafe { zova_sys::zova_vector_collection_delete(&request) })
    }

    pub fn put_vector(&self, collection_name: &str, vector_id: &str, values: &[f32]) -> Result<()> {
        let collection_name = cstring(collection_name, "vector collection name")?;
        let vector_id = cstring(vector_id, "vector id")?;
        let _guard = self.inner.lock();
        let request = zova_sys::zova_vector_put_request {
            db: self.inner.raw_ptr(),
            collection_name: collection_name.as_ptr(),
            vector_id: vector_id.as_ptr(),
            values: values_ptr(values),
            values_len: values.len(),
        };
        self.inner
            .status_locked(unsafe { zova_sys::zova_vector_put(&request) })
    }

    pub fn put_vectors(&self, collection_name: &str, vectors: &[VectorInput<'_>]) -> Result<()> {
        let collection_name = cstring(collection_name, "vector collection name")?;
        let (ids, inputs) = vector_inputs(vectors)?;
        let _guard = self.inner.lock();
        let request = zova_sys::zova_vector_put_many_request {
            db: self.inner.raw_ptr(),
            collection_name: collection_name.as_ptr(),
            vectors: if inputs.is_empty() {
                ptr::null()
            } else {
                inputs.as_ptr()
            },
            vectors_len: inputs.len(),
        };
        let result = self
            .inner
            .status_locked(unsafe { zova_sys::zova_vector_put_many(&request) });
        drop(ids);
        result
    }

    pub fn get_vector(&self, collection_name: &str, vector_id: &str) -> Result<Vector> {
        let collection_name = cstring(collection_name, "vector collection name")?;
        let vector_id = cstring(vector_id, "vector id")?;
        let _guard = self.inner.lock();
        let mut vector = empty_vector();
        let request = zova_sys::zova_vector_get_request {
            db: self.inner.raw_ptr(),
            collection_name: collection_name.as_ptr(),
            vector_id: vector_id.as_ptr(),
            out_vector: &mut vector,
        };
        self.inner
            .status_locked(unsafe { zova_sys::zova_vector_get(&request) })?;
        take_vector(&mut vector)
    }

    pub fn has_vector(&self, collection_name: &str, vector_id: &str) -> Result<bool> {
        let collection_name = cstring(collection_name, "vector collection name")?;
        let vector_id = cstring(vector_id, "vector id")?;
        let _guard = self.inner.lock();
        let mut exists = 0;
        let request = zova_sys::zova_vector_exists_request {
            db: self.inner.raw_ptr(),
            collection_name: collection_name.as_ptr(),
            vector_id: vector_id.as_ptr(),
            out_exists: &mut exists,
        };
        self.inner
            .status_locked(unsafe { zova_sys::zova_vector_exists(&request) })?;
        Ok(exists != 0)
    }

    pub fn delete_vector(&self, collection_name: &str, vector_id: &str) -> Result<()> {
        let collection_name = cstring(collection_name, "vector collection name")?;
        let vector_id = cstring(vector_id, "vector id")?;
        let _guard = self.inner.lock();
        let request = zova_sys::zova_vector_delete_request {
            db: self.inner.raw_ptr(),
            collection_name: collection_name.as_ptr(),
            vector_id: vector_id.as_ptr(),
        };
        self.inner
            .status_locked(unsafe { zova_sys::zova_vector_delete(&request) })
    }

    pub fn search_vectors(
        &self,
        collection_name: &str,
        query: &[f32],
        limit: usize,
    ) -> Result<Vec<VectorSearchResult>> {
        let collection_name = cstring(collection_name, "vector collection name")?;
        let _guard = self.inner.lock();
        let mut results = empty_search_results();
        let request = zova_sys::zova_vector_search_request {
            db: self.inner.raw_ptr(),
            collection_name: collection_name.as_ptr(),
            query: values_ptr(query),
            query_len: query.len(),
            limit,
            out_results: &mut results,
        };
        self.inner
            .status_locked(unsafe { zova_sys::zova_vector_search(&request) })?;
        take_search_results(&mut results)
    }

    pub fn search_vectors_in(
        &self,
        collection_name: &str,
        query: &[f32],
        candidate_ids: &[&str],
        limit: usize,
    ) -> Result<Vec<VectorSearchResult>> {
        let collection_name = cstring(collection_name, "vector collection name")?;
        let (candidates, candidate_ptrs) = candidate_ptrs(candidate_ids)?;
        let _guard = self.inner.lock();
        let mut results = empty_search_results();
        let request = zova_sys::zova_vector_search_in_request {
            db: self.inner.raw_ptr(),
            collection_name: collection_name.as_ptr(),
            query: values_ptr(query),
            query_len: query.len(),
            candidate_ids: if candidate_ptrs.is_empty() {
                ptr::null()
            } else {
                candidate_ptrs.as_ptr()
            },
            candidate_count: candidate_ptrs.len(),
            limit,
            out_results: &mut results,
        };
        let status = self
            .inner
            .status_locked(unsafe { zova_sys::zova_vector_search_in(&request) });
        drop(candidates);
        status?;
        take_search_results(&mut results)
    }

    pub fn search_vectors_within(
        &self,
        collection_name: &str,
        query: &[f32],
        max_distance: f64,
        limit: usize,
    ) -> Result<Vec<VectorSearchResult>> {
        let collection_name = cstring(collection_name, "vector collection name")?;
        let _guard = self.inner.lock();
        let mut results = empty_search_results();
        let request = zova_sys::zova_vector_search_within_request {
            db: self.inner.raw_ptr(),
            collection_name: collection_name.as_ptr(),
            query: values_ptr(query),
            query_len: query.len(),
            max_distance,
            limit,
            out_results: &mut results,
        };
        self.inner
            .status_locked(unsafe { zova_sys::zova_vector_search_within(&request) })?;
        take_search_results(&mut results)
    }

    pub fn search_vectors_in_within(
        &self,
        collection_name: &str,
        query: &[f32],
        candidate_ids: &[&str],
        max_distance: f64,
        limit: usize,
    ) -> Result<Vec<VectorSearchResult>> {
        let collection_name = cstring(collection_name, "vector collection name")?;
        let (candidates, candidate_ptrs) = candidate_ptrs(candidate_ids)?;
        let _guard = self.inner.lock();
        let mut results = empty_search_results();
        let request = zova_sys::zova_vector_search_in_within_request {
            db: self.inner.raw_ptr(),
            collection_name: collection_name.as_ptr(),
            query: values_ptr(query),
            query_len: query.len(),
            candidate_ids: if candidate_ptrs.is_empty() {
                ptr::null()
            } else {
                candidate_ptrs.as_ptr()
            },
            candidate_count: candidate_ptrs.len(),
            max_distance,
            limit,
            out_results: &mut results,
        };
        let status = self
            .inner
            .status_locked(unsafe { zova_sys::zova_vector_search_in_within(&request) });
        drop(candidates);
        status?;
        take_search_results(&mut results)
    }

    pub fn search_vectors_by_id(
        &self,
        collection_name: &str,
        source_vector_id: &str,
        limit: usize,
    ) -> Result<Vec<VectorSearchResult>> {
        let collection_name = cstring(collection_name, "vector collection name")?;
        let source_vector_id = cstring(source_vector_id, "source vector id")?;
        let _guard = self.inner.lock();
        let mut results = empty_search_results();
        let request = zova_sys::zova_vector_search_by_id_request {
            db: self.inner.raw_ptr(),
            collection_name: collection_name.as_ptr(),
            source_vector_id: source_vector_id.as_ptr(),
            limit,
            out_results: &mut results,
        };
        self.inner
            .status_locked(unsafe { zova_sys::zova_vector_search_by_id(&request) })?;
        take_search_results(&mut results)
    }

    pub fn search_vectors_by_id_in(
        &self,
        collection_name: &str,
        source_vector_id: &str,
        candidate_ids: &[&str],
        limit: usize,
    ) -> Result<Vec<VectorSearchResult>> {
        let collection_name = cstring(collection_name, "vector collection name")?;
        let source_vector_id = cstring(source_vector_id, "source vector id")?;
        let (candidates, candidate_ptrs) = candidate_ptrs(candidate_ids)?;
        let _guard = self.inner.lock();
        let mut results = empty_search_results();
        let request = zova_sys::zova_vector_search_by_id_in_request {
            db: self.inner.raw_ptr(),
            collection_name: collection_name.as_ptr(),
            source_vector_id: source_vector_id.as_ptr(),
            candidate_ids: if candidate_ptrs.is_empty() {
                ptr::null()
            } else {
                candidate_ptrs.as_ptr()
            },
            candidate_count: candidate_ptrs.len(),
            limit,
            out_results: &mut results,
        };
        let status = self
            .inner
            .status_locked(unsafe { zova_sys::zova_vector_search_by_id_in(&request) });
        drop(candidates);
        status?;
        take_search_results(&mut results)
    }

    pub fn search_vectors_by_id_within(
        &self,
        collection_name: &str,
        source_vector_id: &str,
        max_distance: f64,
        limit: usize,
    ) -> Result<Vec<VectorSearchResult>> {
        let collection_name = cstring(collection_name, "vector collection name")?;
        let source_vector_id = cstring(source_vector_id, "source vector id")?;
        let _guard = self.inner.lock();
        let mut results = empty_search_results();
        let request = zova_sys::zova_vector_search_by_id_within_request {
            db: self.inner.raw_ptr(),
            collection_name: collection_name.as_ptr(),
            source_vector_id: source_vector_id.as_ptr(),
            max_distance,
            limit,
            out_results: &mut results,
        };
        self.inner
            .status_locked(unsafe { zova_sys::zova_vector_search_by_id_within(&request) })?;
        take_search_results(&mut results)
    }

    pub fn search_vectors_by_id_in_within(
        &self,
        collection_name: &str,
        source_vector_id: &str,
        candidate_ids: &[&str],
        max_distance: f64,
        limit: usize,
    ) -> Result<Vec<VectorSearchResult>> {
        let collection_name = cstring(collection_name, "vector collection name")?;
        let source_vector_id = cstring(source_vector_id, "source vector id")?;
        let (candidates, candidate_ptrs) = candidate_ptrs(candidate_ids)?;
        let _guard = self.inner.lock();
        let mut results = empty_search_results();
        let request = zova_sys::zova_vector_search_by_id_in_within_request {
            db: self.inner.raw_ptr(),
            collection_name: collection_name.as_ptr(),
            source_vector_id: source_vector_id.as_ptr(),
            candidate_ids: if candidate_ptrs.is_empty() {
                ptr::null()
            } else {
                candidate_ptrs.as_ptr()
            },
            candidate_count: candidate_ptrs.len(),
            max_distance,
            limit,
            out_results: &mut results,
        };
        let status = self
            .inner
            .status_locked(unsafe { zova_sys::zova_vector_search_by_id_in_within(&request) });
        drop(candidates);
        status?;
        take_search_results(&mut results)
    }

    fn open_or_create(path: impl AsRef<Path>, create: bool) -> Result<Self> {
        let path = path_to_cstring(path.as_ref())?;
        let mut db = ptr::null_mut();
        let mut message = empty_message();
        let request = zova_sys::zova_database_open_request {
            path: path.as_ptr(),
            out_db: &mut db,
            out_error_message: &mut message,
        };
        let status = unsafe {
            if create {
                zova_sys::zova_database_create(&request)
            } else {
                zova_sys::zova_database_open(&request)
            }
        };
        if status != zova_sys::ZOVA_OK {
            return Err(Error::from_status(status, take_message(&mut message)));
        }
        Self::from_raw(db)
    }

    fn from_raw(raw: *mut zova_sys::zova_database) -> Result<Self> {
        let raw = NonNull::new(raw)
            .ok_or_else(|| Error::from_status(zova_sys::ZOVA_INVALID_ARGUMENT, None))?;
        Ok(Self {
            inner: Arc::new(SharedDatabaseInner {
                raw,
                mutex: Mutex::new(()),
            }),
        })
    }

    fn simple(
        &self,
        function: unsafe extern "C" fn(
            *const zova_sys::zova_database_simple_request,
        ) -> zova_sys::zova_status,
    ) -> Result<()> {
        let _guard = self.inner.lock();
        let request = zova_sys::zova_database_simple_request {
            db: self.inner.raw_ptr(),
        };
        self.inner.status_locked(unsafe { function(&request) })
    }

    fn savepoint_call(
        &self,
        name: &str,
        function: unsafe extern "C" fn(
            *const zova_sys::zova_database_savepoint_request,
        ) -> zova_sys::zova_status,
    ) -> Result<()> {
        let name = cstring(name, "savepoint name")?;
        let _guard = self.inner.lock();
        let request = zova_sys::zova_database_savepoint_request {
            db: self.inner.raw_ptr(),
            name: name.as_ptr(),
        };
        self.inner.status_locked(unsafe { function(&request) })
    }

    fn transaction_with<T>(
        &self,
        begin: unsafe extern "C" fn(
            *const zova_sys::zova_database_simple_request,
        ) -> zova_sys::zova_status,
        f: impl FnOnce(&mut SharedDatabaseGuard<'_>) -> Result<T>,
    ) -> Result<T> {
        self.with_exclusive(|guard| {
            guard.simple_locked(begin)?;
            match f(guard) {
                Ok(value) => {
                    if let Err(error) = guard.commit_locked() {
                        let _ = guard.rollback_locked();
                        Err(error)
                    } else {
                        Ok(value)
                    }
                }
                Err(error) => {
                    let _ = guard.rollback_locked();
                    Err(error)
                }
            }
        })
    }
}

impl SharedDatabaseGuard<'_> {
    pub fn exec(&mut self, sql: &str) -> Result<()> {
        let sql = cstring(sql, "sql")?;
        let request = zova_sys::zova_database_exec_request {
            db: self.inner.raw_ptr(),
            sql: sql.as_ptr(),
        };
        self.inner
            .status_locked(unsafe { zova_sys::zova_database_exec(&request) })
    }

    pub fn prepare(&mut self, sql: &str) -> Result<SharedGuardStatement<'_>> {
        let sql = cstring(sql, "sql")?;
        let mut statement = ptr::null_mut();
        let request = zova_sys::zova_database_prepare_request {
            db: self.inner.raw_ptr(),
            sql: sql.as_ptr(),
            out_statement: &mut statement,
        };
        self.inner
            .status_locked(unsafe { zova_sys::zova_database_prepare(&request) })?;
        let raw = NonNull::new(statement)
            .ok_or_else(|| Error::from_status(zova_sys::ZOVA_INVALID_ARGUMENT, None))?;
        Ok(SharedGuardStatement {
            raw: Some(raw),
            inner: self.inner,
            _guard: PhantomData,
        })
    }

    pub fn last_insert_rowid(&mut self) -> Result<i64> {
        self.inner.last_insert_rowid_locked()
    }

    pub fn changes(&mut self) -> Result<i64> {
        self.inner.changes_locked()
    }

    pub fn total_changes(&mut self) -> Result<i64> {
        self.inner.total_changes_locked()
    }

    pub fn savepoint(&mut self, name: &str) -> Result<()> {
        self.savepoint_locked(name, zova_sys::zova_database_savepoint)
    }

    pub fn rollback_to_savepoint(&mut self, name: &str) -> Result<()> {
        self.savepoint_locked(name, zova_sys::zova_database_rollback_to_savepoint)
    }

    pub fn release_savepoint(&mut self, name: &str) -> Result<()> {
        self.savepoint_locked(name, zova_sys::zova_database_release_savepoint)
    }

    fn simple_locked(
        &self,
        function: unsafe extern "C" fn(
            *const zova_sys::zova_database_simple_request,
        ) -> zova_sys::zova_status,
    ) -> Result<()> {
        let request = zova_sys::zova_database_simple_request {
            db: self.inner.raw_ptr(),
        };
        self.inner.status_locked(unsafe { function(&request) })
    }

    fn savepoint_locked(
        &self,
        name: &str,
        function: unsafe extern "C" fn(
            *const zova_sys::zova_database_savepoint_request,
        ) -> zova_sys::zova_status,
    ) -> Result<()> {
        let name = cstring(name, "savepoint name")?;
        let request = zova_sys::zova_database_savepoint_request {
            db: self.inner.raw_ptr(),
            name: name.as_ptr(),
        };
        self.inner.status_locked(unsafe { function(&request) })
    }

    fn commit_locked(&self) -> Result<()> {
        self.simple_locked(zova_sys::zova_database_commit)
    }

    fn rollback_locked(&self) -> Result<()> {
        self.simple_locked(zova_sys::zova_database_rollback)
    }
}

macro_rules! impl_shared_statement_api {
    ($statement:ty) => {
        pub fn parameter_count(&mut self) -> Result<usize> {
            self.with_raw(|raw, inner| statement_parameter_count(raw, inner))
        }

        pub fn parameter_index(&mut self, name: &str) -> Result<Option<usize>> {
            let name = cstring(name, "parameter name")?;
            self.with_raw(|raw, inner| statement_parameter_index(raw, inner, &name))
        }

        pub fn bind_null(&mut self, index: usize) -> Result<()> {
            self.with_raw(|raw, inner| statement_bind_null(raw, inner, index))
        }

        pub fn bind_i64(&mut self, index: usize, value: i64) -> Result<()> {
            self.with_raw(|raw, inner| statement_bind_i64(raw, inner, index, value))
        }

        pub fn bind_f64(&mut self, index: usize, value: f64) -> Result<()> {
            self.with_raw(|raw, inner| statement_bind_f64(raw, inner, index, value))
        }

        pub fn bind_text(&mut self, index: usize, value: &str) -> Result<()> {
            self.with_raw(|raw, inner| statement_bind_text(raw, inner, index, value))
        }

        pub fn bind_blob(&mut self, index: usize, value: &[u8]) -> Result<()> {
            self.with_raw(|raw, inner| statement_bind_blob(raw, inner, index, value))
        }

        pub fn step(&mut self) -> Result<Step> {
            self.with_raw(|raw, inner| statement_step(raw, inner))
        }

        pub fn reset(&mut self) -> Result<()> {
            self.with_raw(|raw, inner| statement_reset(raw, inner))
        }

        pub fn clear_bindings(&mut self) -> Result<()> {
            self.with_raw(|raw, inner| statement_clear_bindings(raw, inner))
        }

        pub fn column_count(&mut self) -> Result<usize> {
            self.with_raw(|raw, inner| statement_column_count(raw, inner))
        }

        pub fn column_name(&mut self, index: usize) -> Result<String> {
            self.with_raw(|raw, inner| statement_column_name(raw, inner, index))
        }

        pub fn column_type(&mut self, index: usize) -> Result<ColumnType> {
            self.with_raw(|raw, inner| statement_column_type(raw, inner, index))
        }

        pub fn column_i64(&mut self, index: usize) -> Result<i64> {
            self.with_raw(|raw, inner| statement_column_i64(raw, inner, index))
        }

        pub fn column_f64(&mut self, index: usize) -> Result<f64> {
            self.with_raw(|raw, inner| statement_column_f64(raw, inner, index))
        }

        pub fn column_text(&mut self, index: usize) -> Result<Option<String>> {
            self.with_raw(|raw, inner| statement_column_text(raw, inner, index))
        }

        pub fn column_blob(&mut self, index: usize) -> Result<Option<Vec<u8>>> {
            self.with_raw(|raw, inner| statement_column_blob(raw, inner, index))
        }
    };
}

impl SharedStatement {
    impl_shared_statement_api!(SharedStatement);

    fn with_raw<T>(
        &mut self,
        f: impl FnOnce(NonNull<zova_sys::zova_statement>, &SharedDatabaseInner) -> Result<T>,
    ) -> Result<T> {
        let raw = self.raw()?;
        let _guard = self.database.lock();
        f(raw, &self.database)
    }

    fn raw(&self) -> Result<NonNull<zova_sys::zova_statement>> {
        self.raw
            .ok_or_else(|| Error::from_status(zova_sys::ZOVA_MISUSE, None))
    }

    fn destroy(&mut self) {
        if let Some(raw) = self.raw.take() {
            let _guard = self.database.lock();
            unsafe {
                let _ = zova_sys::zova_statement_finalize(raw.as_ptr());
            }
        }
    }
}

impl SharedGuardStatement<'_> {
    impl_shared_statement_api!(SharedGuardStatement<'_>);

    fn with_raw<T>(
        &mut self,
        f: impl FnOnce(NonNull<zova_sys::zova_statement>, &SharedDatabaseInner) -> Result<T>,
    ) -> Result<T> {
        let raw = self.raw()?;
        f(raw, self.inner)
    }

    fn raw(&self) -> Result<NonNull<zova_sys::zova_statement>> {
        self.raw
            .ok_or_else(|| Error::from_status(zova_sys::ZOVA_MISUSE, None))
    }
}

impl SharedObjectWriter {
    pub fn write(&mut self, bytes: &[u8]) -> Result<()> {
        let raw = self.raw()?;
        let database = self.database.clone();
        let _guard = database.lock();
        let request = zova_sys::zova_object_writer_write_request {
            writer: raw.as_ptr(),
            data: bytes.as_ptr(),
            len: bytes.len(),
        };
        database.status_locked(unsafe { zova_sys::zova_object_writer_write(&request) })
    }

    pub fn finish(mut self) -> Result<ObjectId> {
        let raw = self.raw()?;
        let database = self.database.clone();
        let _guard = database.lock();
        let mut out = zova_sys::zova_object_id { bytes: [0; 32] };
        let request = zova_sys::zova_object_writer_finish_request {
            writer: raw.as_ptr(),
            out_id: &mut out,
        };
        database.status_locked(unsafe { zova_sys::zova_object_writer_finish(&request) })?;
        self.destroy_locked();
        Ok(from_c_object_id(out))
    }

    pub fn cancel(mut self) -> Result<()> {
        let raw = self.raw()?;
        let database = self.database.clone();
        let _guard = database.lock();
        let request = zova_sys::zova_object_writer_cancel_request {
            writer: raw.as_ptr(),
        };
        database.status_locked(unsafe { zova_sys::zova_object_writer_cancel(&request) })?;
        self.destroy_locked();
        Ok(())
    }

    fn raw(&self) -> Result<NonNull<zova_sys::zova_object_writer>> {
        self.raw
            .ok_or_else(|| Error::from_status(zova_sys::ZOVA_OBJECT_WRITER_CLOSED, None))
    }

    fn destroy_locked(&mut self) {
        if let Some(raw) = self.raw.take() {
            unsafe {
                let _ = zova_sys::zova_object_writer_destroy(raw.as_ptr());
            }
        }
    }

    fn destroy(&mut self) {
        if self.raw.is_none() {
            return;
        }
        let database = self.database.clone();
        let _guard = database.lock();
        self.destroy_locked();
    }
}

impl SharedDatabaseInner {
    fn raw_ptr(&self) -> *mut zova_sys::zova_database {
        self.raw.as_ptr()
    }

    fn lock(&self) -> MutexGuard<'_, ()> {
        self.mutex
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn status_locked(&self, status: i32) -> Result<()> {
        if status == zova_sys::ZOVA_OK {
            return Ok(());
        }
        let message = unsafe {
            let ptr = zova_sys::zova_database_last_error_message(self.raw_ptr());
            if ptr.is_null() {
                None
            } else {
                Some(CStr::from_ptr(ptr).to_string_lossy().into_owned())
            }
        };
        Err(Error::from_status(status, message))
    }

    fn last_insert_rowid_locked(&self) -> Result<i64> {
        let mut rowid = 0;
        let request = zova_sys::zova_database_last_insert_rowid_request {
            db: self.raw_ptr(),
            out_rowid: &mut rowid,
        };
        self.status_locked(unsafe { zova_sys::zova_database_last_insert_rowid(&request) })?;
        Ok(rowid)
    }

    fn changes_locked(&self) -> Result<i64> {
        let mut changes = 0;
        let request = zova_sys::zova_database_changes_request {
            db: self.raw_ptr(),
            out_changes: &mut changes,
        };
        self.status_locked(unsafe { zova_sys::zova_database_changes(&request) })?;
        Ok(changes)
    }

    fn total_changes_locked(&self) -> Result<i64> {
        let mut total_changes = 0;
        let request = zova_sys::zova_database_total_changes_request {
            db: self.raw_ptr(),
            out_total_changes: &mut total_changes,
        };
        self.status_locked(unsafe { zova_sys::zova_database_total_changes(&request) })?;
        Ok(total_changes)
    }
}

impl Drop for SharedDatabaseInner {
    fn drop(&mut self) {
        let _guard = self.lock();
        unsafe {
            let _ = zova_sys::zova_database_close(self.raw.as_ptr());
        }
    }
}

impl Drop for SharedStatement {
    fn drop(&mut self) {
        self.destroy();
    }
}

impl Drop for SharedGuardStatement<'_> {
    fn drop(&mut self) {
        if let Some(raw) = self.raw.take() {
            unsafe {
                let _ = zova_sys::zova_statement_finalize(raw.as_ptr());
            }
        }
    }
}

impl Drop for SharedObjectWriter {
    fn drop(&mut self) {
        self.destroy();
    }
}

impl fmt::Debug for SharedDatabase {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SharedDatabase").finish_non_exhaustive()
    }
}

impl fmt::Debug for SharedStatement {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SharedStatement").finish_non_exhaustive()
    }
}

impl fmt::Debug for SharedObjectWriter {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SharedObjectWriter").finish_non_exhaustive()
    }
}

fn statement_parameter_count(
    raw: NonNull<zova_sys::zova_statement>,
    inner: &SharedDatabaseInner,
) -> Result<usize> {
    let mut count = 0;
    let request = zova_sys::zova_statement_parameter_count_request {
        statement: raw.as_ptr(),
        out_count: &mut count,
    };
    inner.status_locked(unsafe { zova_sys::zova_statement_parameter_count(&request) })?;
    Ok(count as usize)
}

fn statement_parameter_index(
    raw: NonNull<zova_sys::zova_statement>,
    inner: &SharedDatabaseInner,
    name: &std::ffi::CString,
) -> Result<Option<usize>> {
    let mut index = 0;
    let request = zova_sys::zova_statement_parameter_index_request {
        statement: raw.as_ptr(),
        name: name.as_ptr(),
        out_index: &mut index,
    };
    inner.status_locked(unsafe { zova_sys::zova_statement_parameter_index(&request) })?;
    if index == 0 {
        Ok(None)
    } else {
        Ok(Some(index as usize))
    }
}

fn statement_bind_null(
    raw: NonNull<zova_sys::zova_statement>,
    inner: &SharedDatabaseInner,
    index: usize,
) -> Result<()> {
    let request = zova_sys::zova_statement_bind_null_request {
        statement: raw.as_ptr(),
        index: checked_parameter_index(index)?,
    };
    inner.status_locked(unsafe { zova_sys::zova_statement_bind_null(&request) })
}

fn statement_bind_i64(
    raw: NonNull<zova_sys::zova_statement>,
    inner: &SharedDatabaseInner,
    index: usize,
    value: i64,
) -> Result<()> {
    let request = zova_sys::zova_statement_bind_int64_request {
        statement: raw.as_ptr(),
        index: checked_parameter_index(index)?,
        value,
    };
    inner.status_locked(unsafe { zova_sys::zova_statement_bind_int64(&request) })
}

fn statement_bind_f64(
    raw: NonNull<zova_sys::zova_statement>,
    inner: &SharedDatabaseInner,
    index: usize,
    value: f64,
) -> Result<()> {
    let request = zova_sys::zova_statement_bind_double_request {
        statement: raw.as_ptr(),
        index: checked_parameter_index(index)?,
        value,
    };
    inner.status_locked(unsafe { zova_sys::zova_statement_bind_double(&request) })
}

fn statement_bind_text(
    raw: NonNull<zova_sys::zova_statement>,
    inner: &SharedDatabaseInner,
    index: usize,
    value: &str,
) -> Result<()> {
    let request = zova_sys::zova_statement_bind_text_request {
        statement: raw.as_ptr(),
        index: checked_parameter_index(index)?,
        data: value.as_bytes().as_ptr(),
        len: value.len(),
    };
    inner.status_locked(unsafe { zova_sys::zova_statement_bind_text(&request) })
}

fn statement_bind_blob(
    raw: NonNull<zova_sys::zova_statement>,
    inner: &SharedDatabaseInner,
    index: usize,
    value: &[u8],
) -> Result<()> {
    let request = zova_sys::zova_statement_bind_blob_request {
        statement: raw.as_ptr(),
        index: checked_parameter_index(index)?,
        data: value.as_ptr(),
        len: value.len(),
    };
    inner.status_locked(unsafe { zova_sys::zova_statement_bind_blob(&request) })
}

fn statement_step(
    raw: NonNull<zova_sys::zova_statement>,
    inner: &SharedDatabaseInner,
) -> Result<Step> {
    let mut result = 0;
    let request = zova_sys::zova_statement_step_request {
        statement: raw.as_ptr(),
        out_result: &mut result,
    };
    inner.status_locked(unsafe { zova_sys::zova_statement_step(&request) })?;
    match result {
        zova_sys::ZOVA_STEP_ROW => Ok(Step::Row),
        zova_sys::ZOVA_STEP_DONE => Ok(Step::Done),
        _ => Err(Error::from_status(zova_sys::ZOVA_MISUSE, None)),
    }
}

fn statement_reset(
    raw: NonNull<zova_sys::zova_statement>,
    inner: &SharedDatabaseInner,
) -> Result<()> {
    inner.status_locked(unsafe { zova_sys::zova_statement_reset(raw.as_ptr()) })
}

fn statement_clear_bindings(
    raw: NonNull<zova_sys::zova_statement>,
    inner: &SharedDatabaseInner,
) -> Result<()> {
    inner.status_locked(unsafe { zova_sys::zova_statement_clear_bindings(raw.as_ptr()) })
}

fn statement_column_count(
    raw: NonNull<zova_sys::zova_statement>,
    inner: &SharedDatabaseInner,
) -> Result<usize> {
    let mut count = 0;
    let request = zova_sys::zova_statement_column_count_request {
        statement: raw.as_ptr(),
        out_count: &mut count,
    };
    inner.status_locked(unsafe { zova_sys::zova_statement_column_count(&request) })?;
    Ok(count as usize)
}

fn statement_column_name(
    raw: NonNull<zova_sys::zova_statement>,
    inner: &SharedDatabaseInner,
    index: usize,
) -> Result<String> {
    let mut text = zova_sys::zova_text {
        data: ptr::null_mut(),
        len: 0,
    };
    let request = zova_sys::zova_statement_column_name_request {
        statement: raw.as_ptr(),
        index: checked_index(index)?,
        out_name: &mut text,
    };
    inner.status_locked(unsafe { zova_sys::zova_statement_column_name(&request) })?;
    let bytes = unsafe { std::slice::from_raw_parts(text.data.cast::<u8>(), text.len) };
    let value = String::from_utf8(bytes.to_vec()).map_err(|_| Error::InvalidUtf8Text);
    unsafe {
        zova_sys::zova_text_free(&mut text);
    }
    value
}

fn statement_column_type(
    raw: NonNull<zova_sys::zova_statement>,
    inner: &SharedDatabaseInner,
    index: usize,
) -> Result<ColumnType> {
    let mut value = 0;
    let request = zova_sys::zova_statement_column_type_request {
        statement: raw.as_ptr(),
        index: checked_index(index)?,
        out_type: &mut value,
    };
    inner.status_locked(unsafe { zova_sys::zova_statement_column_type(&request) })?;
    match value {
        zova_sys::ZOVA_COLUMN_INTEGER => Ok(ColumnType::Integer),
        zova_sys::ZOVA_COLUMN_FLOAT => Ok(ColumnType::Float),
        zova_sys::ZOVA_COLUMN_TEXT => Ok(ColumnType::Text),
        zova_sys::ZOVA_COLUMN_BLOB => Ok(ColumnType::Blob),
        zova_sys::ZOVA_COLUMN_NULL => Ok(ColumnType::Null),
        _ => Err(Error::from_status(zova_sys::ZOVA_MISUSE, None)),
    }
}

fn statement_column_i64(
    raw: NonNull<zova_sys::zova_statement>,
    inner: &SharedDatabaseInner,
    index: usize,
) -> Result<i64> {
    let mut value = 0;
    let request = zova_sys::zova_statement_column_int64_request {
        statement: raw.as_ptr(),
        index: checked_index(index)?,
        out_value: &mut value,
    };
    inner.status_locked(unsafe { zova_sys::zova_statement_column_int64(&request) })?;
    Ok(value)
}

fn statement_column_f64(
    raw: NonNull<zova_sys::zova_statement>,
    inner: &SharedDatabaseInner,
    index: usize,
) -> Result<f64> {
    let mut value = 0.0;
    let request = zova_sys::zova_statement_column_double_request {
        statement: raw.as_ptr(),
        index: checked_index(index)?,
        out_value: &mut value,
    };
    inner.status_locked(unsafe { zova_sys::zova_statement_column_double(&request) })?;
    Ok(value)
}

fn statement_column_text(
    raw: NonNull<zova_sys::zova_statement>,
    inner: &SharedDatabaseInner,
    index: usize,
) -> Result<Option<String>> {
    let mut text = zova_sys::zova_text {
        data: ptr::null_mut(),
        len: 0,
    };
    let request = zova_sys::zova_statement_column_text_request {
        statement: raw.as_ptr(),
        index: checked_index(index)?,
        out_text: &mut text,
    };
    inner.status_locked(unsafe { zova_sys::zova_statement_column_text(&request) })?;
    if text.data.is_null() {
        return Ok(None);
    }
    let bytes = unsafe { std::slice::from_raw_parts(text.data.cast::<u8>(), text.len) };
    let value = String::from_utf8(bytes.to_vec()).map_err(|_| Error::InvalidUtf8Text);
    unsafe {
        zova_sys::zova_text_free(&mut text);
    }
    value.map(Some)
}

fn statement_column_blob(
    raw: NonNull<zova_sys::zova_statement>,
    inner: &SharedDatabaseInner,
    index: usize,
) -> Result<Option<Vec<u8>>> {
    let mut buffer = zova_sys::zova_buffer {
        data: ptr::null_mut(),
        len: 0,
    };
    let request = zova_sys::zova_statement_column_blob_request {
        statement: raw.as_ptr(),
        index: checked_index(index)?,
        out_buffer: &mut buffer,
    };
    inner.status_locked(unsafe { zova_sys::zova_statement_column_blob(&request) })?;
    if buffer.data.is_null() {
        return match statement_column_type(raw, inner, index)? {
            ColumnType::Null => Ok(None),
            ColumnType::Blob => Ok(Some(Vec::new())),
            _ => Ok(None),
        };
    }
    let bytes = unsafe { std::slice::from_raw_parts(buffer.data, buffer.len) };
    let value = bytes.to_vec();
    unsafe {
        zova_sys::zova_buffer_free(&mut buffer);
    }
    Ok(Some(value))
}

fn checked_index(index: usize) -> Result<i32> {
    i32::try_from(index).map_err(|_| Error::from_status(zova_sys::ZOVA_INVALID_ARGUMENT, None))
}

fn checked_parameter_index(index: usize) -> Result<i32> {
    if index == 0 {
        return Err(Error::from_status(zova_sys::ZOVA_INVALID_ARGUMENT, None));
    }
    checked_index(index)
}
