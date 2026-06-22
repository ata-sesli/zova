use crate::database::{db_status, DatabaseInner};
use crate::error::{Error, Result, Status};
use crate::Database;
use std::convert::TryFrom;
use std::ffi::CStr;
use std::marker::PhantomData;
use std::ptr::{self, NonNull};
use std::rc::Rc;

/// A Zova object identity: SHA-256 of the full object bytes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ObjectId([u8; 32]);

/// A Zova object chunk identity: SHA-256 of one stored chunk.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ObjectChunkId([u8; 32]);

/// One chunk row in a Zova object manifest.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ObjectManifestChunk {
    pub index: u64,
    pub hash: ObjectChunkId,
    pub offset: u64,
    pub size_bytes: u64,
}

/// Owned manifest metadata for a complete Zova object.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ObjectManifest {
    pub object_id: ObjectId,
    pub size_bytes: u64,
    pub chunk_count: u64,
    pub chunker: String,
    pub chunks: Vec<ObjectManifestChunk>,
}

/// Streaming writer for storing an object without holding the full object in memory.
pub struct ObjectWriter<'db> {
    raw: Option<NonNull<zova_sys::zova_object_writer>>,
    db: *mut zova_sys::zova_database,
    _database: PhantomData<&'db mut Database>,
    _not_send_sync: PhantomData<Rc<()>>,
}

/// Owned streaming writer for language bindings that need writer objects
/// independent of Rust's borrowed `Database::object_writer` lifetime.
pub struct OwnedObjectWriter {
    raw: Option<NonNull<zova_sys::zova_object_writer>>,
    db: *mut zova_sys::zova_database,
    _database: Rc<DatabaseInner>,
    _not_send_sync: PhantomData<Rc<()>>,
}

impl ObjectId {
    /// Return the raw 32-byte object id.
    pub fn into_bytes(self) -> [u8; 32] {
        self.0
    }
}

impl ObjectChunkId {
    /// Return the raw 32-byte chunk id.
    pub fn into_bytes(self) -> [u8; 32] {
        self.0
    }
}

impl AsRef<[u8; 32]> for ObjectId {
    fn as_ref(&self) -> &[u8; 32] {
        &self.0
    }
}

impl AsRef<[u8; 32]> for ObjectChunkId {
    fn as_ref(&self) -> &[u8; 32] {
        &self.0
    }
}

impl From<[u8; 32]> for ObjectId {
    fn from(value: [u8; 32]) -> Self {
        Self(value)
    }
}

impl From<[u8; 32]> for ObjectChunkId {
    fn from(value: [u8; 32]) -> Self {
        Self(value)
    }
}

impl TryFrom<&[u8]> for ObjectId {
    type Error = Error;

    fn try_from(value: &[u8]) -> Result<Self> {
        let bytes: [u8; 32] = value
            .try_into()
            .map_err(|_| Error::from_status(zova_sys::ZOVA_INVALID_ARGUMENT, None))?;
        Ok(Self(bytes))
    }
}

impl TryFrom<&[u8]> for ObjectChunkId {
    type Error = Error;

    fn try_from(value: &[u8]) -> Result<Self> {
        let bytes: [u8; 32] = value
            .try_into()
            .map_err(|_| Error::from_status(zova_sys::ZOVA_INVALID_ARGUMENT, None))?;
        Ok(Self(bytes))
    }
}

/// Compute the Zova object id for `bytes`.
pub fn object_id(bytes: &[u8]) -> Result<ObjectId> {
    let mut out = zova_sys::zova_object_id { bytes: [0; 32] };
    let status =
        unsafe { zova_sys::zova_object_id_from_bytes(bytes.as_ptr(), bytes.len(), &mut out) };
    if status == zova_sys::ZOVA_OK {
        Ok(from_c_object_id(out))
    } else {
        Err(Error::from_status(status, None))
    }
}

/// Compute the Zova chunk id for `bytes`.
pub fn object_chunk_id(bytes: &[u8]) -> Result<ObjectChunkId> {
    let mut out = zova_sys::zova_object_chunk_id { bytes: [0; 32] };
    let status =
        unsafe { zova_sys::zova_object_chunk_id_from_bytes(bytes.as_ptr(), bytes.len(), &mut out) };
    if status == zova_sys::ZOVA_OK {
        Ok(from_c_chunk_id(out))
    } else {
        Err(Error::from_status(status, None))
    }
}

impl Database {
    /// Store full object bytes and return their content-addressed id.
    pub fn put_object(&mut self, bytes: &[u8]) -> Result<ObjectId> {
        let mut out = zova_sys::zova_object_id { bytes: [0; 32] };
        let request = zova_sys::zova_object_put_request {
            db: self.raw_ptr(),
            data: bytes.as_ptr(),
            len: bytes.len(),
            out_id: &mut out,
        };
        self.status(unsafe { zova_sys::zova_object_put(&request) })?;
        Ok(from_c_object_id(out))
    }

