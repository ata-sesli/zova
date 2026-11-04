use std::io::{Read, Seek, SeekFrom};
use std::sync::{Arc, Mutex};

use napi::bindgen_prelude::{AsyncTask, BigInt, Uint8Array};
use napi::{Env, Result, Task};
use napi_derive::napi;

use crate::database::{DatabaseState, NativeDatabase};
use crate::error::{invalid_argument_error, misuse_error, zova_error};

#[napi(object)]
pub struct NativeObjectPutOptions {
    pub profile: String,
}

fn put_options(options: &NativeObjectPutOptions) -> Result<zova::ObjectPutOptions> {
    let profile = match options.profile.as_str() {
        "deduplication" => zova::ObjectStorageProfile::Deduplication,
        "streaming" => zova::ObjectStorageProfile::Streaming,
        value => {
            return Err(invalid_argument_error(format!(
                "unsupported object storage profile: {value}"
            )))
        }
    };
    Ok(zova::ObjectPutOptions { profile })
}

fn object_id_from_array(value: &Uint8Array) -> Result<zova::ObjectId> {
    zova::ObjectId::try_from(value.as_ref()).map_err(zova_error)
}

fn chunk_id_from_array(value: &Uint8Array) -> Result<zova::ObjectChunkId> {
    zova::ObjectChunkId::try_from(value.as_ref()).map_err(zova_error)
}

fn bigint_to_u64(value: &BigInt, label: &str) -> Result<u64> {
    let (signed, value, lossless) = value.get_u64();
    if signed || !lossless {
        return Err(invalid_argument_error(format!(
            "{label} must fit in an unsigned 64-bit value"
        )));
    }
    Ok(value)
}

fn object_id_array(value: zova::ObjectId) -> Uint8Array {
    Uint8Array::new(value.into_bytes().to_vec())
}

fn chunk_id_array(value: zova::ObjectChunkId) -> Uint8Array {
    Uint8Array::new(value.into_bytes().to_vec())
}

#[napi(object)]
pub struct NativeObjectManifestChunk {
    pub index: BigInt,
    pub hash: Uint8Array,
    pub offset: BigInt,
    pub size_bytes: BigInt,
}

#[napi(object)]
pub struct NativeObjectManifest {
    pub object_id: Uint8Array,
    pub size_bytes: BigInt,
    pub chunk_count: BigInt,
    pub chunker: String,
    pub chunks: Vec<NativeObjectManifestChunk>,
}

#[napi(object)]
pub struct NativeObjectManifestChunkInput {
    pub index: BigInt,
    pub hash: Uint8Array,
    pub offset: BigInt,
    pub size_bytes: BigInt,
}

fn native_manifest(manifest: zova::ObjectManifest) -> NativeObjectManifest {
    NativeObjectManifest {
        object_id: object_id_array(manifest.object_id),
        size_bytes: BigInt::from(manifest.size_bytes),
        chunk_count: BigInt::from(manifest.chunk_count),
        chunker: manifest.chunker,
        chunks: manifest
            .chunks
            .into_iter()
            .map(|chunk| NativeObjectManifestChunk {
                index: BigInt::from(chunk.index),
                hash: chunk_id_array(chunk.hash),
                offset: BigInt::from(chunk.offset),
                size_bytes: BigInt::from(chunk.size_bytes),
            })
            .collect(),
    }
}

#[napi]
#[cfg_attr(test, allow(dead_code))]
pub fn object_id(data: Uint8Array) -> Result<Uint8Array> {
    zova::object_id(data.as_ref())
        .map(object_id_array)
        .map_err(zova_error)
}

#[napi]
#[cfg_attr(test, allow(dead_code))]
pub fn object_chunk_id(data: Uint8Array) -> Result<Uint8Array> {
    zova::object_chunk_id(data.as_ref())
        .map(chunk_id_array)
        .map_err(zova_error)
}

#[napi]
impl NativeDatabase {
    #[napi]
    pub fn put_object(&self, data: Uint8Array) -> Result<Uint8Array> {
        self.state
            .database()?
            .put_object(data.as_ref())
            .map(object_id_array)
            .map_err(zova_error)
    }

