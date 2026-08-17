use std::sync::Arc;

use napi::bindgen_prelude::{
    AsyncTask, BigInt, Either3, Float32Array, Int8Array, Uint16Array, Uint8Array,
};
use napi::{Env, Result, Task};
use napi_derive::napi;

use crate::database::{DatabaseState, NativeDatabase, NativeKvEntry};
use crate::error::zova_error;
use crate::graph::{
    target_type, NativeGraphEdgeInput, NativeGraphNodeInput, NativeGraphWalkItem,
    NativeGraphWalkOptions,
};
use crate::vector::{native_search_results, NativeVectorInput, NativeVectorSearchResult};

#[cfg_attr(test, allow(dead_code))]
pub struct RestoreTask {
    source: String,
    destination: String,
    verify: bool,
}

impl Task for RestoreTask {
    type Output = ();
    type JsValue = ();

    fn compute(&mut self) -> Result<Self::Output> {
        zova::restore_backup(
            &self.source,
            &self.destination,
            zova::RestoreOptions {
                verify: self.verify,
            },
        )
        .map_err(zova_error)
    }

    fn resolve(&mut self, _: Env, _: Self::Output) -> Result<Self::JsValue> {
        Ok(())
    }
}

#[cfg_attr(test, allow(dead_code))]
pub struct RestoreToMemoryTask {
    source: String,
    verify: bool,
}

impl Task for RestoreToMemoryTask {
    type Output = zova::SharedDatabase;
    type JsValue = NativeDatabase;

    fn compute(&mut self) -> Result<Self::Output> {
        zova::SharedDatabase::restore_backup_to_memory(
            &self.source,
            zova::RestoreOptions {
                verify: self.verify,
            },
        )
        .map_err(zova_error)
    }

    fn resolve(&mut self, _: Env, output: Self::Output) -> Result<Self::JsValue> {
        Ok(NativeDatabase {
            state: Arc::new(DatabaseState::new(output)),
        })
    }
}

struct DatabaseTaskState {
    database: zova::SharedDatabase,
    state: Arc<DatabaseState>,
}

impl DatabaseTaskState {
    fn new(database: &NativeDatabase) -> Result<Self> {
        Ok(Self {
            database: database.state.register_child()?,
            state: database.state.clone(),
        })
    }

    fn finish(self) {
        self.state.child_closed();
    }
}

pub struct ExecTask {
    state: Option<DatabaseTaskState>,
    sql: String,
}

impl Task for ExecTask {
    type Output = ();
    type JsValue = ();

    fn compute(&mut self) -> Result<Self::Output> {
        self.state
            .as_ref()
            .expect("task state")
            .database
            .exec(&self.sql)
            .map_err(zova_error)
    }

    fn resolve(&mut self, _: Env, _: Self::Output) -> Result<Self::JsValue> {
        Ok(())
    }

    fn finally(mut self, _: Env) -> Result<()> {
        self.state.take().expect("task state").finish();
        Ok(())
    }
}

enum FileTaskKind {
    Backup,
    Compact,
}

pub struct FileTask {
    state: Option<DatabaseTaskState>,
    destination: String,
    verify: bool,
    kind: FileTaskKind,
}

impl Task for FileTask {
    type Output = ();
    type JsValue = ();

    fn compute(&mut self) -> Result<Self::Output> {
        let database = &self.state.as_ref().expect("task state").database;
        match self.kind {
            FileTaskKind::Backup => database
                .backup_to(
                    &self.destination,
                    zova::BackupOptions {
                        verify: self.verify,
                    },
                )
                .map_err(zova_error),
            FileTaskKind::Compact => database
                .compact_to(
                    &self.destination,
                    zova::CompactOptions {
                        verify: self.verify,
                    },
                )
                .map_err(zova_error),
        }
    }

    fn resolve(&mut self, _: Env, _: Self::Output) -> Result<Self::JsValue> {
        Ok(())
    }

    fn finally(mut self, _: Env) -> Result<()> {
        self.state.take().expect("task state").finish();
        Ok(())
    }
}

enum ObjectTaskKind {
    Put(Vec<u8>),
    Get(zova::ObjectId),
}

pub struct ObjectTask {
    state: Option<DatabaseTaskState>,
    kind: ObjectTaskKind,
}

enum OwnedVectorValues {
    F32(Vec<f32>),
    F16(Vec<u16>),
    I8(Vec<i8>),
}

