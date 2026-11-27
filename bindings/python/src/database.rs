use crate::error::{closed_error, zova_error};
use crate::extension::{
    linked_plugins, py_extension_info, py_extension_infos, PyExtensionInfo, PyLinkedPlugin,
};
use crate::fresh_build::PyFreshBuild;
use crate::graph::{
    direction_from_i32, edge_input_from_py, edge_inputs_from_py, neighbors_options_from_py,
    node_input_from_py, node_inputs_from_py, py_graph_edge, py_graph_info, py_graph_neighbors,
    py_graph_node, py_graph_walk, walk_options_from_py, PyGraphEdge, PyGraphInfo, PyGraphNeighbor,
    PyGraphNode, PyGraphWalkItem,
};
use crate::graph_keyed::{
    fresh_edge_payload_refs, fresh_edge_refs, fresh_edges_from_py, fresh_node_refs,
    fresh_nodes_from_py, py_keyed_edge, py_keyed_neighbors, py_keyed_node, py_scan_page,
    py_walk_profile, walk_direction_options_from_py, PyGraphKeyedEdge, PyGraphKeyedNeighbor,
    PyGraphKeyedNode, PyGraphScanPage, PyGraphWalkProfile,
};
use crate::notification::PySubscription;
use crate::object::{
    chunk_id_from_py, manifest_chunks_from_py, object_id_from_py, put_options_from_py, PyObjectId,
    PyObjectManifest, PyObjectReader, PyObjectWriter,
};
use crate::progress::ProgressHandler;
use crate::sql_function;
use crate::statement::PyStatement;
use crate::vector::{
    candidate_refs, collection_options_from_py, py_collection_info, py_search_results, py_vector,
    vector_input_refs, vector_inputs_from_py, vector_values_from_py, PyVector,
    PyVectorCollectionInfo, PyVectorSearchResult,
};
use pyo3::exceptions::PyValueError;
use pyo3::prelude::*;
use pyo3::types::{PyAny, PyBytes};

#[pyclass(name = "Database", unsendable)]
pub(crate) struct PyDatabase {
    inner: Option<zova_rust::Database>,
}

fn extension_options(
    bundles: Option<Vec<String>>,
    trust_store_path: Option<String>,
) -> zova_rust::ExtensionOptions {
    zova_rust::ExtensionOptions {
        bundle_paths: bundles
            .unwrap_or_default()
            .into_iter()
            .map(Into::into)
            .collect(),
        trust_store_path: trust_store_path.map(Into::into),
    }
}

#[pyclass(name = "SavepointContext", unsendable)]
pub(crate) struct PySavepointContext {
    database: Py<PyDatabase>,
    name: String,
    active: bool,
}

#[pymethods]
impl PyDatabase {
    /// Create a new `.zova` file. `plugins` adds `LinkedPlugin` descriptors
    /// to the selected bundles. `page_size` sets SQLite's page size in bytes
    /// and cannot be combined with bundles, a trust store, or plugins.
    #[staticmethod]
    #[pyo3(signature = (path, *, extension_bundles = None, trust_store_path = None, plugins = None, page_size = None))]
    pub(crate) fn create(
        path: &str,
        extension_bundles: Option<Vec<String>>,
        trust_store_path: Option<String>,
        plugins: Option<Vec<PyRef<'_, PyLinkedPlugin>>>,
        page_size: Option<u32>,
    ) -> PyResult<Self> {
        if let Some(page_size) = page_size {
            if extension_bundles.is_some() || trust_store_path.is_some() || plugins.is_some() {
                return Err(PyValueError::new_err(
                    "page_size cannot be combined with extension_bundles, trust_store_path, or plugins",
                ));
            }
            let options = zova_rust::CreateOptions { page_size };
            return Ok(Self {
                inner: Some(
                    zova_rust::Database::create_with_options(path, options).map_err(zova_error)?,
                ),
            });
        }
        let extensions = extension_options(extension_bundles, trust_store_path);
        let database = match plugins {
            Some(plugins) => zova_rust::Database::create_with_plugins(
                path,
                &extensions,
                &linked_plugins(Some(plugins)),
            ),
            None => zova_rust::Database::create_with_extensions(path, &extensions),
        };
        Ok(Self {
            inner: Some(database.map_err(zova_error)?),
        })
    }

    /// Create a new fully initialized volatile in-memory database.
    ///
    /// The database never creates database, WAL, or journal files, is isolated
    /// from every other in-memory database, and is reclaimed when closed.
    #[staticmethod]
    pub(crate) fn create_memory() -> PyResult<Self> {
        Ok(Self {
            inner: Some(zova_rust::Database::create_memory().map_err(zova_error)?),
        })
    }

    /// Open an existing `.zova` file. `plugins` adds `LinkedPlugin`
    /// descriptors to the selected bundles.
    #[staticmethod]
    #[pyo3(signature = (path, *, read_only = false, busy_timeout_ms = 0, extension_bundles = None, trust_store_path = None, plugins = None))]
    pub(crate) fn open(
        path: &str,
        read_only: bool,
        busy_timeout_ms: u32,
        extension_bundles: Option<Vec<String>>,
        trust_store_path: Option<String>,
        plugins: Option<Vec<PyRef<'_, PyLinkedPlugin>>>,
    ) -> PyResult<Self> {
        let extensions = extension_options(extension_bundles, trust_store_path);
        let options = zova_rust::OpenOptions {
            read_only,
            busy_timeout_ms,
        };
        let database = match plugins {
            Some(plugins) => zova_rust::Database::open_with_plugins(
                path,
                options,
                &extensions,
                &linked_plugins(Some(plugins)),
            ),
            None => zova_rust::Database::open_with_extensions(path, options, &extensions),
        };
        Ok(Self {
            inner: Some(database.map_err(zova_error)?),
        })
    }

    /// Open for `extension_upgrade` and `extension_rebuild`. Extension hooks
    /// are not run at open, so this succeeds when an installed extension's
    /// code is missing or outdated. Other arguments follow `open`.
    #[staticmethod]
    #[pyo3(signature = (path, *, read_only = false, busy_timeout_ms = 0, extension_bundles = None, trust_store_path = None, plugins = None))]
    pub(crate) fn open_for_extension_upgrade(
        path: &str,
        read_only: bool,
        busy_timeout_ms: u32,
        extension_bundles: Option<Vec<String>>,
        trust_store_path: Option<String>,
        plugins: Option<Vec<PyRef<'_, PyLinkedPlugin>>>,
    ) -> PyResult<Self> {
        let extensions = extension_options(extension_bundles, trust_store_path);
        let options = zova_rust::OpenOptions {
            read_only,
            busy_timeout_ms,
        };
        let database = match plugins {
            Some(plugins) => zova_rust::Database::open_for_extension_upgrade_with_plugins(
                path,
                options,
                &extensions,
                &linked_plugins(Some(plugins)),
            ),
            None => zova_rust::Database::open_for_extension_upgrade(path, options, &extensions),
        };
        Ok(Self {
            inner: Some(database.map_err(zova_error)?),
        })
    }

    pub(crate) fn close(&mut self) {
        self.inner.take();
    }

    pub(crate) fn exec(&mut self, sql: &str) -> PyResult<()> {
        self.db_mut()?.exec(sql).map_err(zova_error)
    }

    pub(crate) fn prepare(&mut self, sql: &str) -> PyResult<PyStatement> {
        let statement = self.db_mut()?.prepare_owned(sql).map_err(zova_error)?;
        Ok(PyStatement::new(statement))
    }

    pub(crate) fn begin(&mut self) -> PyResult<()> {
        self.db_mut()?.begin().map_err(zova_error)
    }

    pub(crate) fn begin_immediate(&mut self) -> PyResult<()> {
        self.db_mut()?.begin_immediate().map_err(zova_error)
    }

    pub(crate) fn commit(&mut self) -> PyResult<()> {
        self.db_mut()?.commit().map_err(zova_error)
    }

    pub(crate) fn rollback(&mut self) -> PyResult<()> {
        self.db_mut()?.rollback().map_err(zova_error)
    }

    pub(crate) fn savepoint(&mut self, name: &str) -> PyResult<()> {
        self.db_mut()?.savepoint(name).map_err(zova_error)
    }

    pub(crate) fn rollback_to_savepoint(&mut self, name: &str) -> PyResult<()> {
        self.db_mut()?
            .rollback_to_savepoint(name)
            .map_err(zova_error)
    }

    pub(crate) fn release_savepoint(&mut self, name: &str) -> PyResult<()> {
        self.db_mut()?.release_savepoint(name).map_err(zova_error)
    }