    #[napi]
    pub fn put_object_with_options(
        &self,
        data: Uint8Array,
        options: NativeObjectPutOptions,
    ) -> Result<Uint8Array> {
        self.state
            .database()?
            .put_object_with_options(data.as_ref(), put_options(&options)?)
            .map(object_id_array)
            .map_err(zova_error)
    }

    #[napi]
    pub fn get_object(&self, id: Uint8Array) -> Result<Uint8Array> {
        self.state
            .database()?
            .get_object(object_id_from_array(&id)?)
            .map(Uint8Array::new)
            .map_err(zova_error)
    }

    #[napi]
    pub fn read_object_range(
        &self,
        id: Uint8Array,
        offset: BigInt,
        size: u32,
    ) -> Result<Uint8Array> {
        let mut bytes = vec![0; size as usize];
        let copied = self
            .state
            .database()?
            .read_object_range(
                object_id_from_array(&id)?,
                bigint_to_u64(&offset, "object range offset")?,
                &mut bytes,
            )
            .map_err(zova_error)?;
        bytes.truncate(copied);
        Ok(Uint8Array::new(bytes))
    }

    #[napi]
    pub fn has_object(&self, id: Uint8Array) -> Result<bool> {
        self.state
            .database()?
            .has_object(object_id_from_array(&id)?)
            .map_err(zova_error)
    }

    #[napi]
    pub fn object_size(&self, id: Uint8Array) -> Result<BigInt> {
        self.state
            .database()?
            .object_size(object_id_from_array(&id)?)
            .map(BigInt::from)
            .map_err(zova_error)
    }

    #[napi]
    pub fn object_chunk_count(&self, id: Uint8Array) -> Result<BigInt> {
        self.state
            .database()?
            .object_chunk_count(object_id_from_array(&id)?)
            .map(BigInt::from)
            .map_err(zova_error)
    }

    #[napi]
    pub fn delete_object(&self, id: Uint8Array) -> Result<()> {
        self.state
            .database()?
            .delete_object(object_id_from_array(&id)?)
            .map_err(zova_error)
    }

    #[napi]
    pub fn object_manifest(&self, id: Uint8Array) -> Result<NativeObjectManifest> {
        self.state
            .database()?
            .object_manifest(object_id_from_array(&id)?)
            .map(native_manifest)
            .map_err(zova_error)
    }

    #[napi]
    pub fn get_object_chunk(&self, hash: Uint8Array) -> Result<Uint8Array> {
        self.state
            .database()?
            .get_object_chunk(chunk_id_from_array(&hash)?)
            .map(Uint8Array::new)
            .map_err(zova_error)
    }

    #[napi]
    pub fn has_object_chunk(&self, hash: Uint8Array) -> Result<bool> {
        self.state
            .database()?
            .has_object_chunk(chunk_id_from_array(&hash)?)
            .map_err(zova_error)
    }

    #[napi]
    pub fn put_object_chunk(&self, hash: Uint8Array, data: Uint8Array) -> Result<()> {
        self.state
            .database()?
            .put_object_chunk(chunk_id_from_array(&hash)?, data.as_ref())
            .map_err(zova_error)
    }

    #[napi]
    pub fn put_object_chunk_with_options(
        &self,
        hash: Uint8Array,
        data: Uint8Array,
        options: NativeObjectPutOptions,
    ) -> Result<()> {
        self.state
            .database()?
            .put_object_chunk_with_options(
                chunk_id_from_array(&hash)?,
                data.as_ref(),
                put_options(&options)?,
            )
            .map_err(zova_error)
    }

    #[napi]
    pub fn delete_object_chunk(&self, hash: Uint8Array) -> Result<bool> {
        self.state
            .database()?
            .delete_object_chunk(chunk_id_from_array(&hash)?)
            .map_err(zova_error)
    }