impl OwnedVectorValues {
    fn from_native(values: Either3<Float32Array, Uint16Array, Int8Array>) -> Self {
        match values {
            Either3::A(values) => Self::F32(values.to_vec()),
            Either3::B(values) => Self::F16(values.to_vec()),
            Either3::C(values) => Self::I8(values.to_vec()),
        }
    }

    fn borrowed(&self) -> zova::VectorValues<'_> {
        match self {
            Self::F32(values) => zova::VectorValues::F32(values),
            Self::F16(values) => zova::VectorValues::F16(values),
            Self::I8(values) => zova::VectorValues::I8(values),
        }
    }
}

struct OwnedVectorInput {
    id: String,
    values: OwnedVectorValues,
}

pub struct VectorPutTask {
    state: Option<DatabaseTaskState>,
    collection_name: String,
    vectors: Vec<OwnedVectorInput>,
}

impl Task for VectorPutTask {
    type Output = ();
    type JsValue = ();

    fn compute(&mut self) -> Result<Self::Output> {
        let vectors = self
            .vectors
            .iter()
            .map(|vector| zova::VectorInput {
                id: &vector.id,
                values: vector.values.borrowed(),
            })
            .collect::<Vec<_>>();
        self.state
            .as_ref()
            .expect("task state")
            .database
            .put_vectors(&self.collection_name, &vectors)
            .map_err(zova_error)
    }

    fn resolve(&mut self, _: Env, _: Self::Output) -> Result<Self::JsValue> {
        Ok(())
    }

    fn finally(mut self, _: Env) -> Result<()> {
        self.state.take().expect("task state").finish();
        Ok(())
    }
}

pub struct VectorSearchTask {
    state: Option<DatabaseTaskState>,
    collection_name: String,
    query: OwnedVectorValues,
    candidate_ids: Option<Vec<String>>,
    max_distance: Option<f64>,
    limit: usize,
}

impl Task for VectorSearchTask {
    type Output = Vec<zova::VectorSearchResult>;
    type JsValue = Vec<NativeVectorSearchResult>;

    fn compute(&mut self) -> Result<Self::Output> {
        let candidates = self
            .candidate_ids
            .as_ref()
            .map(|items| items.iter().map(String::as_str).collect::<Vec<_>>());
        let database = &self.state.as_ref().expect("task state").database;
        match (candidates.as_deref(), self.max_distance) {
            (None, None) => {
                database.search_vectors(&self.collection_name, self.query.borrowed(), self.limit)
            }
            (Some(candidates), None) => database.search_vectors_in(
                &self.collection_name,
                self.query.borrowed(),
                candidates,
                self.limit,
            ),
            (None, Some(distance)) => database.search_vectors_within(
                &self.collection_name,
                self.query.borrowed(),
                distance,
                self.limit,
            ),
            (Some(candidates), Some(distance)) => database.search_vectors_in_within(
                &self.collection_name,
                self.query.borrowed(),
                candidates,
                distance,
                self.limit,
            ),
        }
        .map_err(zova_error)
    }

    fn resolve(&mut self, _: Env, output: Self::Output) -> Result<Self::JsValue> {
        Ok(native_search_results(output))
    }

    fn finally(mut self, _: Env) -> Result<()> {
        self.state.take().expect("task state").finish();
        Ok(())
    }
}

struct OwnedGraphNodeInput {
    graph_name: String,
    node_id: String,
    kind: String,
    target_type: zova::GraphTargetType,
    target_namespace: Option<String>,
    target_ref: Option<String>,
}

struct OwnedGraphEdgeInput {
    graph_name: String,
    from_node_id: String,
    edge_type: String,
    to_node_id: String,
}

enum GraphBatchKind {
    Nodes(Vec<OwnedGraphNodeInput>),
    Edges(Vec<OwnedGraphEdgeInput>),
}

pub struct GraphBatchTask {
    state: Option<DatabaseTaskState>,
    kind: GraphBatchKind,
}

impl Task for GraphBatchTask {
    type Output = ();
    type JsValue = ();

