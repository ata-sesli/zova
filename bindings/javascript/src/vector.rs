use napi::bindgen_prelude::{BigInt, Either3, Float32Array, Int8Array, Uint16Array};
use napi::Result;
use napi_derive::napi;

use crate::database::NativeDatabase;
use crate::error::{invalid_argument_error, zova_error};

#[napi(object)]
pub struct NativeVectorCollectionOptions {
    pub dimensions: u32,
    pub metric: String,
    pub element_type: String,
}

#[napi(object)]
pub struct NativeVectorCollectionInfo {
    pub name: String,
    pub dimensions: u32,
    pub metric: String,
    pub element_type: String,
    pub vector_count: BigInt,
}

#[napi(object)]
pub struct NativeVectorInput {
    pub id: String,
    pub values: Either3<Float32Array, Uint16Array, Int8Array>,
}

#[napi(object)]
pub struct NativeVector {
    pub id: String,
    pub values: Either3<Float32Array, Uint16Array, Int8Array>,
}

#[napi(object)]
pub struct NativeVectorSearchResult {
    pub id: String,
    pub distance: f64,
}

fn metric(value: &str) -> Result<zova::VectorMetric> {
    match value {
        "cosine" => Ok(zova::VectorMetric::Cosine),
        "l2" => Ok(zova::VectorMetric::L2),
        "dot" => Ok(zova::VectorMetric::Dot),
        _ => Err(invalid_argument_error(format!(
            "unsupported vector metric: {value}"
        ))),
    }
}

fn metric_name(value: zova::VectorMetric) -> &'static str {
    match value {
        zova::VectorMetric::Cosine => "cosine",
        zova::VectorMetric::L2 => "l2",
        zova::VectorMetric::Dot => "dot",
    }
}

fn element_type(value: &str) -> Result<zova::VectorElementType> {
    match value {
        "f32" => Ok(zova::VectorElementType::F32),
        "f16" => Ok(zova::VectorElementType::F16),
        "i8" => Ok(zova::VectorElementType::I8),
        _ => Err(invalid_argument_error(format!(
            "unsupported vector element type: {value}"
        ))),
    }
}

fn element_type_name(value: zova::VectorElementType) -> &'static str {
    match value {
        zova::VectorElementType::F32 => "f32",
        zova::VectorElementType::F16 => "f16",
        zova::VectorElementType::I8 => "i8",
    }
}

fn values_ref(values: &Either3<Float32Array, Uint16Array, Int8Array>) -> zova::VectorValues<'_> {
    match values {
        Either3::A(values) => zova::VectorValues::F32(values.as_ref()),
        Either3::B(values) => zova::VectorValues::F16(values.as_ref()),
        Either3::C(values) => zova::VectorValues::I8(values.as_ref()),
    }
}

fn native_values(values: zova::VectorValuesOwned) -> Either3<Float32Array, Uint16Array, Int8Array> {
    match values {
        zova::VectorValuesOwned::F32(values) => Either3::A(Float32Array::new(values)),
        zova::VectorValuesOwned::F16(values) => Either3::B(Uint16Array::new(values)),
        zova::VectorValuesOwned::I8(values) => Either3::C(Int8Array::new(values)),
    }
}

fn native_collection_info(info: zova::VectorCollectionInfo) -> NativeVectorCollectionInfo {
    NativeVectorCollectionInfo {
        name: info.name,
        dimensions: info.dimensions,
        metric: metric_name(info.metric).to_owned(),
        element_type: element_type_name(info.element_type).to_owned(),
        vector_count: BigInt::from(info.vector_count),
    }
}

fn native_vector(vector: zova::Vector) -> NativeVector {
    NativeVector {
        id: vector.id,
        values: native_values(vector.values),
    }
}

pub(crate) fn native_search_results(
    results: Vec<zova::VectorSearchResult>,
) -> Vec<NativeVectorSearchResult> {
    results
        .into_iter()
        .map(|result| NativeVectorSearchResult {
            id: result.id,
            distance: result.distance,
        })
        .collect()
}

#[napi]
impl NativeDatabase {
    #[napi]
    pub fn create_vector_collection(
        &self,
        name: String,
        options: NativeVectorCollectionOptions,
    ) -> Result<()> {
        self.state
            .database()?
            .create_vector_collection(
                &name,
                zova::VectorCollectionOptions {
                    dimensions: options.dimensions,
                    metric: metric(&options.metric)?,
                    element_type: element_type(&options.element_type)?,
                },
            )
            .map_err(zova_error)
    }

    #[napi]
    pub fn has_vector_collection(&self, name: String) -> Result<bool> {
        self.state
            .database()?
            .has_vector_collection(&name)
            .map_err(zova_error)
    }