    #[napi]
    pub fn assemble_object_from_chunks(
        &self,
        id: Uint8Array,
        size_bytes: BigInt,
        chunks: Vec<NativeObjectManifestChunkInput>,
    ) -> Result<()> {
        let chunks = chunks
            .into_iter()
            .map(|chunk| {
                Ok(zova::ObjectManifestChunk {
                    index: bigint_to_u64(&chunk.index, "manifest chunk index")?,
                    hash: chunk_id_from_array(&chunk.hash)?,
                    offset: bigint_to_u64(&chunk.offset, "manifest chunk offset")?,
                    size_bytes: bigint_to_u64(&chunk.size_bytes, "manifest chunk size")?,
                })
            })
            .collect::<Result<Vec<_>>>()?;
        self.state
            .database()?
            .assemble_object_from_chunks(
                object_id_from_array(&id)?,
                bigint_to_u64(&size_bytes, "object size")?,
                &chunks,
            )
            .map_err(zova_error)
    }

    #[napi]
    pub fn assemble_object_from_chunks_with_options(
        &self,
        id: Uint8Array,
        size_bytes: BigInt,
        chunks: Vec<NativeObjectManifestChunkInput>,
        options: NativeObjectPutOptions,
    ) -> Result<()> {
        let chunks = chunks
            .into_iter()
            .map(|chunk| {
                Ok(zova::ObjectManifestChunk {
                    index: bigint_to_u64(&chunk.index, "manifest chunk index")?,
                    hash: chunk_id_from_array(&chunk.hash)?,
                    offset: bigint_to_u64(&chunk.offset, "manifest chunk offset")?,
                    size_bytes: bigint_to_u64(&chunk.size_bytes, "manifest chunk size")?,
                })
            })
            .collect::<Result<Vec<_>>>()?;
        self.state
            .database()?
            .assemble_object_from_chunks_with_options(
                object_id_from_array(&id)?,
                bigint_to_u64(&size_bytes, "object size")?,
                &chunks,
                put_options(&options)?,
            )
            .map_err(zova_error)
    }

    #[napi]
    pub fn object_writer(&self) -> Result<NativeObjectWriter> {
        let database = self.state.register_child()?;
        match database.object_writer() {
            Ok(writer) => Ok(NativeObjectWriter::new(writer, self.state.clone())),
            Err(error) => {
                self.state.child_closed();
                Err(zova_error(error))
            }
        }
    }

    #[napi]
    pub fn object_writer_with_options(
        &self,
        options: NativeObjectPutOptions,
    ) -> Result<NativeObjectWriter> {
        let database = self.state.register_child()?;
        match database.object_writer_with_options(put_options(&options)?) {
            Ok(writer) => Ok(NativeObjectWriter::new(writer, self.state.clone())),
            Err(error) => {
                self.state.child_closed();
                Err(zova_error(error))
            }
        }
    }

    #[napi]
    pub fn object_seekable_reader(&self, id: Uint8Array) -> Result<NativeObjectSeekableReader> {
        open_seekable_reader(&self.state, object_id_from_array(&id)?)
    }

    #[napi(ts_return_type = "Promise<NativeObjectSeekableReader>")]
    pub fn async_object_seekable_reader(
        &self,
        id: Uint8Array,
    ) -> Result<AsyncTask<OpenSeekableReaderTask>> {
        Ok(AsyncTask::new(OpenSeekableReaderTask {
            state: self.state.clone(),
            id: object_id_from_array(&id)?,
        }))
    }

    #[napi]
    pub fn object_reader(&self, id: Uint8Array) -> Result<NativeObjectReader> {
        let database = self.state.register_child()?;
        match database.object_reader(object_id_from_array(&id)?) {
            Ok(reader) => Ok(NativeObjectReader::new(reader, self.state.clone())),
            Err(error) => {
                self.state.child_closed();
                Err(zova_error(error))
            }
        }
    }
}

#[napi(js_name = "NativeObjectReader")]
pub struct NativeObjectReader {
    reader: Option<zova::SharedObjectReader>,
    database: Arc<DatabaseState>,
}

impl NativeObjectReader {
    fn new(reader: zova::SharedObjectReader, database: Arc<DatabaseState>) -> Self {
        Self {
            reader: Some(reader),
            database,
        }
    }