    /// Load a complete object into memory.
    pub fn get_object(&mut self, id: ObjectId) -> Result<Vec<u8>> {
        let mut buffer = empty_buffer();
        let request = zova_sys::zova_object_get_request {
            db: self.raw_ptr(),
            id: id.to_c(),
            out_buffer: &mut buffer,
        };
        self.status(unsafe { zova_sys::zova_object_get(&request) })?;
        Ok(take_buffer(&mut buffer))
    }

    /// Read a byte range from an object into caller-owned memory.
    pub fn read_object_range(
        &mut self,
        id: ObjectId,
        offset: u64,
        buffer: &mut [u8],
    ) -> Result<usize> {
        let mut copied = 0;
        let request = zova_sys::zova_object_read_range_request {
            db: self.raw_ptr(),
            id: id.to_c(),
            offset,
            buffer: buffer.as_mut_ptr(),
            buffer_len: buffer.len(),
            out_copied: &mut copied,
        };
        self.status(unsafe { zova_sys::zova_object_read_range(&request) })?;
        Ok(copied)
    }

    /// Return whether an object exists.
    pub fn has_object(&mut self, id: ObjectId) -> Result<bool> {
        let mut exists = 0;
        let request = zova_sys::zova_object_exists_request {
            db: self.raw_ptr(),
            id: id.to_c(),
            out_exists: &mut exists,
        };
        self.status(unsafe { zova_sys::zova_object_exists(&request) })?;
        Ok(exists != 0)
    }

    /// Return an object's logical byte size.
    pub fn object_size(&mut self, id: ObjectId) -> Result<u64> {
        let mut size = 0;
        let request = zova_sys::zova_object_size_request {
            db: self.raw_ptr(),
            id: id.to_c(),
            out_size: &mut size,
        };
        self.status(unsafe { zova_sys::zova_object_size(&request) })?;
        Ok(size)
    }

    /// Return the number of manifest chunks for an object.
    pub fn object_chunk_count(&mut self, id: ObjectId) -> Result<u64> {
        let mut count = 0;
        let request = zova_sys::zova_object_chunk_count_request {
            db: self.raw_ptr(),
            id: id.to_c(),
            out_count: &mut count,
        };
        self.status(unsafe { zova_sys::zova_object_chunk_count(&request) })?;
        Ok(count)
    }

    /// Delete an object and garbage-collect unreferenced chunks.
    pub fn delete_object(&mut self, id: ObjectId) -> Result<()> {
        let request = zova_sys::zova_object_delete_request {
            db: self.raw_ptr(),
            id: id.to_c(),
        };
        self.status(unsafe { zova_sys::zova_object_delete(&request) })
    }

    /// Return an object's owned manifest.
    pub fn object_manifest(&mut self, id: ObjectId) -> Result<ObjectManifest> {
        let mut manifest = empty_manifest();
        let request = zova_sys::zova_object_manifest_get_request {
            db: self.raw_ptr(),
            id: id.to_c(),
            out_manifest: &mut manifest,
        };
        self.status(unsafe { zova_sys::zova_object_manifest_get(&request) })?;
        Ok(take_manifest(&mut manifest))
    }

    /// Load one chunk by content hash.
    pub fn get_object_chunk(&mut self, hash: ObjectChunkId) -> Result<Vec<u8>> {
        let mut buffer = empty_buffer();
        let request = zova_sys::zova_object_chunk_get_request {
            db: self.raw_ptr(),
            hash: hash.to_c(),
            out_buffer: &mut buffer,
        };
        self.status(unsafe { zova_sys::zova_object_chunk_get(&request) })?;
        Ok(take_buffer(&mut buffer))
    }

    /// Return whether a chunk exists.
    pub fn has_object_chunk(&mut self, hash: ObjectChunkId) -> Result<bool> {
        match self.get_object_chunk(hash) {
            Ok(_) => Ok(true),
            Err(error) if error.status() == Some(Status::ObjectChunkNotFound) => Ok(false),
            Err(error) => Err(error),
        }
    }

    /// Store one verified loose chunk.
    pub fn put_object_chunk(&mut self, expected_hash: ObjectChunkId, bytes: &[u8]) -> Result<()> {
        let request = zova_sys::zova_object_chunk_put_request {
            db: self.raw_ptr(),
            expected_hash: expected_hash.to_c(),
            data: bytes.as_ptr(),
            len: bytes.len(),
        };
        self.status(unsafe { zova_sys::zova_object_chunk_put(&request) })
    }