    pub(crate) fn savepoint_context(slf: Py<Self>, name: &str) -> PySavepointContext {
        PySavepointContext {
            database: slf,
            name: name.to_owned(),
            active: false,
        }
    }

    pub(crate) fn notify(&mut self, channel: &str, payload: &str) -> PyResult<()> {
        self.db_mut()?.notify(channel, payload).map_err(zova_error)
    }

    pub(crate) fn listen(&mut self, channel: &str) -> PyResult<PySubscription> {
        Ok(PySubscription {
            inner: Some(self.db_mut()?.listen(channel).map_err(zova_error)?),
        })
    }

    pub(crate) fn install_extension(&mut self, name: &str) -> PyResult<()> {
        self.db_mut()?.install_extension(name).map_err(zova_error)
    }

    pub(crate) fn list_extensions(&mut self) -> PyResult<Vec<PyExtensionInfo>> {
        Ok(py_extension_infos(
            self.db_mut()?.list_extensions().map_err(zova_error)?,
        ))
    }

    pub(crate) fn extension_info(&mut self, name: &str) -> PyResult<PyExtensionInfo> {
        Ok(py_extension_info(
            self.db_mut()?.extension_info(name).map_err(zova_error)?,
        ))
    }

    pub(crate) fn check_extension(&mut self, name: &str) -> PyResult<()> {
        self.db_mut()?.check_extension(name).map_err(zova_error)
    }

    pub(crate) fn check_extensions(&mut self) -> PyResult<()> {
        self.db_mut()?.check_extensions().map_err(zova_error)
    }

    pub(crate) fn drop_extension(&mut self, name: &str) -> PyResult<()> {
        self.db_mut()?.drop_extension(name).map_err(zova_error)
    }

    pub(crate) fn vacuum(&mut self) -> PyResult<()> {
        self.db_mut()?.vacuum().map_err(zova_error)
    }

    /// `progress`, when given, is called with a `Progress` event on this
    /// thread. An exception it raises cancels the backup, which leaves no
    /// destination, and propagates. It must not use this database.
    #[pyo3(signature = (destination, *, verify = true, progress = None))]
    pub(crate) fn backup_to(
        &mut self,
        destination: &str,
        verify: bool,
        progress: Option<Py<PyAny>>,
    ) -> PyResult<()> {
        let options = zova_rust::BackupOptions { verify };
        let db = self.db_mut()?;
        match progress {
            None => db.backup_to(destination, options).map_err(zova_error),
            Some(callback) => {
                let mut handler = ProgressHandler::new(callback);
                let result =
                    db.backup_to_with_progress(destination, options, |event| handler.call(event));
                handler.finish(result)
            }
        }
    }

    /// `progress` works as in `backup_to`.
    #[pyo3(signature = (destination, *, verify = true, progress = None))]
    pub(crate) fn compact_to(
        &mut self,
        destination: &str,
        verify: bool,
        progress: Option<Py<PyAny>>,
    ) -> PyResult<()> {
        let options = zova_rust::CompactOptions { verify };
        let db = self.db_mut()?;
        match progress {
            None => db.compact_to(destination, options).map_err(zova_error),
            Some(callback) => {
                let mut handler = ProgressHandler::new(callback);
                let result =
                    db.compact_to_with_progress(destination, options, |event| handler.call(event));
                handler.finish(result)
            }
        }
    }

    /// Release free pages of incremental auto-vacuum member files in place,
    /// each step in its own short write transaction of at most `step_pages`
    /// pages. `max_pages` bounds the pages released by the call; 0 releases
    /// every free page. Returns one `ReclaimedMember` per member file: the
    /// main database, then each attached object, vector, and graph store.
    /// Raises `ZovaError` with `ZOVA_OBJECT_TRANSACTION_ACTIVE` inside an
    /// explicit transaction.
    #[pyo3(signature = (*, max_pages = 0, step_pages = 1024))]
    pub(crate) fn reclaim_space(
        &mut self,
        max_pages: u64,
        step_pages: u32,
    ) -> PyResult<Vec<PyReclaimedMember>> {
        let members = self
            .db_mut()?
            .reclaim_space(zova_rust::ReclaimOptions {
                max_pages,
                step_pages,
            })
            .map_err(zova_error)?;
        Ok(members.into_iter().map(PyReclaimedMember::from).collect())
    }

    /// Switch every member of this database set (the main database and each
    /// attached bound store) to `mode` ("delete", "truncate", "persist" or
    /// "wal") and return the modes now in effect. Either every member ends in
    /// `mode`, or the members already switched are restored and `ZovaError`
    /// is raised: `ZOVA_BUSY` when another handle keeps a member in WAL mode,
    /// `ZOVA_INVALID_ARGUMENT` for "memory", "off" or an in-memory database,
    /// `ZOVA_OBJECT_TRANSACTION_ACTIVE` inside a transaction, and
    /// `ZOVA_READ_ONLY` on a read-only handle. Only WAL is stored in the file.
    pub(crate) fn set_journal_mode(&mut self, mode: &str) -> PyResult<Vec<PyJournalModeMember>> {
        let mode = parse_journal_mode(mode)?;
        let members = self.db_mut()?.set_journal_mode(mode).map_err(zova_error)?;
        Ok(members.into_iter().map(PyJournalModeMember::from).collect())
    }

    /// Journal mode of each member: the main database, then each attached
    /// object, vector and graph store.
    pub(crate) fn journal_modes(&mut self) -> PyResult<Vec<PyJournalModeMember>> {
        let members = self.db_mut()?.journal_modes().map_err(zova_error)?;
        Ok(members.into_iter().map(PyJournalModeMember::from).collect())
    }

    /// Run a WAL checkpoint ("passive", "full", "restart" or "truncate") on
    /// every member. Members not in WAL mode report zero frames. Raises
    /// `ZovaError` with `ZOVA_OBJECT_TRANSACTION_ACTIVE` inside a transaction.
    #[pyo3(signature = (mode = "passive"))]
    pub(crate) fn checkpoint(&mut self, mode: &str) -> PyResult<Vec<PyCheckpointedMember>> {
        let mode = match mode {
            "passive" => zova_rust::CheckpointMode::Passive,
            "full" => zova_rust::CheckpointMode::Full,
            "restart" => zova_rust::CheckpointMode::Restart,
            "truncate" => zova_rust::CheckpointMode::Truncate,
            _ => {
                return Err(PyValueError::new_err(
                    "checkpoint mode must be 'passive', 'full', 'restart' or 'truncate'",
                ))
            }
        };
        let members = self.db_mut()?.checkpoint(mode).map_err(zova_error)?;
        Ok(members
            .into_iter()
            .map(PyCheckpointedMember::from)
            .collect())
    }

    /// Experimental: switch this database set (the main database and each
    /// attached bound store) to `protocol` ("none" or "cwal"), then open it
    /// again through this handle. A set already in `protocol` is left as it
    /// is.
    ///
    /// Only native libraries built with `-Dexperimental-cwal` support it;
    /// others raise `ZovaError` with `ZOVA_UNSUPPORTED_ZOVA_VERSION`. It needs
    /// a read-write handle on a file with every member in WAL mode, outside a
    /// transaction (`ZOVA_OBJECT_TRANSACTION_ACTIVE`), with no other handle on
    /// the set (`ZOVA_BUSY`), and with no open statements, object readers or
    /// writers, subscriptions, or registered SQL functions on this handle
    /// (`ZOVA_MISUSE`): register SQL functions after switching.
    ///
    /// A CWAL set has one writer: a second read-write open raises
    /// `ZOVA_BUSY`, and read-only opens are unlimited. Do not open its member
    /// files with Python's `sqlite3` or another SQLite library in this
    /// process: closing that connection releases this process's POSIX locks
    /// on the file.
    pub(crate) fn set_commit_protocol(&mut self, protocol: &str) -> PyResult<()> {
        let protocol = match protocol {
            "none" => zova_rust::CommitProtocol::None,
            "cwal" => zova_rust::CommitProtocol::Cwal,
            _ => {
                return Err(PyValueError::new_err(
                    "commit protocol must be 'none' or 'cwal'",
                ))
            }
        };
        self.db_mut()?
            .set_commit_protocol(protocol)
            .map_err(zova_error)
    }

    pub(crate) fn set_busy_timeout(&mut self, milliseconds: u32) -> PyResult<()> {
        self.db_mut()?
            .set_busy_timeout(milliseconds)
            .map_err(zova_error)
    }

    pub(crate) fn last_insert_rowid(&mut self) -> PyResult<i64> {
        self.db_mut()?.last_insert_rowid().map_err(zova_error)
    }

    pub(crate) fn changes(&mut self) -> PyResult<i64> {
        self.db_mut()?.changes().map_err(zova_error)
    }