    #[napi]
    pub fn vector_collection_info(&self, name: String) -> Result<NativeVectorCollectionInfo> {
        self.state
            .database()?
            .vector_collection_info(&name)
            .map(native_collection_info)
            .map_err(zova_error)
    }

    #[napi]
    pub fn list_vector_collections(&self) -> Result<Vec<NativeVectorCollectionInfo>> {
        self.state
            .database()?
            .list_vector_collections()
            .map(|items| items.into_iter().map(native_collection_info).collect())
            .map_err(zova_error)
    }

    #[napi]
    pub fn delete_vector_collection(&self, name: String) -> Result<()> {
        self.state
            .database()?
            .delete_vector_collection(&name)
            .map_err(zova_error)
    }

    #[napi]
    pub fn put_vector(
        &self,
        collection_name: String,
        vector_id: String,
        values: Either3<Float32Array, Uint16Array, Int8Array>,
    ) -> Result<()> {
        self.state
            .database()?
            .put_vector(&collection_name, &vector_id, values_ref(&values))
            .map_err(zova_error)
    }

    #[napi]
    pub fn put_vectors(
        &self,
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
        self.state
            .database()?
            .put_vectors(&collection_name, &inputs)
            .map_err(zova_error)
    }

    #[napi]
    pub fn get_vector(&self, collection_name: String, vector_id: String) -> Result<NativeVector> {
        self.state
            .database()?
            .get_vector(&collection_name, &vector_id)
            .map(native_vector)
            .map_err(zova_error)
    }

    #[napi]
    pub fn has_vector(&self, collection_name: String, vector_id: String) -> Result<bool> {
        self.state
            .database()?
            .has_vector(&collection_name, &vector_id)
            .map_err(zova_error)
    }

    #[napi]
    pub fn delete_vector(&self, collection_name: String, vector_id: String) -> Result<()> {
        self.state
            .database()?
            .delete_vector(&collection_name, &vector_id)
            .map_err(zova_error)
    }

    #[napi]
    pub fn delete_vectors(&self, collection_name: String, vector_ids: Vec<String>) -> Result<()> {
        let vector_ids = vector_ids.iter().map(String::as_str).collect::<Vec<_>>();
        self.state
            .database()?
            .delete_vectors(&collection_name, &vector_ids)
            .map_err(zova_error)
    }

    #[napi]
    pub fn search_vectors(
        &self,
        collection_name: String,
        query: Either3<Float32Array, Uint16Array, Int8Array>,
        candidate_ids: Option<Vec<String>>,
        max_distance: Option<f64>,
        limit: u32,
    ) -> Result<Vec<NativeVectorSearchResult>> {
        let candidate_refs = candidate_ids
            .as_ref()
            .map(|items| items.iter().map(String::as_str).collect::<Vec<_>>());
        let database = self.state.database()?;
        let results = match (candidate_refs.as_deref(), max_distance) {
            (None, None) => {
                database.search_vectors(&collection_name, values_ref(&query), limit as usize)
            }
            (Some(candidates), None) => database.search_vectors_in(
                &collection_name,
                values_ref(&query),
                candidates,
                limit as usize,
            ),
            (None, Some(distance)) => database.search_vectors_within(
                &collection_name,
                values_ref(&query),
                distance,
                limit as usize,
            ),
            (Some(candidates), Some(distance)) => database.search_vectors_in_within(
                &collection_name,
                values_ref(&query),
                candidates,
                distance,
                limit as usize,
            ),
        }
        .map_err(zova_error)?;
        Ok(native_search_results(results))
    }

    #[napi]
    pub fn search_vectors_by_id(
        &self,
        collection_name: String,
        source_vector_id: String,
        candidate_ids: Option<Vec<String>>,
        max_distance: Option<f64>,
        limit: u32,
    ) -> Result<Vec<NativeVectorSearchResult>> {
        let candidate_refs = candidate_ids
            .as_ref()
            .map(|items| items.iter().map(String::as_str).collect::<Vec<_>>());
        let database = self.state.database()?;
        let results = match (candidate_refs.as_deref(), max_distance) {
            (None, None) => {
                database.search_vectors_by_id(&collection_name, &source_vector_id, limit as usize)
            }
            (Some(candidates), None) => database.search_vectors_by_id_in(
                &collection_name,
                &source_vector_id,
                candidates,
                limit as usize,
            ),
            (None, Some(distance)) => database.search_vectors_by_id_within(
                &collection_name,
                &source_vector_id,
                distance,
                limit as usize,
            ),
            (Some(candidates), Some(distance)) => database.search_vectors_by_id_in_within(
                &collection_name,
                &source_vector_id,
                candidates,
                distance,
                limit as usize,
            ),
        }
        .map_err(zova_error)?;
        Ok(native_search_results(results))
    }
}
