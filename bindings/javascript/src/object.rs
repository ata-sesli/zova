use std::sync::Arc;

use napi::bindgen_prelude::{BigInt, Uint8Array};
use napi::Result;
use napi_derive::napi;

use crate::database::{DatabaseState, NativeDatabase};
use crate::error::{invalid_argument_error, misuse_error, zova_error};

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