    pub(crate) fn total_changes(&mut self) -> PyResult<i64> {
        self.db_mut()?.total_changes().map_err(zova_error)
    }

    /// Select chunk compression for objects written through this handle:
    /// 0 stores chunks uncompressed, 1 stores LZ4 when that is smaller.
    pub(crate) fn set_object_compression(&mut self, compression: i32) -> PyResult<()> {
        let compression = match compression {
            0 => zova_rust::ObjectCompression::None,
            1 => zova_rust::ObjectCompression::Lz4,
            other => {
                return Err(pyo3::exceptions::PyValueError::new_err(format!(
                    "unknown object compression: {other}"
                )))
            }
        };
        self.db_mut()?
            .set_object_compression(compression)
            .map_err(zova_error)
    }

    pub(crate) fn put_object(&mut self, data: Vec<u8>) -> PyResult<PyObjectId> {
        Ok(PyObjectId::from_rust(
            self.db_mut()?.put_object(&data).map_err(zova_error)?,
        ))
    }

    pub(crate) fn put_object_with_options(
        &mut self,
        data: Vec<u8>,
        options: &Bound<'_, PyAny>,
    ) -> PyResult<PyObjectId> {
        let options = put_options_from_py(options)?;
        Ok(PyObjectId::from_rust(
            self.db_mut()?
                .put_object_with_options(&data, options)
                .map_err(zova_error)?,
        ))
    }