    fn compute(&mut self) -> Result<Self::Output> {
        let database = &self.state.as_ref().expect("task state").database;
        match &self.kind {
            GraphBatchKind::Nodes(inputs) => {
                let inputs = inputs
                    .iter()
                    .map(|input| zova::GraphNodeInput {
                        graph_name: &input.graph_name,
                        node_id: &input.node_id,
                        kind: &input.kind,
                        target_type: input.target_type,
                        target_namespace: input.target_namespace.as_deref(),
                        target_ref: input.target_ref.as_deref(),
                    })
                    .collect::<Vec<_>>();
                database.put_graph_nodes(&inputs)
            }
            GraphBatchKind::Edges(inputs) => {
                let inputs = inputs
                    .iter()
                    .map(|input| zova::GraphEdgeInput {
                        graph_name: &input.graph_name,
                        from_node_id: &input.from_node_id,
                        edge_type: &input.edge_type,
                        to_node_id: &input.to_node_id,
                    })
                    .collect::<Vec<_>>();
                database.put_graph_edges(&inputs)
            }
        }
        .map_err(zova_error)
    }

    fn resolve(&mut self, _: Env, _: Self::Output) -> Result<Self::JsValue> {
        Ok(())
    }

    fn finally(mut self, _: Env) -> Result<()> {
        self.state.take().expect("task state").finish();
        Ok(())
    }
}

pub struct GraphWalkTask {
    state: Option<DatabaseTaskState>,
    options: NativeGraphWalkOptions,
}

impl Task for GraphWalkTask {
    type Output = Vec<zova::GraphWalkItem>;
    type JsValue = Vec<NativeGraphWalkItem>;

    fn compute(&mut self) -> Result<Self::Output> {
        self.state
            .as_ref()
            .expect("task state")
            .database
            .graph_walk(zova::GraphWalkOptions {
                graph_name: &self.options.graph_name,
                start_node_id: &self.options.start_node_id,
                edge_type: self.options.edge_type.as_deref(),
                max_depth: self.options.max_depth,
                limit: self.options.limit as usize,
            })
            .map_err(zova_error)
    }

    fn resolve(&mut self, _: Env, output: Self::Output) -> Result<Self::JsValue> {
        Ok(output
            .into_iter()
            .map(|item| NativeGraphWalkItem {
                node_id: item.node_id,
                kind: item.kind,
                depth: item.depth,
                predecessor_node_id: item.predecessor_node_id,
                edge_type: item.edge_type,
            })
            .collect())
    }

    fn finally(mut self, _: Env) -> Result<()> {
        self.state.take().expect("task state").finish();
        Ok(())
    }
}

impl Task for ObjectTask {
    type Output = Vec<u8>;
    type JsValue = Uint8Array;

    fn compute(&mut self) -> Result<Self::Output> {
        let database = &self.state.as_ref().expect("task state").database;
        match &self.kind {
            ObjectTaskKind::Put(bytes) => database
                .put_object(bytes)
                .map(|id| id.into_bytes().to_vec())
                .map_err(zova_error),
            ObjectTaskKind::Get(id) => database.get_object(*id).map_err(zova_error),
        }
    }

    fn resolve(&mut self, _: Env, output: Self::Output) -> Result<Self::JsValue> {
        Ok(Uint8Array::new(output))
    }

    fn finally(mut self, _: Env) -> Result<()> {
        self.state.take().expect("task state").finish();
        Ok(())
    }
}

enum KvTaskKind {
    Get(Vec<u8>, Vec<u8>),
    GetMany(Vec<u8>, Vec<Vec<u8>>),
    Put(Vec<u8>, Vec<u8>, Vec<u8>),
    PutMany(Vec<u8>, Vec<(Vec<u8>, Vec<u8>)>),
    Delete(Vec<u8>, Vec<u8>),
    DeleteMany(Vec<u8>, Vec<Vec<u8>>),
    Count(Vec<u8>),
    ClearNamespace(Vec<u8>),
}

pub enum KvTaskOutput {
    Void,
    Get(Option<Vec<u8>>),
    Many(Vec<Option<Vec<u8>>>),
    Count(u64),
}

pub struct KvTask {
    state: Option<DatabaseTaskState>,
    kind: KvTaskKind,
}

impl Task for KvTask {
    type Output = KvTaskOutput;
    type JsValue = KvTaskValue;

