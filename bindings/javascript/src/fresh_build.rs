use std::sync::Arc;

use napi::bindgen_prelude::{BigInt, BigInt64Array, Either4, Uint8Array};
use napi::Result;
use napi_derive::napi;

use crate::database::{DatabaseState, NativeDatabase};
use crate::error::{invalid_argument_error, misuse_error, zova_error};
use crate::graph_keyed::{
    fresh_nodes, fresh_payload_edges, NativeGraphFreshEdgeInput, NativeGraphFreshNodeInput,
};
use crate::vector::{values_ref, NativeVectorInput};

/// One fresh-build cell: `null`, an integer `bigint`, a float `number`, text,
/// or a blob.
type NativeFreshValue = Option<Either4<BigInt, f64, String, Uint8Array>>;

/// Timings are milliseconds; counters are plain numbers.
#[napi(object)]
pub struct NativeFreshBuildProfile {
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
    pub table_rows: f64,
    pub fts_rows: f64,
    pub vector_rows: f64,
    pub payload_bytes: f64,
}

#[napi(object)]
pub struct NativeFreshBuildResult {
    pub node_keys: BigInt64Array,
    pub edge_keys: BigInt64Array,
    pub profile: NativeFreshBuildProfile,
}

/// An active fresh-build session. While it is open, every other call on its
/// database fails, and the database cannot close. `finish` commits; `abort`,
/// `close`, or any failure rolls the whole session back.
#[napi(js_name = "NativeFreshBuild")]
pub struct NativeFreshBuild {
    build: Option<zova::SharedFreshBuild>,
    database: Arc<DatabaseState>,
}

impl NativeFreshBuild {
    fn build(&mut self) -> Result<&mut zova::SharedFreshBuild> {
        self.build
            .as_mut()
            .ok_or_else(|| misuse_error("fresh build is closed"))
    }

    fn take(&mut self) -> Result<zova::SharedFreshBuild> {
        let build = self
            .build
            .take()
            .ok_or_else(|| misuse_error("fresh build is closed"))?;
        self.database.child_closed();
        Ok(build)
    }

    fn rows(
        &mut self,
        table_name: &str,
        columns: &[String],
        rows: &[Vec<NativeFreshValue>],
        fts: bool,
    ) -> Result<()> {
        let values = match fresh_values(columns.len(), rows) {
            Ok(values) => values,
            Err(error) => {
                // Invalid input ends the session, exactly as a native failure does.
                if let Ok(build) = self.take() {
                    let _ = build.abort();
                }
                return Err(error);
            }
        };
        let columns = columns.iter().map(String::as_str).collect::<Vec<_>>();
        let build = self.build()?;
        if fts {
            build.fts_rows(table_name, &columns, &values)
        } else {
            build.table_rows(table_name, &columns, &values)
        }
        .map_err(zova_error)
    }
}

fn fresh_values<'a>(
    column_count: usize,
    rows: &'a [Vec<NativeFreshValue>],
) -> Result<Vec<zova::FreshValue<'a>>> {
    let mut values = Vec::with_capacity(rows.len() * column_count);
    for (index, row) in rows.iter().enumerate() {
        if row.len() != column_count {
            return Err(invalid_argument_error(format!(
                "fresh build row {index} has {} values; expected {column_count}",
                row.len()
            )));
        }
        for value in row {
            values.push(match value {
                None => zova::FreshValue::Null,
                Some(Either4::A(value)) => match value.get_i64() {
                    (value, true) => zova::FreshValue::Int64(value),
                    _ => {
                        return Err(invalid_argument_error(format!(
                            "fresh build row {index} has an integer outside the signed 64-bit range"
                        )))
                    }
                },
                Some(Either4::B(value)) => zova::FreshValue::Float64(*value),
                Some(Either4::C(value)) => zova::FreshValue::Text(value),
                Some(Either4::D(value)) => zova::FreshValue::Blob(value.as_ref()),
            });
        }
    }
    Ok(values)
}

fn profile(profile: zova::FreshBuildProfile) -> NativeFreshBuildProfile {
    NativeFreshBuildProfile {
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
        table_rows: profile.table_rows as f64,
        fts_rows: profile.fts_rows as f64,
        vector_rows: profile.vector_rows as f64,
        payload_bytes: profile.payload_bytes as f64,
    }
}

#[napi]
impl NativeFreshBuild {
    #[napi]
    pub fn table_rows(
        &mut self,
        table_name: String,
        columns: Vec<String>,
        #[napi(ts_arg_type = "Array<Array<bigint | number | string | Uint8Array | null>>")]
        rows: Vec<Vec<NativeFreshValue>>,
    ) -> Result<()> {
        self.rows(&table_name, &columns, &rows, false)
    }

    #[napi]
    pub fn fts_rows(
        &mut self,
        table_name: String,
        columns: Vec<String>,
        #[napi(ts_arg_type = "Array<Array<bigint | number | string | Uint8Array | null>>")]
        rows: Vec<Vec<NativeFreshValue>>,
    ) -> Result<()> {
        self.rows(&table_name, &columns, &rows, true)
    }

    #[napi]
    pub fn graph(
        &mut self,
        graph_name: String,
        nodes: Vec<NativeGraphFreshNodeInput>,
        edges: Vec<NativeGraphFreshEdgeInput>,
    ) -> Result<()> {
        let nodes = match fresh_nodes(&nodes) {
            Ok(nodes) => nodes,
            Err(error) => {
                if let Ok(build) = self.take() {
                    let _ = build.abort();
                }
                return Err(error);
            }
        };
        let edges = fresh_payload_edges(&edges);
        self.build()?
            .graph(&graph_name, &nodes, &edges)
            .map_err(zova_error)
    }

    #[napi]
    pub fn vectors(
        &mut self,
        collection_name: String,
        vectors: Vec<NativeVectorInput>,
    ) -> Result<()> {
        let inputs = vectors
            .iter()
            .map(|vector| zova::VectorInput {
                id: &vector.id,
                values: values_ref(&vector.values),
            })
            .collect::<Vec<_>>();
        self.build()?
            .vectors(&collection_name, &inputs)
            .map_err(zova_error)
    }

    /// Commit the session. The build is closed afterwards.
    #[napi]
    pub fn finish(&mut self) -> Result<NativeFreshBuildResult> {
        let result = self.take()?.finish().map_err(zova_error)?;
        Ok(NativeFreshBuildResult {
            node_keys: BigInt64Array::new(result.node_keys),
            edge_keys: BigInt64Array::new(result.edge_keys),
            profile: profile(result.profile),
        })
    }

    /// Roll the session back. The build is closed afterwards.
    #[napi]
    pub fn abort(&mut self) -> Result<()> {
        self.take()?.abort().map_err(zova_error)
    }

    /// Roll back an unfinished session; closing a closed build does nothing.
    #[napi]
    pub fn close(&mut self) {
        if let Ok(build) = self.take() {
            drop(build);
        }
    }

    #[napi(getter)]
    pub fn closed(&self) -> bool {
        self.build.is_none()
    }
}

#[napi]
impl NativeDatabase {
    #[napi]
    pub fn begin_fresh_build(&self) -> Result<NativeFreshBuild> {
        let database = self.state.register_child()?;
        match database.begin_fresh_build() {
            Ok(build) => Ok(NativeFreshBuild {
                build: Some(build),
                database: self.state.clone(),
            }),
            Err(error) => {
                self.state.child_closed();
                Err(zova_error(error))
            }
        }
    }
}