    pub(crate) fn get_object<'py>(
        &mut self,
        py: Python<'py>,
        id: &Bound<'_, PyAny>,
    ) -> PyResult<Bound<'py, PyBytes>> {
        let id = object_id_from_py(id)?;
        let data = self.db_mut()?.get_object(id).map_err(zova_error)?;
        Ok(PyBytes::new(py, &data))
    }

    pub(crate) fn read_object_range<'py>(
        &mut self,
        py: Python<'py>,
        id: &Bound<'_, PyAny>,
        offset: u64,
        size: usize,
    ) -> PyResult<Bound<'py, PyBytes>> {
        let id = object_id_from_py(id)?;
        let mut buffer = vec![0; size];
        let copied = self
            .db_mut()?
            .read_object_range(id, offset, &mut buffer)
            .map_err(zova_error)?;
        buffer.truncate(copied);
        Ok(PyBytes::new(py, &buffer))
    }

    pub(crate) fn has_object(&mut self, id: &Bound<'_, PyAny>) -> PyResult<bool> {
        let id = object_id_from_py(id)?;
        self.db_mut()?.has_object(id).map_err(zova_error)
    }

    pub(crate) fn object_size(&mut self, id: &Bound<'_, PyAny>) -> PyResult<u64> {
        let id = object_id_from_py(id)?;
        self.db_mut()?.object_size(id).map_err(zova_error)
    }

    pub(crate) fn object_chunk_count(&mut self, id: &Bound<'_, PyAny>) -> PyResult<u64> {
        let id = object_id_from_py(id)?;
        self.db_mut()?.object_chunk_count(id).map_err(zova_error)
    }

    pub(crate) fn delete_object(&mut self, id: &Bound<'_, PyAny>) -> PyResult<()> {
        let id = object_id_from_py(id)?;
        self.db_mut()?.delete_object(id).map_err(zova_error)
    }

    pub(crate) fn object_manifest(&mut self, id: &Bound<'_, PyAny>) -> PyResult<PyObjectManifest> {
        let id = object_id_from_py(id)?;
        let manifest = self.db_mut()?.object_manifest(id).map_err(zova_error)?;
        Ok(PyObjectManifest::from_rust(manifest))
    }

    pub(crate) fn get_object_chunk<'py>(
        &mut self,
        py: Python<'py>,
        hash: &Bound<'_, PyAny>,
    ) -> PyResult<Bound<'py, PyBytes>> {
        let hash = chunk_id_from_py(hash)?;
        let data = self.db_mut()?.get_object_chunk(hash).map_err(zova_error)?;
        Ok(PyBytes::new(py, &data))
    }

    pub(crate) fn has_object_chunk(&mut self, hash: &Bound<'_, PyAny>) -> PyResult<bool> {
        let hash = chunk_id_from_py(hash)?;
        self.db_mut()?.has_object_chunk(hash).map_err(zova_error)
    }

    pub(crate) fn put_object_chunk(
        &mut self,
        expected_hash: &Bound<'_, PyAny>,
        data: Vec<u8>,
    ) -> PyResult<()> {
        let expected_hash = chunk_id_from_py(expected_hash)?;
        self.db_mut()?
            .put_object_chunk(expected_hash, &data)
            .map_err(zova_error)
    }

    pub(crate) fn put_object_chunk_with_options(
        &mut self,
        expected_hash: &Bound<'_, PyAny>,
        data: Vec<u8>,
        options: &Bound<'_, PyAny>,
    ) -> PyResult<()> {
        let expected_hash = chunk_id_from_py(expected_hash)?;
        let options = put_options_from_py(options)?;
        self.db_mut()?
            .put_object_chunk_with_options(expected_hash, &data, options)
            .map_err(zova_error)
    }

    pub(crate) fn delete_object_chunk(&mut self, hash: &Bound<'_, PyAny>) -> PyResult<bool> {
        let hash = chunk_id_from_py(hash)?;
        self.db_mut()?.delete_object_chunk(hash).map_err(zova_error)
    }

    pub(crate) fn assemble_object_from_chunks(
        &mut self,
        id: &Bound<'_, PyAny>,
        size_bytes: u64,
        chunks: &Bound<'_, PyAny>,
    ) -> PyResult<()> {
        let id = object_id_from_py(id)?;
        let chunks = manifest_chunks_from_py(chunks)?;
        self.db_mut()?
            .assemble_object_from_chunks(id, size_bytes, &chunks)
            .map_err(zova_error)
    }

    pub(crate) fn assemble_object_from_chunks_with_options(
        &mut self,
        id: &Bound<'_, PyAny>,
        size_bytes: u64,
        chunks: &Bound<'_, PyAny>,
        options: &Bound<'_, PyAny>,
    ) -> PyResult<()> {
        let id = object_id_from_py(id)?;
        let chunks = manifest_chunks_from_py(chunks)?;
        let options = put_options_from_py(options)?;
        self.db_mut()?
            .assemble_object_from_chunks_with_options(id, size_bytes, &chunks, options)
            .map_err(zova_error)
    }

    pub(crate) fn object_writer(&mut self) -> PyResult<PyObjectWriter> {
        Ok(PyObjectWriter {
            inner: Some(self.db_mut()?.object_writer_owned().map_err(zova_error)?),
        })
    }

    pub(crate) fn object_writer_with_options(
        &mut self,
        options: &Bound<'_, PyAny>,
    ) -> PyResult<PyObjectWriter> {
        let options = put_options_from_py(options)?;
        Ok(PyObjectWriter {
            inner: Some(
                self.db_mut()?
                    .object_writer_owned_with_options(options)
                    .map_err(zova_error)?,
            ),
        })
    }

    pub(crate) fn object_reader(&mut self, id: &Bound<'_, PyAny>) -> PyResult<PyObjectReader> {
        let id = object_id_from_py(id)?;
        Ok(PyObjectReader {
            inner: Some(self.db_mut()?.object_reader_owned(id).map_err(zova_error)?),
        })
    }

    pub(crate) fn object_seekable_reader(
        &mut self,
        id: &Bound<'_, PyAny>,
    ) -> PyResult<crate::object::PyObjectSeekableReader> {
        let id = object_id_from_py(id)?;
        Ok(crate::object::PyObjectSeekableReader {
            inner: Some(
                self.db_mut()?
                    .object_seekable_reader_owned(id)
                    .map_err(zova_error)?,
            ),
        })
    }

    pub(crate) fn create_vector_collection(
        &mut self,
        name: &str,
        options: &Bound<'_, PyAny>,
    ) -> PyResult<()> {
        let options = collection_options_from_py(options)?;
        self.db_mut()?
            .create_vector_collection(name, options)
            .map_err(zova_error)
    }

    pub(crate) fn has_vector_collection(&mut self, name: &str) -> PyResult<bool> {
        self.db_mut()?
            .has_vector_collection(name)
            .map_err(zova_error)
    }

    pub(crate) fn vector_collection_info(
        &mut self,
        name: &str,
    ) -> PyResult<PyVectorCollectionInfo> {
        let info = self
            .db_mut()?
            .vector_collection_info(name)
            .map_err(zova_error)?;
        Ok(py_collection_info(info))
    }

    pub(crate) fn list_vector_collections(&mut self) -> PyResult<Vec<PyVectorCollectionInfo>> {
        let collections = self
            .db_mut()?
            .list_vector_collections()
            .map_err(zova_error)?;
        Ok(collections.into_iter().map(py_collection_info).collect())
    }

    pub(crate) fn delete_vector_collection(&mut self, name: &str) -> PyResult<()> {
        self.db_mut()?
            .delete_vector_collection(name)
            .map_err(zova_error)
    }

    pub(crate) fn put_vector(
        &mut self,
        collection_name: &str,
        vector_id: &str,
        element_type: i32,
        values: &Bound<'_, PyAny>,
    ) -> PyResult<()> {
        let values = vector_values_from_py(element_type, values)?;
        self.db_mut()?
            .put_vector(collection_name, vector_id, values.as_rust())
            .map_err(zova_error)
    }

    pub(crate) fn put_vectors(
        &mut self,
        collection_name: &str,
        vectors: &Bound<'_, PyAny>,
    ) -> PyResult<()> {
        let owned = vector_inputs_from_py(vectors)?;
        let refs = vector_input_refs(&owned);
        self.db_mut()?
            .put_vectors(collection_name, &refs)
            .map_err(zova_error)
    }

    pub(crate) fn get_vector(
        &mut self,
        collection_name: &str,
        vector_id: &str,
    ) -> PyResult<PyVector> {
        let vector = self
            .db_mut()?
            .get_vector(collection_name, vector_id)
            .map_err(zova_error)?;
        Ok(py_vector(vector))
    }

    pub(crate) fn has_vector(&mut self, collection_name: &str, vector_id: &str) -> PyResult<bool> {
        self.db_mut()?
            .has_vector(collection_name, vector_id)
            .map_err(zova_error)
    }

    pub(crate) fn delete_vector(&mut self, collection_name: &str, vector_id: &str) -> PyResult<()> {
        self.db_mut()?
            .delete_vector(collection_name, vector_id)
            .map_err(zova_error)
    }

    pub(crate) fn search_vectors(
        &mut self,
        collection_name: &str,
        element_type: i32,
        query: &Bound<'_, PyAny>,
        limit: usize,
    ) -> PyResult<Vec<PyVectorSearchResult>> {
        let query = vector_values_from_py(element_type, query)?;
        let results = self
            .db_mut()?
            .search_vectors(collection_name, query.as_rust(), limit)
            .map_err(zova_error)?;
        Ok(py_search_results(results))
    }

    pub(crate) fn search_vectors_in(
        &mut self,
        collection_name: &str,
        element_type: i32,
        query: &Bound<'_, PyAny>,
        candidate_ids: Vec<String>,
        limit: usize,
    ) -> PyResult<Vec<PyVectorSearchResult>> {
        let query = vector_values_from_py(element_type, query)?;
        let candidates = candidate_refs(&candidate_ids);
        let results = self
            .db_mut()?
            .search_vectors_in(collection_name, query.as_rust(), &candidates, limit)
            .map_err(zova_error)?;
        Ok(py_search_results(results))
    }

    pub(crate) fn search_vectors_within(
        &mut self,
        collection_name: &str,
        element_type: i32,
        query: &Bound<'_, PyAny>,
        max_distance: f64,
        limit: usize,
    ) -> PyResult<Vec<PyVectorSearchResult>> {
        let query = vector_values_from_py(element_type, query)?;
        let results = self
            .db_mut()?
            .search_vectors_within(collection_name, query.as_rust(), max_distance, limit)
            .map_err(zova_error)?;
        Ok(py_search_results(results))
    }

    pub(crate) fn search_vectors_in_within(
        &mut self,
        collection_name: &str,
        element_type: i32,
        query: &Bound<'_, PyAny>,
        candidate_ids: Vec<String>,
        max_distance: f64,
        limit: usize,
    ) -> PyResult<Vec<PyVectorSearchResult>> {
        let query = vector_values_from_py(element_type, query)?;
        let candidates = candidate_refs(&candidate_ids);
        let results = self
            .db_mut()?
            .search_vectors_in_within(
                collection_name,
                query.as_rust(),
                &candidates,
                max_distance,
                limit,
            )
            .map_err(zova_error)?;
        Ok(py_search_results(results))
    }

    pub(crate) fn search_vectors_by_id(
        &mut self,
        collection_name: &str,
        source_vector_id: &str,
        limit: usize,
    ) -> PyResult<Vec<PyVectorSearchResult>> {
        let results = self
            .db_mut()?
            .search_vectors_by_id(collection_name, source_vector_id, limit)
            .map_err(zova_error)?;
        Ok(py_search_results(results))
    }

    pub(crate) fn search_vectors_by_id_in(
        &mut self,
        collection_name: &str,
        source_vector_id: &str,
        candidate_ids: Vec<String>,
        limit: usize,
    ) -> PyResult<Vec<PyVectorSearchResult>> {
        let candidates = candidate_refs(&candidate_ids);
        let results = self
            .db_mut()?
            .search_vectors_by_id_in(collection_name, source_vector_id, &candidates, limit)
            .map_err(zova_error)?;
        Ok(py_search_results(results))
    }

    pub(crate) fn search_vectors_by_id_within(
        &mut self,
        collection_name: &str,
        source_vector_id: &str,
        max_distance: f64,
        limit: usize,
    ) -> PyResult<Vec<PyVectorSearchResult>> {
        let results = self
            .db_mut()?
            .search_vectors_by_id_within(collection_name, source_vector_id, max_distance, limit)
            .map_err(zova_error)?;
        Ok(py_search_results(results))
    }

    pub(crate) fn search_vectors_by_id_in_within(
        &mut self,
        collection_name: &str,
        source_vector_id: &str,
        candidate_ids: Vec<String>,
        max_distance: f64,
        limit: usize,
    ) -> PyResult<Vec<PyVectorSearchResult>> {
        let candidates = candidate_refs(&candidate_ids);
        let results = self
            .db_mut()?
            .search_vectors_by_id_in_within(
                collection_name,
                source_vector_id,
                &candidates,
                max_distance,
                limit,
            )
            .map_err(zova_error)?;
        Ok(py_search_results(results))
    }

    pub(crate) fn create_graph(&mut self, name: &str) -> PyResult<()> {
        self.db_mut()?.create_graph(name).map_err(zova_error)
    }

    pub(crate) fn has_graph(&mut self, name: &str) -> PyResult<bool> {
        self.db_mut()?.has_graph(name).map_err(zova_error)
    }

    pub(crate) fn graph_info(&mut self, name: &str) -> PyResult<PyGraphInfo> {
        let info = self.db_mut()?.graph_info(name).map_err(zova_error)?;
        Ok(py_graph_info(info))
    }

    pub(crate) fn list_graphs(&mut self) -> PyResult<Vec<PyGraphInfo>> {
        let graphs = self.db_mut()?.list_graphs().map_err(zova_error)?;
        Ok(graphs.into_iter().map(py_graph_info).collect())
    }

    pub(crate) fn delete_graph(&mut self, name: &str) -> PyResult<()> {
        self.db_mut()?.delete_graph(name).map_err(zova_error)
    }

    pub(crate) fn put_graph_node(&mut self, input: &Bound<'_, PyAny>) -> PyResult<()> {
        let input = node_input_from_py(input)?;
        self.db_mut()?
            .put_graph_node(input.as_rust())
            .map_err(zova_error)
    }

    pub(crate) fn get_graph_node(
        &mut self,
        graph_name: &str,
        node_id: &str,
    ) -> PyResult<PyGraphNode> {
        let node = self
            .db_mut()?
            .get_graph_node(graph_name, node_id)
            .map_err(zova_error)?;
        Ok(py_graph_node(node))
    }

    pub(crate) fn has_graph_node(&mut self, graph_name: &str, node_id: &str) -> PyResult<bool> {
        self.db_mut()?
            .has_graph_node(graph_name, node_id)
            .map_err(zova_error)
    }

    pub(crate) fn delete_graph_node(&mut self, graph_name: &str, node_id: &str) -> PyResult<()> {
        self.db_mut()?
            .delete_graph_node(graph_name, node_id)
            .map_err(zova_error)
    }

    pub(crate) fn put_graph_edge(&mut self, input: &Bound<'_, PyAny>) -> PyResult<()> {
        let input = edge_input_from_py(input)?;
        self.db_mut()?
            .put_graph_edge(input.as_rust())
            .map_err(zova_error)
    }

    pub(crate) fn get_graph_edge(
        &mut self,
        graph_name: &str,
        from_node_id: &str,
        edge_type: &str,
        to_node_id: &str,
    ) -> PyResult<PyGraphEdge> {
        let edge = self
            .db_mut()?
            .get_graph_edge(graph_name, from_node_id, edge_type, to_node_id)
            .map_err(zova_error)?;
        Ok(py_graph_edge(edge))
    }

    pub(crate) fn has_graph_edge(
        &mut self,
        graph_name: &str,
        from_node_id: &str,
        edge_type: &str,
        to_node_id: &str,
    ) -> PyResult<bool> {
        self.db_mut()?
            .has_graph_edge(graph_name, from_node_id, edge_type, to_node_id)
            .map_err(zova_error)
    }

    pub(crate) fn delete_graph_edge(&mut self, input: &Bound<'_, PyAny>) -> PyResult<()> {
        let input = edge_input_from_py(input)?;
        self.db_mut()?
            .delete_graph_edge(input.as_rust())
            .map_err(zova_error)
    }

    pub(crate) fn graph_neighbors(
        &mut self,
        options: &Bound<'_, PyAny>,
    ) -> PyResult<Vec<PyGraphNeighbor>> {
        let options = neighbors_options_from_py(options)?;
        let neighbors = self
            .db_mut()?
            .graph_neighbors(options.as_rust())
            .map_err(zova_error)?;
        Ok(py_graph_neighbors(neighbors))
    }

    pub(crate) fn graph_walk(
        &mut self,
        options: &Bound<'_, PyAny>,
    ) -> PyResult<Vec<PyGraphWalkItem>> {
        let options = walk_options_from_py(options)?;
        let items = self
            .db_mut()?
            .graph_walk(options.as_rust())
            .map_err(zova_error)?;
        Ok(py_graph_walk(items))
    }

    /// Upgrade an installed extension to the linked or bundled code's newer
    /// version. Open the database with `open_for_extension_upgrade` first.
    pub(crate) fn extension_upgrade(&mut self, name: &str) -> PyResult<()> {
        self.db_mut()?.extension_upgrade(name).map_err(zova_error)
    }

    /// Rebuild an extension's derived storage at its installed version.
    pub(crate) fn extension_rebuild(&mut self, name: &str) -> PyResult<()> {
        self.db_mut()?.extension_rebuild(name).map_err(zova_error)
    }

    /// Insert or replace `GraphNodeInput` values atomically.
    pub(crate) fn put_graph_nodes(&mut self, inputs: &Bound<'_, PyAny>) -> PyResult<()> {
        let owned = node_inputs_from_py(inputs)?;
        let refs = owned
            .iter()
            .map(|input| input.as_rust())
            .collect::<Vec<_>>();
        self.db_mut()?.put_graph_nodes(&refs).map_err(zova_error)
    }

    /// Insert `GraphEdgeInput` values atomically.
    pub(crate) fn put_graph_edges(&mut self, inputs: &Bound<'_, PyAny>) -> PyResult<()> {
        let owned = edge_inputs_from_py(inputs)?;
        let refs = owned
            .iter()
            .map(|input| input.as_rust())
            .collect::<Vec<_>>();
        self.db_mut()?.put_graph_edges(&refs).map_err(zova_error)
    }

    /// Delete nodes and their incident edges atomically.
    pub(crate) fn delete_graph_nodes(
        &mut self,
        graph_name: &str,
        node_ids: Vec<String>,
    ) -> PyResult<()> {
        let refs = node_ids.iter().map(String::as_str).collect::<Vec<_>>();
        self.db_mut()?
            .delete_graph_nodes(graph_name, &refs)
            .map_err(zova_error)
    }

    /// Delete `GraphEdgeInput` edges atomically.
    pub(crate) fn delete_graph_edges(&mut self, inputs: &Bound<'_, PyAny>) -> PyResult<()> {
        let owned = edge_inputs_from_py(inputs)?;
        let refs = owned
            .iter()
            .map(|input| input.as_rust())
            .collect::<Vec<_>>();
        self.db_mut()?.delete_graph_edges(&refs).map_err(zova_error)
    }

    /// Count a node's edges in `direction`, optionally of one edge type.
    #[pyo3(signature = (graph_name, node_id, direction, edge_type = None))]
    pub(crate) fn graph_degree(
        &mut self,
        graph_name: &str,
        node_id: &str,
        direction: i32,
        edge_type: Option<String>,
    ) -> PyResult<u64> {
        let options = zova_rust::GraphDegreeOptions {
            graph_name,
            node_id,
            direction: direction_from_i32(direction)?,
            edge_type: edge_type.as_deref(),
        };
        self.db_mut()?.graph_degree(options).map_err(zova_error)
    }

    /// Insert or replace nodes atomically; returns their keys in input order.
    pub(crate) fn put_graph_nodes_keyed(
        &mut self,
        inputs: &Bound<'_, PyAny>,
    ) -> PyResult<Vec<i64>> {
        let owned = node_inputs_from_py(inputs)?;
        let refs = owned
            .iter()
            .map(|input| input.as_rust())
            .collect::<Vec<_>>();
        self.db_mut()?
            .put_graph_nodes_keyed(&refs)
            .map_err(zova_error)
    }

    /// Insert edges atomically; returns their keys in input order.
    pub(crate) fn put_graph_edges_keyed(
        &mut self,
        inputs: &Bound<'_, PyAny>,
    ) -> PyResult<Vec<i64>> {
        let owned = edge_inputs_from_py(inputs)?;
        let refs = owned
            .iter()
            .map(|input| input.as_rust())
            .collect::<Vec<_>>();
        self.db_mut()?
            .put_graph_edges_keyed(&refs)
            .map_err(zova_error)
    }

    /// Nodes by key, aligned with `node_keys`; missing keys yield None.
    pub(crate) fn get_graph_nodes_keyed(
        &mut self,
        graph_name: &str,
        node_keys: Vec<i64>,
    ) -> PyResult<Vec<Option<PyGraphKeyedNode>>> {
        let nodes = self
            .db_mut()?
            .get_graph_nodes_keyed(graph_name, &node_keys)
            .map_err(zova_error)?;
        Ok(nodes
            .into_iter()
            .map(|node| node.map(py_keyed_node))
            .collect())
    }

    /// Edges by key, aligned with `edge_keys`; missing keys yield None.
    pub(crate) fn get_graph_edges_keyed(
        &mut self,
        graph_name: &str,
        edge_keys: Vec<i64>,
    ) -> PyResult<Vec<Option<PyGraphKeyedEdge>>> {
        let edges = self
            .db_mut()?
            .get_graph_edges_keyed(graph_name, &edge_keys)
            .map_err(zova_error)?;
        Ok(edges
            .into_iter()
            .map(|edge| edge.map(py_keyed_edge))
            .collect())
    }

    /// `graph_neighbors` with edge and neighbor keys.
    pub(crate) fn graph_neighbors_keyed(
        &mut self,
        options: &Bound<'_, PyAny>,
    ) -> PyResult<Vec<PyGraphKeyedNeighbor>> {
        let options = neighbors_options_from_py(options)?;
        let neighbors = self
            .db_mut()?
            .graph_neighbors_keyed(options.as_rust())
            .map_err(zova_error)?;
        Ok(py_keyed_neighbors(neighbors))
    }

    /// Degrees aligned with `node_keys`.
    #[pyo3(signature = (graph_name, node_keys, direction, edge_type = None))]
    pub(crate) fn graph_degrees_keyed(
        &mut self,
        graph_name: &str,
        node_keys: Vec<i64>,
        direction: i32,
        edge_type: Option<String>,
    ) -> PyResult<Vec<u64>> {
        let options = zova_rust::GraphKeyedDegreeOptions {
            graph_name,
            node_keys: &node_keys,
            direction: direction_from_i32(direction)?,
            edge_type: edge_type.as_deref(),
        };
        self.db_mut()?
            .graph_degrees_keyed(options)
            .map_err(zova_error)
    }

    /// Edge payloads aligned with `edge_keys`. A missing edge yields None and
    /// an edge without a payload yields empty bytes.
    pub(crate) fn get_graph_edge_payloads<'py>(
        &mut self,
        py: Python<'py>,
        graph_name: &str,
        edge_keys: Vec<i64>,
    ) -> PyResult<Vec<Option<Bound<'py, PyBytes>>>> {
        let payloads = self
            .db_mut()?
            .get_graph_edge_payloads(graph_name, &edge_keys)
            .map_err(zova_error)?;
        Ok(payloads
            .into_iter()
            .map(|payload| payload.map(|payload| PyBytes::new(py, &payload)))
            .collect())
    }

    /// Replace edge payloads atomically from `(edge_key, payload)` pairs.
    pub(crate) fn replace_graph_edge_payloads(
        &mut self,
        graph_name: &str,
        replacements: Vec<(i64, Vec<u8>)>,
    ) -> PyResult<()> {
        let refs = replacements
            .iter()
            .map(
                |(edge_key, payload)| zova_rust::GraphEdgePayloadReplacement {
                    edge_key: *edge_key,
                    payload,
                },
            )
            .collect::<Vec<_>>();
        self.db_mut()?
            .replace_graph_edge_payloads(graph_name, &refs)
            .map_err(zova_error)
    }

    /// Page through nodes and edges in creation order. Each cursor is a
    /// `(created_order, key)` pair taken from the last item of the previous
    /// page; `(0, 0)` starts from the beginning.
    #[pyo3(signature = (graph_name, *, node_limit, edge_limit, node_after = (0, 0), edge_after = (0, 0)))]
    pub(crate) fn graph_scan(
        &mut self,
        graph_name: &str,
        node_limit: usize,
        edge_limit: usize,
        node_after: (i64, i64),
        edge_after: (i64, i64),
    ) -> PyResult<PyGraphScanPage> {
        let options = zova_rust::GraphScanOptions {
            graph_name,
            node_after: zova_rust::GraphScanCursor {
                created_order: node_after.0,
                key: node_after.1,
            },
            edge_after: zova_rust::GraphScanCursor {
                created_order: edge_after.0,
                key: edge_after.1,
            },
            node_limit,
            edge_limit,
        };
        let page = self.db_mut()?.graph_scan(options).map_err(zova_error)?;
        Ok(py_scan_page(page))
    }

    /// Directional bounded breadth-first walk from `GraphWalkDirectionOptions`.
    /// The start node is returned at depth 0 and counts toward `limit`.
    pub(crate) fn graph_walk_direction(
        &mut self,
        options: &Bound<'_, PyAny>,
    ) -> PyResult<Vec<PyGraphWalkItem>> {
        let options = walk_direction_options_from_py(options)?;
        let items = self
            .db_mut()?
            .graph_walk_direction(options.as_rust()?)
            .map_err(zova_error)?;
        Ok(py_graph_walk(items))
    }

    /// `graph_walk_direction` plus a `GraphWalkProfile`.
    pub(crate) fn graph_walk_direction_profiled(
        &mut self,
        options: &Bound<'_, PyAny>,
    ) -> PyResult<(Vec<PyGraphWalkItem>, PyGraphWalkProfile)> {
        let options = walk_direction_options_from_py(options)?;
        let (items, profile) = self
            .db_mut()?
            .graph_walk_direction_profiled(options.as_rust()?)
            .map_err(zova_error)?;
        Ok((py_graph_walk(items), py_walk_profile(profile)))
    }

    /// Build one graph into an empty graph store, normalizing the input.
    /// Returns `(node_keys, edge_keys)`.
    pub(crate) fn build_fresh_graph_keyed(
        &mut self,
        graph_name: &str,
        nodes: &Bound<'_, PyAny>,
        edges: &Bound<'_, PyAny>,
    ) -> PyResult<(Vec<i64>, Vec<i64>)> {
        let nodes = fresh_nodes_from_py(nodes)?;
        let edges = fresh_edges_from_py(edges)?;
        let keys = self
            .db_mut()?
            .build_fresh_graph_keyed(
                graph_name,
                &fresh_node_refs(&nodes)?,
                &fresh_edge_refs(&edges)?,
            )
            .map_err(zova_error)?;
        Ok((keys.node_keys, keys.edge_keys))
    }

    /// Trusted build: nodes must be unique final-order rows and edges
    /// deduplicated final-order topology. Violations fail atomically.
    pub(crate) fn build_fresh_graph_prepared_keyed(
        &mut self,
        graph_name: &str,
        nodes: &Bound<'_, PyAny>,
        edges: &Bound<'_, PyAny>,
    ) -> PyResult<(Vec<i64>, Vec<i64>)> {
        let nodes = fresh_nodes_from_py(nodes)?;
        let edges = fresh_edges_from_py(edges)?;
        let keys = self
            .db_mut()?
            .build_fresh_graph_prepared_keyed(
                graph_name,
                &fresh_node_refs(&nodes)?,
                &fresh_edge_refs(&edges)?,
            )
            .map_err(zova_error)?;
        Ok((keys.node_keys, keys.edge_keys))
    }

    /// `build_fresh_graph_prepared_keyed` with edge payloads.
    pub(crate) fn build_fresh_graph_prepared_keyed_with_payloads(
        &mut self,
        graph_name: &str,
        nodes: &Bound<'_, PyAny>,
        edges: &Bound<'_, PyAny>,
    ) -> PyResult<(Vec<i64>, Vec<i64>)> {
        let nodes = fresh_nodes_from_py(nodes)?;
        let edges = fresh_edges_from_py(edges)?;
        let keys = self
            .db_mut()?
            .build_fresh_graph_prepared_keyed_with_payloads(
                graph_name,
                &fresh_node_refs(&nodes)?,
                &fresh_edge_payload_refs(&edges),
            )
            .map_err(zova_error)?;
        Ok((keys.node_keys, keys.edge_keys))
    }

    /// Delete vectors atomically. Missing ids are ignored.
    pub(crate) fn delete_vectors(
        &mut self,
        collection_name: &str,
        vector_ids: Vec<String>,
    ) -> PyResult<()> {
        let refs = candidate_refs(&vector_ids);
        self.db_mut()?
            .delete_vectors(collection_name, &refs)
            .map_err(zova_error)
    }

    /// Raw-i8 cosine search with `query_count` contiguous query rows of
    /// `dimensions` values each in `query_values`. Each vector is scored by
    /// its least similar query row. `mode` and `aggregation` take
    /// `VectorMultiI8SearchMode` and `VectorMultiI8Aggregation` values. Empty
    /// `candidate_ids` searches the whole collection.
    #[pyo3(signature = (collection_name, query_values, query_count, dimensions, *, limit, candidate_ids = Vec::new(), mode = 0, aggregation = 0, prefilter_query_index = 0, prefilter_limit = 0))]
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn search_vectors_multi_i8(
        &mut self,
        collection_name: &str,
        query_values: Vec<i8>,
        query_count: usize,
        dimensions: usize,
        limit: usize,
        candidate_ids: Vec<String>,
        mode: i32,
        aggregation: i32,
        prefilter_query_index: usize,
        prefilter_limit: usize,
    ) -> PyResult<Vec<PyVectorSearchResult>> {
        let mode = match mode {
            0 => zova_rust::VectorMultiI8SearchMode::GlobalMinCosine,
            1 => zova_rust::VectorMultiI8SearchMode::CbmPrefilterMinCosine,
            _ => {
                return Err(PyValueError::new_err(format!(
                    "invalid multi-i8 search mode {mode}; expected 0 or 1"
                )))
            }
        };
        let aggregation = match aggregation {
            0 => zova_rust::VectorMultiI8Aggregation::MinCosine,
            _ => {
                return Err(PyValueError::new_err(format!(
                    "invalid multi-i8 aggregation {aggregation}; expected 0"
                )))
            }
        };
        let candidates = candidate_refs(&candidate_ids);
        let results = self
            .db_mut()?
            .search_vectors_multi_i8(zova_rust::VectorMultiI8SearchOptions {
                collection_name,
                query_values: &query_values,
                query_count,
                dimensions,
                candidate_ids: &candidates,
                mode,
                aggregation,
                prefilter_query_index,
                prefilter_limit,
                limit,
            })
            .map_err(zova_error)?;
        Ok(py_search_results(results))
    }

    /// Start a `FreshBuild` session. Requires `PRAGMA foreign_keys=ON`, empty
    /// object, vector, and graph stores, and no live statements or writers.
    pub(crate) fn begin_fresh_build(&mut self) -> PyResult<PyFreshBuild> {
        let build = self
            .db_mut()?
            .begin_fresh_build_owned()
            .map_err(zova_error)?;
        Ok(PyFreshBuild::new(build))
    }

    /// Register a scalar SQL function on this connection.
    ///
    /// `name` is an ASCII identifier of 1-64 bytes without a `zova_` or
    /// `_zova_` prefix; `arity` is -1 for any argument count or 0-127. A name
    /// and arity pair can be registered once per connection. `function`
    /// receives None, int, float, str, or bytes arguments and returns one of
    /// those types. An exception, or another return type, fails the SQL
    /// statement with its message. The function runs while the connection is
    /// busy and must not use this database or its statements, readers, or
    /// writers; doing so deadlocks.
    #[pyo3(signature = (name, arity, function, *, deterministic = false, direct_only = false, innocuous = false))]
    pub(crate) fn register_function(
        &mut self,
        name: &str,
        arity: i32,
        function: Py<PyAny>,
        deterministic: bool,
        direct_only: bool,
        innocuous: bool,
    ) -> PyResult<()> {
        let flags = zova_rust::SqlFunctionFlags {
            deterministic,
            direct_only,
            innocuous,
        };
        self.db_mut()?
            .register_function(name, arity, flags, move |args| {
                sql_function::call(&function, args)
            })
            .map_err(zova_error)
    }

    pub(crate) fn __enter__(slf: PyRefMut<'_, Self>) -> PyRefMut<'_, Self> {
        slf
    }

    pub(crate) fn kv_get<'py>(
        &mut self,
        py: Python<'py>,
        namespace: Vec<u8>,
        key: Vec<u8>,
    ) -> PyResult<Option<Bound<'py, PyBytes>>> {
        match self
            .db_mut()?
            .kv_get(&namespace, &key)
            .map_err(zova_error)?
        {
            Some(value) => Ok(Some(PyBytes::new(py, &value))),
            None => Ok(None),
        }
    }

    #[pyo3(signature = (namespace, keys))]
    pub(crate) fn kv_get_many<'py>(
        &mut self,
        py: Python<'py>,
        namespace: Vec<u8>,
        keys: Vec<Vec<u8>>,
    ) -> PyResult<Vec<Option<Bound<'py, PyBytes>>>> {
        let key_refs: Vec<&[u8]> = keys.iter().map(|key| key.as_slice()).collect();
        let values = self
            .db_mut()?
            .kv_get_many(&namespace, &key_refs)
            .map_err(zova_error)?;
        Ok(values
            .into_iter()
            .map(|value| value.map(|value| PyBytes::new(py, &value)))
            .collect())
    }

    pub(crate) fn kv_put(
        &mut self,
        namespace: Vec<u8>,
        key: Vec<u8>,
        value: Vec<u8>,
    ) -> PyResult<()> {
        self.db_mut()?
            .kv_put(&namespace, &key, &value)
            .map_err(zova_error)
    }

    #[pyo3(signature = (namespace, entries))]
    pub(crate) fn kv_put_many(
        &mut self,
        namespace: Vec<u8>,
        entries: Vec<(Vec<u8>, Vec<u8>)>,
    ) -> PyResult<()> {
        let rust_entries: Vec<zova_rust::KvEntry> = entries
            .iter()
            .map(|(key, value)| zova_rust::KvEntry::new(key, value))
            .collect();
        self.db_mut()?
            .kv_put_many(&namespace, &rust_entries)
            .map_err(zova_error)
    }

    pub(crate) fn kv_delete(&mut self, namespace: Vec<u8>, key: Vec<u8>) -> PyResult<()> {
        self.db_mut()?
            .kv_delete(&namespace, &key)
            .map_err(zova_error)
    }

    #[pyo3(signature = (namespace, keys))]
    pub(crate) fn kv_delete_many(
        &mut self,
        namespace: Vec<u8>,
        keys: Vec<Vec<u8>>,
    ) -> PyResult<()> {
        let key_refs: Vec<&[u8]> = keys.iter().map(|key| key.as_slice()).collect();
        self.db_mut()?
            .kv_delete_many(&namespace, &key_refs)
            .map_err(zova_error)
    }

    pub(crate) fn kv_count(&mut self, namespace: Vec<u8>) -> PyResult<u64> {
        self.db_mut()?.kv_count(&namespace).map_err(zova_error)
    }

    pub(crate) fn kv_clear_namespace(&mut self, namespace: Vec<u8>) -> PyResult<()> {
        self.db_mut()?
            .kv_clear_namespace(&namespace)
            .map_err(zova_error)
    }

    /// Return one page of a namespace in ascending key byte order as
    /// `(entries, has_more)`, where entries is a list of `(key, value)` pairs.
    ///
    /// Keys compare as raw bytes: a shorter key sorts before every longer key
    /// it prefixes. `start` is inclusive, `end` exclusive, and `after` skips
    /// through the given key; pass the last returned key as `after` to
    /// continue. Every value is `b""` when `keys_only` is true.
    #[pyo3(signature = (namespace, *, limit, prefix = Vec::new(), start = None, end = None, after = None, keys_only = false))]
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn kv_scan<'py>(
        &mut self,
        py: Python<'py>,
        namespace: Vec<u8>,
        limit: usize,
        prefix: Vec<u8>,
        start: Option<Vec<u8>>,
        end: Option<Vec<u8>>,
        after: Option<Vec<u8>>,
        keys_only: bool,
    ) -> PyResult<(Vec<(Bound<'py, PyBytes>, Bound<'py, PyBytes>)>, bool)> {
        let page = self
            .db_mut()?
            .kv_scan(
                &namespace,
                &zova_rust::KvScanOptions {
                    prefix: &prefix,
                    start: start.as_deref(),
                    end: end.as_deref(),
                    after: after.as_deref(),
                    limit,
                    keys_only,
                },
            )
            .map_err(zova_error)?;
        let entries = page
            .entries
            .iter()
            .map(|entry| (PyBytes::new(py, &entry.key), PyBytes::new(py, &entry.value)))
            .collect();
        Ok((entries, page.has_more))
    }

    /// Insert one entry only when its key is absent. Returns whether it was written.
    pub(crate) fn kv_put_if_absent(
        &mut self,
        namespace: Vec<u8>,
        key: Vec<u8>,
        value: Vec<u8>,
    ) -> PyResult<bool> {
        self.db_mut()?
            .kv_put_if_absent(&namespace, &key, &value)
            .map_err(zova_error)
    }

    /// Replace one value only when the current value equals `expected` byte
    /// for byte. A missing key never matches. Returns whether it was written.
    pub(crate) fn kv_compare_and_put(
        &mut self,
        namespace: Vec<u8>,
        key: Vec<u8>,
        expected: Vec<u8>,
        value: Vec<u8>,
    ) -> PyResult<bool> {
        self.db_mut()?
            .kv_compare_and_put(&namespace, &key, &expected, &value)
            .map_err(zova_error)
    }

    /// Delete one entry only when its current value equals `expected` byte
    /// for byte. A missing key never matches. Returns whether it was deleted.
    pub(crate) fn kv_compare_and_delete(
        &mut self,
        namespace: Vec<u8>,
        key: Vec<u8>,
        expected: Vec<u8>,
    ) -> PyResult<bool> {
        self.db_mut()?
            .kv_compare_and_delete(&namespace, &key, &expected)
            .map_err(zova_error)
    }

    pub(crate) fn __exit__(
        &mut self,
        _exc_type: Option<&Bound<'_, PyAny>>,
        _exc_value: Option<&Bound<'_, PyAny>>,
        _traceback: Option<&Bound<'_, PyAny>>,
    ) -> bool {
        self.close();
        false
    }
}