    fn compute(&mut self) -> Result<Self::Output> {
        let database = &self.state.as_ref().expect("task state").database;
        match &self.kind {
            KvTaskKind::Get(namespace, key) => database
                .kv_get(namespace, key)
                .map(KvTaskOutput::Get)
                .map_err(zova_error),
            KvTaskKind::GetMany(namespace, keys) => {
                let key_refs: Vec<&[u8]> = keys.iter().map(|key| key.as_slice()).collect();
                database
                    .kv_get_many(namespace, &key_refs)
                    .map(KvTaskOutput::Many)
                    .map_err(zova_error)
            }
            KvTaskKind::Put(namespace, key, value) => database
                .kv_put(namespace, key, value)
                .map(|()| KvTaskOutput::Void)
                .map_err(zova_error),
            KvTaskKind::PutMany(namespace, entries) => {
                let entries = entries
                    .iter()
                    .map(|(key, value)| zova::KvEntry {
                        key: key.as_slice(),
                        value: value.as_slice(),
                    })
                    .collect::<Vec<_>>();
                database
                    .kv_put_many(namespace, &entries)
                    .map(|()| KvTaskOutput::Void)
                    .map_err(zova_error)
            }
            KvTaskKind::Delete(namespace, key) => database
                .kv_delete(namespace, key)
                .map(|()| KvTaskOutput::Void)
                .map_err(zova_error),
            KvTaskKind::DeleteMany(namespace, keys) => {
                let key_refs: Vec<&[u8]> = keys.iter().map(|key| key.as_slice()).collect();
                database
                    .kv_delete_many(namespace, &key_refs)
                    .map(|()| KvTaskOutput::Void)
                    .map_err(zova_error)
            }
            KvTaskKind::Count(namespace) => database
                .kv_count(namespace)
                .map(KvTaskOutput::Count)
                .map_err(zova_error),
            KvTaskKind::ClearNamespace(namespace) => database
                .kv_clear_namespace(namespace)
                .map(|()| KvTaskOutput::Void)
                .map_err(zova_error),
        }
    }

    fn resolve(&mut self, _: Env, output: Self::Output) -> Result<Self::JsValue> {
        Ok(match output {
            KvTaskOutput::Void => KvTaskValue {
                kind: "void".into(),
                value: None,
                values: None,
                count: None,
            },
            KvTaskOutput::Get(value) => KvTaskValue {
                kind: "get".into(),
                value: value.map(|value| Uint8Array::new(value)),
                values: None,
                count: None,
            },
            KvTaskOutput::Many(values) => KvTaskValue {
                kind: "many".into(),
                value: None,
                values: Some(
                    values
                        .into_iter()
                        .map(|value| value.map(|value| Uint8Array::new(value)))
                        .collect(),
                ),
                count: None,
            },
            KvTaskOutput::Count(count) => KvTaskValue {
                kind: "count".into(),
                value: None,
                values: None,
                count: Some(BigInt::from(count)),
            },
        })
    }

    fn finally(mut self, _: Env) -> Result<()> {
        self.state.take().expect("task state").finish();
        Ok(())
    }
}

#[napi(object)]
pub struct KvTaskValue {
    pub kind: String,
    pub value: Option<Uint8Array>,
    pub values: Option<Vec<Option<Uint8Array>>>,
    pub count: Option<BigInt>,
}

#[napi(ts_return_type = "Promise<void>")]
#[cfg_attr(test, allow(dead_code))]
pub fn async_restore_backup(
    source: String,
    destination: String,
    verify: Option<bool>,
) -> AsyncTask<RestoreTask> {
    AsyncTask::new(RestoreTask {
        source,
        destination,
        verify: verify.unwrap_or(true),
    })
}

#[napi(ts_return_type = "Promise<NativeDatabase>")]
#[cfg_attr(test, allow(dead_code))]
pub fn async_restore_backup_to_memory(
    source: String,
    verify: Option<bool>,
) -> AsyncTask<RestoreToMemoryTask> {
    AsyncTask::new(RestoreToMemoryTask {
        source,
        verify: verify.unwrap_or(true),
    })
}

#[napi]
impl NativeDatabase {
    #[napi(ts_return_type = "Promise<void>")]
    pub fn async_exec(&self, sql: String) -> Result<AsyncTask<ExecTask>> {
        Ok(AsyncTask::new(ExecTask {
            state: Some(DatabaseTaskState::new(self)?),
            sql,
        }))
    }