    /// Delete an unreferenced loose chunk.
    pub fn delete_object_chunk(&mut self, hash: ObjectChunkId) -> Result<bool> {
        let mut deleted = 0;
        let request = zova_sys::zova_object_chunk_delete_request {
            db: self.raw_ptr(),
            hash: hash.to_c(),
            out_deleted: &mut deleted,
        };
        self.status(unsafe { zova_sys::zova_object_chunk_delete(&request) })?;
        Ok(deleted != 0)
    }

    /// Assemble a complete object from already stored chunks.
    pub fn assemble_object_from_chunks(
        &mut self,
        id: ObjectId,
        size_bytes: u64,
        chunks: &[ObjectManifestChunk],
    ) -> Result<()> {
        let c_chunks: Vec<_> = chunks.iter().map(ObjectManifestChunk::to_c).collect();
        let request = zova_sys::zova_object_assemble_from_chunks_request {
            db: self.raw_ptr(),
            id: id.to_c(),
            size_bytes,
            chunks: c_chunks.as_ptr(),
            chunk_count: c_chunks.len(),
        };
        self.status(unsafe { zova_sys::zova_object_assemble_from_chunks(&request) })
    }

    /// Create a streaming object writer.
    pub fn object_writer(&mut self) -> Result<ObjectWriter<'_>> {
        let mut writer = ptr::null_mut();
        let request = zova_sys::zova_object_writer_create_request {
            db: self.raw_ptr(),
            out_writer: &mut writer,
        };
        self.status(unsafe { zova_sys::zova_object_writer_create(&request) })?;
        let raw = NonNull::new(writer)
            .ok_or_else(|| Error::from_status(zova_sys::ZOVA_INVALID_ARGUMENT, None))?;
        Ok(ObjectWriter {
            raw: Some(raw),
            db: self.raw_ptr(),
            _database: PhantomData,
            _not_send_sync: PhantomData,
        })
    }

    /// Create an owned streaming object writer that keeps the database handle alive.
    pub fn object_writer_owned(&mut self) -> Result<OwnedObjectWriter> {
        let mut writer = ptr::null_mut();
        let request = zova_sys::zova_object_writer_create_request {
            db: self.raw_ptr(),
            out_writer: &mut writer,
        };
        self.status(unsafe { zova_sys::zova_object_writer_create(&request) })?;
        let raw = NonNull::new(writer)
            .ok_or_else(|| Error::from_status(zova_sys::ZOVA_INVALID_ARGUMENT, None))?;
        Ok(OwnedObjectWriter {
            raw: Some(raw),
            db: self.raw_ptr(),
            _database: self.inner.clone(),
            _not_send_sync: PhantomData,
        })
    }
}

impl ObjectWriter<'_> {
    /// Append bytes to the stream.
    pub fn write(&mut self, bytes: &[u8]) -> Result<()> {
        let raw = self.raw()?;
        let request = zova_sys::zova_object_writer_write_request {
            writer: raw.as_ptr(),
            data: bytes.as_ptr(),
            len: bytes.len(),
        };
        db_status(self.db, unsafe {
            zova_sys::zova_object_writer_write(&request)
        })
    }

    /// Finish the stream and return the complete object's id.
    pub fn finish(mut self) -> Result<ObjectId> {
        let raw = self.raw()?;
        let mut out = zova_sys::zova_object_id { bytes: [0; 32] };
        let request = zova_sys::zova_object_writer_finish_request {
            writer: raw.as_ptr(),
            out_id: &mut out,
        };
        db_status(self.db, unsafe {
            zova_sys::zova_object_writer_finish(&request)
        })?;
        self.destroy();
        Ok(from_c_object_id(out))
    }

    /// Cancel the stream and clean up unreferenced chunks written by this writer.
    pub fn cancel(mut self) -> Result<()> {
        let raw = self.raw()?;
        let request = zova_sys::zova_object_writer_cancel_request {
            writer: raw.as_ptr(),
        };
        db_status(self.db, unsafe {
            zova_sys::zova_object_writer_cancel(&request)
        })?;
        self.destroy();
        Ok(())
    }

    fn raw(&self) -> Result<NonNull<zova_sys::zova_object_writer>> {
        self.raw
            .ok_or_else(|| Error::from_status(zova_sys::ZOVA_OBJECT_WRITER_CLOSED, None))
    }

    fn destroy(&mut self) {
        if let Some(raw) = self.raw.take() {
            unsafe {
                let _ = zova_sys::zova_object_writer_destroy(raw.as_ptr());
            }
        }
    }
}

impl Drop for ObjectWriter<'_> {
    fn drop(&mut self) {
        self.destroy();
    }
}