impl PyDatabase {
    pub(crate) fn db_mut(&mut self) -> PyResult<&mut zova_rust::Database> {
        self.inner.as_mut().ok_or_else(|| closed_error("database"))
    }
}

#[pymethods]
impl PySavepointContext {
    pub(crate) fn __enter__(&mut self, py: Python<'_>) -> PyResult<Py<PyDatabase>> {
        self.database
            .borrow_mut(py)
            .savepoint(&self.name)
            .map_err(|err| err)?;
        self.active = true;
        Ok(self.database.clone_ref(py))
    }

    pub(crate) fn __exit__(
        &mut self,
        py: Python<'_>,
        exc_type: Option<&Bound<'_, PyAny>>,
        _exc_value: Option<&Bound<'_, PyAny>>,
        _traceback: Option<&Bound<'_, PyAny>>,
    ) -> PyResult<bool> {
        if !self.active {
            return Ok(false);
        }
        self.active = false;

        let mut database = self.database.borrow_mut(py);
        if exc_type.is_some() {
            database.rollback_to_savepoint(&self.name)?;
            database.release_savepoint(&self.name)?;
            return Ok(false);
        }
        database.release_savepoint(&self.name)?;
        Ok(false)
    }
}

#[pyfunction]
pub(crate) fn convert_sqlite_to_zova(source: &str, destination: &str) -> PyResult<()> {
    zova_rust::Database::convert_sqlite_to_zova(source, destination).map_err(zova_error)
}