    #[napi(ts_return_type = "Promise<void>")]
    pub fn async_backup_to(
        &self,
        destination: String,
        verify: Option<bool>,
    ) -> Result<AsyncTask<FileTask>> {
        Ok(AsyncTask::new(FileTask {
            state: Some(DatabaseTaskState::new(self)?),
            destination,
            verify: verify.unwrap_or(true),
            kind: FileTaskKind::Backup,
        }))
    }

    #[napi(ts_return_type = "Promise<void>")]
    pub fn async_compact_to(
        &self,
        destination: String,
        verify: Option<bool>,
    ) -> Result<AsyncTask<FileTask>> {
        Ok(AsyncTask::new(FileTask {
            state: Some(DatabaseTaskState::new(self)?),
            destination,
            verify: verify.unwrap_or(true),
            kind: FileTaskKind::Compact,
        }))
    }

    #[napi(ts_return_type = "Promise<Uint8Array>")]
    pub fn async_put_object(&self, data: Uint8Array) -> Result<AsyncTask<ObjectTask>> {
        Ok(AsyncTask::new(ObjectTask {
            state: Some(DatabaseTaskState::new(self)?),
            kind: ObjectTaskKind::Put(data.to_vec()),
        }))
    }

    #[napi(ts_return_type = "Promise<Uint8Array>")]
    pub fn async_get_object(&self, id: Uint8Array) -> Result<AsyncTask<ObjectTask>> {
        let id = zova::ObjectId::try_from(id.as_ref()).map_err(zova_error)?;
        Ok(AsyncTask::new(ObjectTask {
            state: Some(DatabaseTaskState::new(self)?),
            kind: ObjectTaskKind::Get(id),
        }))
    }

    #[napi(ts_return_type = "Promise<void>")]
    pub fn async_put_vectors(
        &self,
        collection_name: String,
        vectors: Vec<NativeVectorInput>,
    ) -> Result<AsyncTask<VectorPutTask>> {
        let vectors = vectors
            .into_iter()
            .map(|vector| OwnedVectorInput {
                id: vector.id,
                values: OwnedVectorValues::from_native(vector.values),
            })
            .collect();
        Ok(AsyncTask::new(VectorPutTask {
            state: Some(DatabaseTaskState::new(self)?),
            collection_name,
            vectors,
        }))
    }

    #[napi(ts_return_type = "Promise<Array<NativeVectorSearchResult>>")]
    pub fn async_search_vectors(
        &self,
        collection_name: String,
        query: Either3<Float32Array, Uint16Array, Int8Array>,
        candidate_ids: Option<Vec<String>>,
        max_distance: Option<f64>,
        limit: u32,
    ) -> Result<AsyncTask<VectorSearchTask>> {
        Ok(AsyncTask::new(VectorSearchTask {
            state: Some(DatabaseTaskState::new(self)?),
            collection_name,
            query: OwnedVectorValues::from_native(query),
            candidate_ids,
            max_distance,
            limit: limit as usize,
        }))
    }

    #[napi(ts_return_type = "Promise<void>")]
    pub fn async_put_graph_nodes(
        &self,
        inputs: Vec<NativeGraphNodeInput>,
    ) -> Result<AsyncTask<GraphBatchTask>> {
        let inputs = inputs
            .into_iter()
            .map(|input| {
                Ok(OwnedGraphNodeInput {
                    graph_name: input.graph_name,
                    node_id: input.node_id,
                    kind: input.kind,
                    target_type: target_type(&input.target_type)?,
                    target_namespace: input.target_namespace,
                    target_ref: input.target_ref,
                })
            })
            .collect::<Result<Vec<_>>>()?;
        Ok(AsyncTask::new(GraphBatchTask {
            state: Some(DatabaseTaskState::new(self)?),
            kind: GraphBatchKind::Nodes(inputs),
        }))
    }

    #[napi(ts_return_type = "Promise<void>")]
    pub fn async_put_graph_edges(
        &self,
        inputs: Vec<NativeGraphEdgeInput>,
    ) -> Result<AsyncTask<GraphBatchTask>> {
        let inputs = inputs
            .into_iter()
            .map(|input| OwnedGraphEdgeInput {
                graph_name: input.graph_name,
                from_node_id: input.from_node_id,
                edge_type: input.edge_type,
                to_node_id: input.to_node_id,
            })
            .collect();
        Ok(AsyncTask::new(GraphBatchTask {
            state: Some(DatabaseTaskState::new(self)?),
            kind: GraphBatchKind::Edges(inputs),
        }))
    }

