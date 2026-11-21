//! Atomic fresh-build sessions.
//!
//! A session loads user tables, FTS tables, one graph, and vectors into a
//! database whose object, vector, and graph stores are empty, then publishes
//! everything with one commit. While a session is active, every ordinary call
//! on the same native handle fails. A failed step rolls the whole session back
//! and ends it; later steps then fail with [`Status::Misuse`](crate::Status).

use crate::database::cstring;
use crate::error::{Error, Result};
use crate::graph::slice_ptr;
use crate::graph_keyed::{fresh_edge_payload_inputs, fresh_node_inputs, mut_slice_ptr};
use crate::vector::vector_inputs;
use crate::{Database, GraphFreshEdgePayloadInput, GraphFreshNodeInput, VectorInput};
use std::ptr::{self, NonNull};

/// One typed cell of row-major fresh-build input.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum FreshValue<'a> {
    Null,
    Int64(i64),
    Float64(f64),
    Text(&'a str),
    Blob(&'a [u8]),
}

/// Timings and counters reported by a committed fresh build.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct FreshBuildProfile {
    pub validation_ms: f64,
    pub table_load_ms: f64,
    pub fts_load_ms: f64,
    pub graph_load_ms: f64,
    pub graph_validation_ms: f64,
    pub graph_key_generation_ms: f64,
    pub graph_node_load_ms: f64,
    pub graph_edge_load_ms: f64,
    pub vector_load_ms: f64,
    pub index_build_ms: f64,
    pub commit_ms: f64,
    pub table_rows: u64,
    pub fts_rows: u64,
    pub vector_rows: u64,
    pub payload_bytes: u64,
}

/// Committed fresh-build output. Graph keys align with the graph step input.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct FreshBuildResult {
    pub node_keys: Vec<i64>,
    pub edge_keys: Vec<i64>,
    pub profile: FreshBuildProfile,
}

/// Active fresh-build session on a [`Database`]. Dropping an unfinished
/// session rolls it back.
pub struct FreshBuild<'db> {
    db: &'db mut Database,
    session: FreshSession,
}

impl Database {
    /// Start a fresh-build session. Requires `PRAGMA foreign_keys=ON`, empty
    /// object, vector, and graph stores, and no live statements or writers.
    pub fn begin_fresh_build(&mut self) -> Result<FreshBuild<'_>> {
        let db = self.raw_ptr();
        let session = FreshSession::begin(db, |status| self.status(status))?;
        Ok(FreshBuild { db: self, session })
    }
}