#[pyfunction]
#[pyo3(signature = (source, destination, *, verify = true))]
pub(crate) fn restore_backup(source: &str, destination: &str, verify: bool) -> PyResult<()> {
    zova_rust::restore_backup(source, destination, zova_rust::RestoreOptions { verify })
        .map_err(zova_error)
}

/// What `Database.reclaim_space` did for one member file.
///
/// `member` is "main", "object_store", "vector_store", or "graph_store";
/// `auto_vacuum` is "none", "full", or "incremental". When it is "none", the
/// member releases nothing and only `compact_to` drops its free pages.
#[pyclass(name = "ReclaimedMember", frozen, skip_from_py_object)]
pub(crate) struct PyReclaimedMember {
    #[pyo3(get)]
    member: &'static str,
    #[pyo3(get)]
    auto_vacuum: &'static str,
    #[pyo3(get)]
    page_size: u32,
    #[pyo3(get)]
    pages_released: u64,
    #[pyo3(get)]
    free_pages_left: u64,
}

#[pymethods]
impl PyReclaimedMember {
    fn __repr__(&self) -> String {
        format!(
            "ReclaimedMember(member='{}', auto_vacuum='{}', page_size={}, \
             pages_released={}, free_pages_left={})",
            self.member,
            self.auto_vacuum,
            self.page_size,
            self.pages_released,
            self.free_pages_left
        )
    }
}