    #[napi(ts_return_type = "Promise<Array<NativeGraphWalkItem>>")]
    pub fn async_graph_walk(
        &self,
        options: NativeGraphWalkOptions,
    ) -> Result<AsyncTask<GraphWalkTask>> {
        Ok(AsyncTask::new(GraphWalkTask {
            state: Some(DatabaseTaskState::new(self)?),
            options,
        }))
    }

    #[napi(ts_return_type = "Promise<KvTaskValue>")]
    pub fn async_kv_get(
        &self,
        namespace: Uint8Array,
        key: Uint8Array,
    ) -> Result<AsyncTask<KvTask>> {
        Ok(AsyncTask::new(KvTask {
            state: Some(DatabaseTaskState::new(self)?),
            kind: KvTaskKind::Get(namespace.to_vec(), key.to_vec()),
        }))
    }

    #[napi(ts_return_type = "Promise<KvTaskValue>")]
    pub fn async_kv_get_many(
        &self,
        namespace: Uint8Array,
        keys: Vec<Uint8Array>,
    ) -> Result<AsyncTask<KvTask>> {
        Ok(AsyncTask::new(KvTask {
            state: Some(DatabaseTaskState::new(self)?),
            kind: KvTaskKind::GetMany(
                namespace.to_vec(),
                keys.into_iter().map(|key| key.to_vec()).collect(),
            ),
        }))
    }

    #[napi(ts_return_type = "Promise<KvTaskValue>")]
    pub fn async_kv_put(
        &self,
        namespace: Uint8Array,
        key: Uint8Array,
        value: Uint8Array,
    ) -> Result<AsyncTask<KvTask>> {
        Ok(AsyncTask::new(KvTask {
            state: Some(DatabaseTaskState::new(self)?),
            kind: KvTaskKind::Put(namespace.to_vec(), key.to_vec(), value.to_vec()),
        }))
    }

    #[napi(ts_return_type = "Promise<KvTaskValue>")]
    pub fn async_kv_put_many(
        &self,
        namespace: Uint8Array,
        entries: Vec<NativeKvEntry>,
    ) -> Result<AsyncTask<KvTask>> {
        Ok(AsyncTask::new(KvTask {
            state: Some(DatabaseTaskState::new(self)?),
            kind: KvTaskKind::PutMany(
                namespace.to_vec(),
                entries
                    .into_iter()
                    .map(|entry| (entry.key.to_vec(), entry.value.to_vec()))
                    .collect(),
            ),
        }))
    }

    #[napi(ts_return_type = "Promise<KvTaskValue>")]
    pub fn async_kv_delete(
        &self,
        namespace: Uint8Array,
        key: Uint8Array,
    ) -> Result<AsyncTask<KvTask>> {
        Ok(AsyncTask::new(KvTask {
            state: Some(DatabaseTaskState::new(self)?),
            kind: KvTaskKind::Delete(namespace.to_vec(), key.to_vec()),
        }))
    }

    #[napi(ts_return_type = "Promise<KvTaskValue>")]
    pub fn async_kv_delete_many(
        &self,
        namespace: Uint8Array,
        keys: Vec<Uint8Array>,
    ) -> Result<AsyncTask<KvTask>> {
        Ok(AsyncTask::new(KvTask {
            state: Some(DatabaseTaskState::new(self)?),
            kind: KvTaskKind::DeleteMany(
                namespace.to_vec(),
                keys.into_iter().map(|key| key.to_vec()).collect(),
            ),
        }))
    }

    #[napi(ts_return_type = "Promise<KvTaskValue>")]
    pub fn async_kv_count(&self, namespace: Uint8Array) -> Result<AsyncTask<KvTask>> {
        Ok(AsyncTask::new(KvTask {
            state: Some(DatabaseTaskState::new(self)?),
            kind: KvTaskKind::Count(namespace.to_vec()),
        }))
    }

    #[napi(ts_return_type = "Promise<KvTaskValue>")]
    pub fn async_kv_clear_namespace(&self, namespace: Uint8Array) -> Result<AsyncTask<KvTask>> {
        Ok(AsyncTask::new(KvTask {
            state: Some(DatabaseTaskState::new(self)?),
            kind: KvTaskKind::ClearNamespace(namespace.to_vec()),
        }))
    }
}