    fn reader(&mut self) -> Result<&mut zova::SharedObjectReader> {
        self.reader
            .as_mut()
            .ok_or_else(|| misuse_error("object reader is closed"))
    }

    fn drop_reader(&mut self) {
        if self.reader.take().is_some() {
            self.database.child_closed();
        }
    }
}

#[napi]
impl NativeObjectReader {
    #[napi(getter)]
    pub fn closed(&self) -> bool {
        self.reader.is_none()
    }

    #[napi]
    pub fn read(&mut self, size: u32) -> Result<Uint8Array> {
        let mut bytes = vec![0; size as usize];
        let read = self.reader()?.read(&mut bytes).map_err(zova_error)?;
        bytes.truncate(read);
        Ok(Uint8Array::new(bytes))
    }

    #[napi]
    pub fn close(&mut self) -> Result<()> {
        let Some(reader) = self.reader.as_mut() else {
            return Ok(());
        };
        reader.close().map_err(zova_error)?;
        self.drop_reader();
        Ok(())
    }
}

impl Drop for NativeObjectReader {
    fn drop(&mut self) {
        self.drop_reader();
    }
}

#[napi(js_name = "NativeObjectWriter")]
pub struct NativeObjectWriter {
    writer: Option<zova::SharedObjectWriter>,
    database: Arc<DatabaseState>,
}

impl NativeObjectWriter {
    fn new(writer: zova::SharedObjectWriter, database: Arc<DatabaseState>) -> Self {
        Self {
            writer: Some(writer),
            database,
        }
    }

    fn writer(&mut self) -> Result<&mut zova::SharedObjectWriter> {
        self.writer
            .as_mut()
            .ok_or_else(|| misuse_error("object writer is closed"))
    }

    fn take_writer(&mut self) -> Result<zova::SharedObjectWriter> {
        self.writer
            .take()
            .ok_or_else(|| misuse_error("object writer is closed"))
    }

    fn drop_writer(&mut self) {
        if self.writer.take().is_some() {
            self.database.child_closed();
        }
    }
}

#[napi]
impl NativeObjectWriter {
    #[napi(getter)]
    pub fn closed(&self) -> bool {
        self.writer.is_none()
    }

    #[napi]
    pub fn write(&mut self, data: Uint8Array) -> Result<()> {
        self.writer()?.write(data.as_ref()).map_err(zova_error)
    }

    #[napi]
    pub fn finish(&mut self) -> Result<Uint8Array> {
        let writer = self.take_writer()?;
        let result = writer.finish().map(object_id_array).map_err(zova_error);
        self.database.child_closed();
        result
    }

    #[napi]
    pub fn cancel(&mut self) -> Result<()> {
        let writer = self.take_writer()?;
        let result = writer.cancel().map_err(zova_error);
        self.database.child_closed();
        result
    }

    #[napi]
    pub fn close(&mut self) -> Result<()> {
        if self.writer.is_none() {
            return Ok(());
        }
        self.cancel()
    }
}

impl Drop for NativeObjectWriter {
    fn drop(&mut self) {
        self.drop_writer();
    }
}

/// Open a seekable reader as a registered child of the database.
pub(crate) fn open_seekable_reader(
    state: &Arc<DatabaseState>,
    id: zova::ObjectId,
) -> Result<NativeObjectSeekableReader> {
    let database = state.register_child()?;
    match database.object_seekable_reader(id) {
        Ok(reader) => Ok(NativeObjectSeekableReader {
            size: reader.size(),
            reader: Arc::new(Mutex::new(Some(reader))),
            database: state.clone(),
        }),
        Err(error) => {
            state.child_closed();
            Err(zova_error(error))
        }
    }
}

/// Map a reader I/O error back to its native Zova error when it carries one.
fn seekable_error(error: std::io::Error) -> napi::Error {
    match error
        .into_inner()
        .map(|inner| inner.downcast::<zova::Error>())
    {
        Some(Ok(native)) => zova_error(*native),
        Some(Err(other)) => invalid_argument_error(other.to_string()),
        None => invalid_argument_error("object reader I/O error"),
    }
}

type SeekableReaderSlot = Arc<Mutex<Option<zova::SharedObjectSeekableReader>>>;