impl From<zova_rust::ReclaimedMember> for PyReclaimedMember {
    fn from(member: zova_rust::ReclaimedMember) -> Self {
        Self {
            member: match member.member {
                zova_rust::ProgressMember::Main => "main",
                zova_rust::ProgressMember::ObjectStore => "object_store",
                zova_rust::ProgressMember::VectorStore => "vector_store",
                zova_rust::ProgressMember::GraphStore => "graph_store",
                _ => "unknown",
            },
            auto_vacuum: member.auto_vacuum.name(),
            page_size: member.page_size,
            pages_released: member.pages_released,
            free_pages_left: member.free_pages_left,
        }
    }
}

fn progress_member_name(member: zova_rust::ProgressMember) -> &'static str {
    match member {
        zova_rust::ProgressMember::Main => "main",
        zova_rust::ProgressMember::ObjectStore => "object_store",
        zova_rust::ProgressMember::VectorStore => "vector_store",
        zova_rust::ProgressMember::GraphStore => "graph_store",
        _ => "unknown",
    }
}

fn parse_journal_mode(mode: &str) -> PyResult<zova_rust::JournalMode> {
    Ok(match mode {
        "delete" => zova_rust::JournalMode::Delete,
        "truncate" => zova_rust::JournalMode::Truncate,
        "persist" => zova_rust::JournalMode::Persist,
        "memory" => zova_rust::JournalMode::Memory,
        "wal" => zova_rust::JournalMode::Wal,
        "off" => zova_rust::JournalMode::Off,
        _ => {
            return Err(PyValueError::new_err(
                "journal mode must be 'delete', 'truncate', 'persist' or 'wal'",
            ))
        }
    })
}