impl OwnedObjectWriter {
    /// Append bytes to the stream.
    pub fn write(&mut self, bytes: &[u8]) -> Result<()> {
        let raw = self.raw()?;
        let request = zova_sys::zova_object_writer_write_request {
            writer: raw.as_ptr(),
            data: bytes.as_ptr(),
            len: bytes.len(),
        };
        db_status(self.db, unsafe {
            zova_sys::zova_object_writer_write(&request)
        })
    }

    /// Finish the stream and return the complete object's id.
    pub fn finish(mut self) -> Result<ObjectId> {
        let raw = self.raw()?;
        let mut out = zova_sys::zova_object_id { bytes: [0; 32] };
        let request = zova_sys::zova_object_writer_finish_request {
            writer: raw.as_ptr(),
            out_id: &mut out,
        };
        db_status(self.db, unsafe {
            zova_sys::zova_object_writer_finish(&request)
        })?;
        self.destroy();
        Ok(from_c_object_id(out))
    }

    /// Cancel the stream and clean up unreferenced chunks written by this writer.
    pub fn cancel(mut self) -> Result<()> {
        let raw = self.raw()?;
        let request = zova_sys::zova_object_writer_cancel_request {
            writer: raw.as_ptr(),
        };
        db_status(self.db, unsafe {
            zova_sys::zova_object_writer_cancel(&request)
        })?;
        self.destroy();
        Ok(())
    }

    fn raw(&self) -> Result<NonNull<zova_sys::zova_object_writer>> {
        self.raw
            .ok_or_else(|| Error::from_status(zova_sys::ZOVA_OBJECT_WRITER_CLOSED, None))
    }

    fn destroy(&mut self) {
        if let Some(raw) = self.raw.take() {
            unsafe {
                let _ = zova_sys::zova_object_writer_destroy(raw.as_ptr());
            }
        }
    }
}

impl Drop for OwnedObjectWriter {
    fn drop(&mut self) {
        self.destroy();
    }
}

impl ObjectId {
    fn to_c(self) -> zova_sys::zova_object_id {
        zova_sys::zova_object_id { bytes: self.0 }
    }
}

impl ObjectChunkId {
    fn to_c(self) -> zova_sys::zova_object_chunk_id {
        zova_sys::zova_object_chunk_id { bytes: self.0 }
    }
}

impl ObjectManifestChunk {
    fn to_c(&self) -> zova_sys::zova_object_manifest_chunk {
        zova_sys::zova_object_manifest_chunk {
            index: self.index,
            hash: self.hash.to_c(),
            offset: self.offset,
            size_bytes: self.size_bytes,
        }
    }
}

fn from_c_object_id(id: zova_sys::zova_object_id) -> ObjectId {
    ObjectId(id.bytes)
}

fn from_c_chunk_id(id: zova_sys::zova_object_chunk_id) -> ObjectChunkId {
    ObjectChunkId(id.bytes)
}

fn empty_buffer() -> zova_sys::zova_buffer {
    zova_sys::zova_buffer {
        data: ptr::null_mut(),
        len: 0,
    }
}

fn take_buffer(buffer: &mut zova_sys::zova_buffer) -> Vec<u8> {
    if buffer.data.is_null() || buffer.len == 0 {
        unsafe {
            zova_sys::zova_buffer_free(buffer);
        }
        return Vec::new();
    }
    let bytes = unsafe { std::slice::from_raw_parts(buffer.data, buffer.len) };
    let out = bytes.to_vec();
    unsafe {
        zova_sys::zova_buffer_free(buffer);
    }
    out
}

fn empty_manifest() -> zova_sys::zova_object_manifest {
    zova_sys::zova_object_manifest {
        object_id: zova_sys::zova_object_id { bytes: [0; 32] },
        size_bytes: 0,
        chunk_count: 0,
        chunker: ptr::null(),
        chunks: ptr::null_mut(),
        chunks_len: 0,
    }
}

fn take_manifest(manifest: &mut zova_sys::zova_object_manifest) -> ObjectManifest {
    let chunker = if manifest.chunker.is_null() {
        String::new()
    } else {
        unsafe {
            CStr::from_ptr(manifest.chunker)
                .to_string_lossy()
                .into_owned()
        }
    };
    let chunks = if manifest.chunks.is_null() || manifest.chunks_len == 0 {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(manifest.chunks, manifest.chunks_len) }
            .iter()
            .map(|chunk| ObjectManifestChunk {
                index: chunk.index,
                hash: from_c_chunk_id(chunk.hash),
                offset: chunk.offset,
                size_bytes: chunk.size_bytes,
            })
            .collect()
    };
    let out = ObjectManifest {
        object_id: from_c_object_id(manifest.object_id),
        size_bytes: manifest.size_bytes,
        chunk_count: manifest.chunk_count,
        chunker,
        chunks,
    };
    unsafe {
        zova_sys::zova_object_manifest_free(manifest);
    }
    out
}