fn read_seekable(slot: &SeekableReaderSlot, size: u32) -> Result<Vec<u8>> {
    let mut guard = slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let reader = guard
        .as_mut()
        .ok_or_else(|| misuse_error("object reader is closed"))?;
    let mut bytes = vec![0; size as usize];
    let read = reader.read(&mut bytes).map_err(seekable_error)?;
    bytes.truncate(read);
    Ok(bytes)
}

/// Seekable, verified object reader. The mutex lets synchronous calls and
/// worker-thread reads serialize access to the same native reader.
#[napi(js_name = "NativeObjectSeekableReader")]
pub struct NativeObjectSeekableReader {
    reader: SeekableReaderSlot,
    database: Arc<DatabaseState>,
    size: u64,
}

impl NativeObjectSeekableReader {
    fn close_inner(&self) -> Result<()> {
        let mut guard = self
            .reader
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let Some(reader) = guard.as_mut() else {
            return Ok(());
        };
        reader.close().map_err(zova_error)?;
        *guard = None;
        self.database.child_closed();
        Ok(())
    }
}

#[napi]
impl NativeObjectSeekableReader {
    #[napi(getter)]
    pub fn closed(&self) -> bool {
        self.reader
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .is_none()
    }

    #[napi(getter)]
    pub fn size(&self) -> BigInt {
        BigInt::from(self.size)
    }

    #[napi(getter)]
    pub fn position(&self) -> Result<BigInt> {
        let guard = self
            .reader
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let reader = guard
            .as_ref()
            .ok_or_else(|| misuse_error("object reader is closed"))?;
        Ok(BigInt::from(reader.position()))
    }

    #[napi]
    pub fn read(&self, size: u32) -> Result<Uint8Array> {
        Ok(Uint8Array::new(read_seekable(&self.reader, size)?))
    }

    #[napi(ts_return_type = "Promise<Uint8Array>")]
    pub fn async_read(&self, size: u32) -> AsyncTask<SeekableReadTask> {
        AsyncTask::new(SeekableReadTask {
            reader: self.reader.clone(),
            size,
        })
    }

    /// Move to an absolute offset. Offsets past the end read zero bytes.
    #[napi]
    pub fn seek(&self, offset: BigInt) -> Result<BigInt> {
        let (signed, offset, lossless) = offset.get_u64();
        if signed || !lossless {
            return Err(invalid_argument_error(
                "object reader offset must be a non-negative 64-bit integer",
            ));
        }
        let mut guard = self
            .reader
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let reader = guard
            .as_mut()
            .ok_or_else(|| misuse_error("object reader is closed"))?;
        let position = reader
            .seek(SeekFrom::Start(offset))
            .map_err(seekable_error)?;
        Ok(BigInt::from(position))
    }

    #[napi]
    pub fn close(&self) -> Result<()> {
        self.close_inner()
    }
}

impl Drop for NativeObjectSeekableReader {
    fn drop(&mut self) {
        let mut guard = self
            .reader
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if guard.take().is_some() {
            self.database.child_closed();
        }
    }
}

pub struct SeekableReadTask {
    reader: SeekableReaderSlot,
    size: u32,
}

impl Task for SeekableReadTask {
    type Output = Vec<u8>;
    type JsValue = Uint8Array;

    fn compute(&mut self) -> Result<Self::Output> {
        read_seekable(&self.reader, self.size)
    }

    fn resolve(&mut self, _: Env, output: Self::Output) -> Result<Self::JsValue> {
        Ok(Uint8Array::new(output))
    }
}

pub struct OpenSeekableReaderTask {
    state: Arc<DatabaseState>,
    id: zova::ObjectId,
}

impl Task for OpenSeekableReaderTask {
    type Output = NativeObjectSeekableReader;
    type JsValue = NativeObjectSeekableReader;

    fn compute(&mut self) -> Result<Self::Output> {
        open_seekable_reader(&self.state, self.id)
    }

    fn resolve(&mut self, _: Env, output: Self::Output) -> Result<Self::JsValue> {
        Ok(output)
    }
}