/// Journal mode of one member of a database set.
///
/// `member` is "main", "object_store", "vector_store", or "graph_store";
/// `journal_mode` is "delete", "truncate", "persist", "memory", "wal" or "off".
#[pyclass(name = "JournalModeMember", frozen, skip_from_py_object)]
pub(crate) struct PyJournalModeMember {
    #[pyo3(get)]
    member: &'static str,
    #[pyo3(get)]
    journal_mode: &'static str,
}

#[pymethods]
impl PyJournalModeMember {
    fn __repr__(&self) -> String {
        format!(
            "JournalModeMember(member='{}', journal_mode='{}')",
            self.member, self.journal_mode
        )
    }
}

impl From<zova_rust::JournalModeMember> for PyJournalModeMember {
    fn from(member: zova_rust::JournalModeMember) -> Self {
        Self {
            member: progress_member_name(member.member),
            journal_mode: member.journal_mode.name(),
        }
    }
}

/// What `Database.checkpoint` did for one member file. `busy` is true when
/// another handle kept the checkpoint from finishing; the frame counts are 0
/// when the member is not in WAL mode.
#[pyclass(name = "CheckpointedMember", frozen, skip_from_py_object)]
pub(crate) struct PyCheckpointedMember {
    #[pyo3(get)]
    member: &'static str,
    #[pyo3(get)]
    journal_mode: &'static str,
    #[pyo3(get)]
    busy: bool,
    #[pyo3(get)]
    wal_frames: u64,
    #[pyo3(get)]
    checkpointed_frames: u64,
}

#[pymethods]
impl PyCheckpointedMember {
    fn __repr__(&self) -> String {
        format!(
            "CheckpointedMember(member='{}', journal_mode='{}', busy={}, \
             wal_frames={}, checkpointed_frames={})",
            self.member,
            self.journal_mode,
            if self.busy { "True" } else { "False" },
            self.wal_frames,
            self.checkpointed_frames
        )
    }
}

impl From<zova_rust::CheckpointedMember> for PyCheckpointedMember {
    fn from(member: zova_rust::CheckpointedMember) -> Self {
        Self {
            member: progress_member_name(member.member),
            journal_mode: member.journal_mode.name(),
            busy: member.busy,
            wal_frames: member.wal_frames,
            checkpointed_frames: member.checkpointed_frames,
        }
    }
}

/// Storage-format facts about a `.zova` file, reported without opening or
/// mutating the file.
///
/// `compatibility` is the raw C ABI `zova_format_compatibility` code; the
/// public Python `zova.probe_format` wrapper converts it into the
/// `FormatCompatibility` enum.
#[pyclass(name = "FormatInfo", frozen, skip_from_py_object)]
#[derive(Clone)]
pub(crate) struct PyFormatInfo {
    #[pyo3(get)]
    format_version: u32,
    #[pyo3(get)]
    compatibility: i32,
}

/// Probe a `.zova` file's storage format without opening or mutating it.
///
/// The probe never requires an open database handle and never writes to the
/// probed file.
#[pyfunction]
pub(crate) fn probe_format(path: &str) -> PyResult<PyFormatInfo> {
    let info = zova_rust::probe_format(path).map_err(zova_error)?;
    Ok(PyFormatInfo {
        format_version: info.format_version,
        compatibility: info.compatibility as i32,
    })
}

/// Migrate a `.zova` file forward to this release's storage format.
///
/// Migration is explicit, copy-forward, and source-preserving: the source file
/// is never mutated, the destination must not already exist, and any failure
/// removes attempted output. When `verify` is true (the default), the migrated
/// destination is verified after the copy. A database with a non-bundled
/// extension installed needs that extension's trusted bundle in
/// `extension_bundles` or its `LinkedPlugin` in `plugins`, exactly as
/// `Database.open` does.
///
/// `progress`, when given, is called with a `Progress` event on this thread.
/// An exception it raises cancels the migration, which leaves the source
/// unchanged and creates no destination, and propagates.
#[pyfunction]
#[pyo3(signature = (source, destination, *, verify = true, extension_bundles = None, trust_store_path = None, progress = None, plugins = None))]
pub(crate) fn migrate_database(
    source: &str,
    destination: &str,
    verify: bool,
    extension_bundles: Option<Vec<String>>,
    trust_store_path: Option<String>,
    progress: Option<Py<PyAny>>,
    plugins: Option<Vec<PyRef<'_, PyLinkedPlugin>>>,
) -> PyResult<()> {
    let extensions = extension_options(extension_bundles, trust_store_path);
    let options = zova_rust::MigrateOptions { verify };
    let plugins = plugins.map(|plugins| linked_plugins(Some(plugins)));
    match (progress, plugins) {
        (None, None) => {
            zova_rust::migrate_database_with_extensions(source, destination, options, &extensions)
                .map_err(zova_error)
        }
        (None, Some(plugins)) => zova_rust::migrate_database_with_plugins(
            source,
            destination,
            options,
            &extensions,
            &plugins,
        )
        .map_err(zova_error),
        (Some(callback), plugins) => {
            let mut handler = ProgressHandler::new(callback);
            let result = match plugins {
                None => zova_rust::migrate_database_with_progress(
                    source,
                    destination,
                    options,
                    &extensions,
                    |event| handler.call(event),
                ),
                Some(plugins) => zova_rust::migrate_database_with_plugins_and_progress(
                    source,
                    destination,
                    options,
                    &extensions,
                    &plugins,
                    |event| handler.call(event),
                ),
            };
            handler.finish(result)
        }
    }
}

/// Restore a valid `.zova` backup file into a new volatile in-memory database.
///
/// The returned database owns the source's schema and data entirely in memory
/// and never creates database, WAL, or journal files.
#[pyfunction]
#[pyo3(signature = (source, *, verify = true))]
pub(crate) fn restore_backup_to_memory(source: &str, verify: bool) -> PyResult<PyDatabase> {
    let database =
        zova_rust::restore_backup_to_memory(source, zova_rust::RestoreOptions { verify })
            .map_err(zova_error)?;
    Ok(PyDatabase {
        inner: Some(database),
    })
}