impl FreshBuild<'_> {
    /// Append row-major `values` (`columns.len()` cells per row) to an
    /// initially empty table. Indexes on the table are rebuilt at finish.
    pub fn table_rows(
        &mut self,
        table_name: &str,
        columns: &[&str],
        values: &[FreshValue<'_>],
    ) -> Result<()> {
        let db = &mut *self.db;
        self.session.rows(
            |status| db.status(status),
            table_name,
            columns,
            values,
            false,
        )
    }

    /// Append row-major `values` to an initially empty FTS table.
    pub fn fts_rows(
        &mut self,
        table_name: &str,
        columns: &[&str],
        values: &[FreshValue<'_>],
    ) -> Result<()> {
        let db = &mut *self.db;
        self.session.rows(
            |status| db.status(status),
            table_name,
            columns,
            values,
            true,
        )
    }

    /// Load the session's one graph from trusted final-order input.
    pub fn graph(
        &mut self,
        graph_name: &str,
        nodes: &[GraphFreshNodeInput<'_>],
        edges: &[GraphFreshEdgePayloadInput<'_>],
    ) -> Result<()> {
        let db = &mut *self.db;
        self.session
            .graph(|status| db.status(status), graph_name, nodes, edges)
    }

    pub fn vectors(&mut self, collection_name: &str, vectors: &[VectorInput<'_>]) -> Result<()> {
        let db = &mut *self.db;
        self.session
            .vectors(|status| db.status(status), collection_name, vectors)
    }

    /// Build deferred indexes, validate foreign keys, and commit.
    pub fn finish(mut self) -> Result<FreshBuildResult> {
        let db = &mut *self.db;
        self.session.finish(|status| db.status(status))
    }

    /// Roll the session back explicitly.
    pub fn abort(mut self) -> Result<()> {
        let db = &mut *self.db;
        self.session.abort(|status| db.status(status))
    }
}

impl Drop for FreshBuild<'_> {
    fn drop(&mut self) {
        self.session.destroy();
    }
}

/// Native session state shared by the `Database` and `SharedDatabase` wrappers.
pub(crate) struct FreshSession {
    raw: Option<NonNull<zova_sys::zova_fresh_build>>,
    active: bool,
    node_key_count: usize,
    edge_key_count: usize,
}

// The native session handle locks its database mutex for every call.
unsafe impl Send for FreshSession {}

impl FreshSession {
    pub(crate) fn begin(
        db: *mut zova_sys::zova_database,
        status: impl FnOnce(i32) -> Result<()>,
    ) -> Result<Self> {
        let mut raw = ptr::null_mut();
        let request = zova_sys::zova_fresh_build_begin_request {
            db,
            out_build: &mut raw,
        };
        status(unsafe { zova_sys::zova_fresh_build_begin(&request) })?;
        let raw = NonNull::new(raw).ok_or_else(|| {
            Error::from_status(
                zova_sys::ZOVA_MISUSE,
                Some("fresh build begin returned no session".to_owned()),
            )
        })?;
        Ok(Self {
            raw: Some(raw),
            active: true,
            node_key_count: 0,
            edge_key_count: 0,
        })
    }

    fn raw(&self) -> Result<*mut zova_sys::zova_fresh_build> {
        match self.raw {
            Some(raw) if self.active => Ok(raw.as_ptr()),
            _ => Err(Error::from_status(
                zova_sys::ZOVA_MISUSE,
                Some("fresh build session is no longer active".to_owned()),
            )),
        }
    }

    /// Run one step; any failure leaves the native session rolled back.
    fn step<T>(
        &mut self,
        f: impl FnOnce(*mut zova_sys::zova_fresh_build) -> Result<T>,
    ) -> Result<T> {
        let raw = self.raw()?;
        let result = f(raw);
        if result.is_err() {
            // Native step failures already rolled back; this covers failures
            // detected before the native call. Abort on an inactive session
            // is a harmless INVALID_ARGUMENT.
            unsafe { zova_sys::zova_fresh_build_abort(raw) };
            self.active = false;
        }
        result
    }

    pub(crate) fn rows(
        &mut self,
        status: impl FnOnce(i32) -> Result<()>,
        table_name: &str,
        columns: &[&str],
        values: &[FreshValue<'_>],
        fts: bool,
    ) -> Result<()> {
        self.step(|build| {
            let table_name = cstring(table_name, "fresh build table name")?;
            let column_names = columns
                .iter()
                .map(|column| cstring(column, "fresh build column name"))
                .collect::<Result<Vec<_>>>()?;
            let column_ptrs = column_names
                .iter()
                .map(|column| column.as_ptr())
                .collect::<Vec<_>>();
            let row_count = match columns.len() {
                0 => 0,
                count if values.len() % count == 0 => values.len() / count,
                _ => {
                    return Err(Error::from_status(
                        zova_sys::ZOVA_INVALID_ARGUMENT,
                        Some("fresh build values are not a whole number of rows".to_owned()),
                    ))
                }
            };
            let raw_values = values.iter().map(fresh_value).collect::<Vec<_>>();
            let request = zova_sys::zova_fresh_build_rows_request {
                build,
                table_name: table_name.as_ptr(),
                column_names: slice_ptr(&column_ptrs),
                column_count: column_ptrs.len(),
                values: slice_ptr(&raw_values),
                row_count,
            };
            status(unsafe {
                if fts {
                    zova_sys::zova_fresh_build_fts_rows(&request)
                } else {
                    zova_sys::zova_fresh_build_table_rows(&request)
                }
            })
        })
    }

    pub(crate) fn graph(
        &mut self,
        status: impl FnOnce(i32) -> Result<()>,
        graph_name: &str,
        nodes: &[GraphFreshNodeInput<'_>],
        edges: &[GraphFreshEdgePayloadInput<'_>],
    ) -> Result<()> {
        self.step(|build| {
            let graph_name = cstring(graph_name, "graph name")?;
            let (_node_strings, raw_nodes) = fresh_node_inputs(nodes)?;
            let (_edge_types, raw_edges) = fresh_edge_payload_inputs(edges)?;
            let request = zova_sys::zova_fresh_build_graph_request {
                build,
                graph_name: graph_name.as_ptr(),
                nodes: slice_ptr(&raw_nodes),
                nodes_len: raw_nodes.len(),
                edges: slice_ptr(&raw_edges),
                edges_len: raw_edges.len(),
                out_node_keys: ptr::null_mut(),
                out_node_keys_capacity: 0,
                out_edge_keys: ptr::null_mut(),
                out_edge_keys_capacity: 0,
            };
            status(unsafe { zova_sys::zova_fresh_build_graph(&request) })
        })?;
        self.node_key_count = nodes.len();
        self.edge_key_count = edges.len();
        Ok(())
    }

    pub(crate) fn vectors(
        &mut self,
        status: impl FnOnce(i32) -> Result<()>,
        collection_name: &str,
        vectors: &[VectorInput<'_>],
    ) -> Result<()> {
        self.step(|build| {
            let collection_name = cstring(collection_name, "vector collection name")?;
            let (_ids, raw) = vector_inputs(vectors)?;
            let request = zova_sys::zova_fresh_build_vectors_request {
                build,
                collection_name: collection_name.as_ptr(),
                vectors: slice_ptr(&raw),
                vectors_len: raw.len(),
            };
            status(unsafe { zova_sys::zova_fresh_build_vectors(&request) })
        })
    }

    pub(crate) fn finish(
        &mut self,
        status: impl FnOnce(i32) -> Result<()>,
    ) -> Result<FreshBuildResult> {
        let mut node_keys = vec![0; self.node_key_count];
        let mut edge_keys = vec![0; self.edge_key_count];
        let mut profile = zova_sys::zova_fresh_build_profile::default();
        self.step(|build| {
            let request = zova_sys::zova_fresh_build_finish_request {
                build,
                out_node_keys: mut_slice_ptr(&mut node_keys),
                out_node_keys_capacity: node_keys.len(),
                out_edge_keys: mut_slice_ptr(&mut edge_keys),
                out_edge_keys_capacity: edge_keys.len(),
                out_profile: &mut profile,
            };
            status(unsafe { zova_sys::zova_fresh_build_finish(&request) })
        })?;
        self.active = false;
        Ok(FreshBuildResult {
            node_keys,
            edge_keys,
            profile: FreshBuildProfile {
                validation_ms: profile.validation_ms,
                table_load_ms: profile.table_load_ms,
                fts_load_ms: profile.fts_load_ms,
                graph_load_ms: profile.graph_load_ms,
                graph_validation_ms: profile.graph_validation_ms,
                graph_key_generation_ms: profile.graph_key_generation_ms,
                graph_node_load_ms: profile.graph_node_load_ms,
                graph_edge_load_ms: profile.graph_edge_load_ms,
                vector_load_ms: profile.vector_load_ms,
                index_build_ms: profile.index_build_ms,
                commit_ms: profile.commit_ms,
                table_rows: profile.table_rows,
                fts_rows: profile.fts_rows,
                vector_rows: profile.vector_rows,
                payload_bytes: profile.payload_bytes,
            },
        })
    }

    pub(crate) fn abort(&mut self, status: impl FnOnce(i32) -> Result<()>) -> Result<()> {
        let raw = self.raw()?;
        self.active = false;
        status(unsafe { zova_sys::zova_fresh_build_abort(raw) })
    }

    /// Roll back if still active and free the native session. Must run while
    /// the owning database handle is still open.
    pub(crate) fn destroy(&mut self) {
        if let Some(raw) = self.raw.take() {
            unsafe { zova_sys::zova_fresh_build_destroy(raw.as_ptr()) };
        }
        self.active = false;
    }
}

fn fresh_value(value: &FreshValue<'_>) -> zova_sys::zova_fresh_value {
    let mut raw = zova_sys::zova_fresh_value {
        value_type: zova_sys::ZOVA_FRESH_VALUE_NULL,
        int64_value: 0,
        float64_value: 0.0,
        bytes: ptr::null(),
        bytes_len: 0,
    };
    match *value {
        FreshValue::Null => {}
        FreshValue::Int64(value) => {
            raw.value_type = zova_sys::ZOVA_FRESH_VALUE_INT64;
            raw.int64_value = value;
        }
        FreshValue::Float64(value) => {
            raw.value_type = zova_sys::ZOVA_FRESH_VALUE_FLOAT64;
            raw.float64_value = value;
        }
        FreshValue::Text(value) => {
            raw.value_type = zova_sys::ZOVA_FRESH_VALUE_TEXT;
            raw.bytes = slice_ptr(value.as_bytes());
            raw.bytes_len = value.len();
        }
        FreshValue::Blob(value) => {
            raw.value_type = zova_sys::ZOVA_FRESH_VALUE_BLOB;
            raw.bytes = slice_ptr(value);
            raw.bytes_len = value.len();
        }
    }
    raw
}
