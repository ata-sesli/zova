use pyo3::exceptions::PyValueError;
use pyo3::prelude::*;
use pyo3::types::PyAny;

#[pyclass(name = "VectorCollectionOptions", frozen, skip_from_py_object)]
#[derive(Clone, Copy)]
pub(crate) struct PyVectorCollectionOptions {
    dimensions: u32,
    metric: i32,
}

#[pyclass(name = "Vector", frozen, skip_from_py_object)]
#[derive(Clone)]
pub(crate) struct PyVector {
    id: String,
    values: Vec<f32>,
}

#[pyclass(name = "VectorCollectionInfo", frozen, skip_from_py_object)]
#[derive(Clone)]
pub(crate) struct PyVectorCollectionInfo {
    name: String,
    dimensions: u32,
    metric: i32,
    vector_count: u64,
}

#[pyclass(name = "VectorInput", frozen, skip_from_py_object)]
#[derive(Clone)]
pub(crate) struct PyVectorInput {
    id: String,
    values: Vec<f32>,
}

#[pyclass(name = "VectorSearchResult", frozen, skip_from_py_object)]
#[derive(Clone)]
pub(crate) struct PyVectorSearchResult {
    id: String,
    distance: f64,
}

#[pymethods]
impl PyVectorCollectionOptions {
    #[new]
    pub(crate) fn new(dimensions: u32, metric: i32) -> PyResult<Self> {
        let _ = metric_from_i32(metric)?;
        Ok(Self { dimensions, metric })
    }

    #[getter]
    pub(crate) fn dimensions(&self) -> u32 {
        self.dimensions
    }

    #[getter]
    pub(crate) fn metric(&self) -> i32 {
        self.metric
    }

    pub(crate) fn __repr__(&self) -> String {
        format!(
            "VectorCollectionOptions(dimensions={}, metric={})",
            self.dimensions, self.metric
        )
    }
}

#[pymethods]
impl PyVector {
    #[getter]
    pub(crate) fn id(&self) -> String {
        self.id.clone()
    }

    #[getter]
    pub(crate) fn values(&self) -> Vec<f32> {
        self.values.clone()
    }

    pub(crate) fn __repr__(&self) -> String {
        format!("Vector(id='{}', values_len={})", self.id, self.values.len())
    }
}

#[pymethods]
impl PyVectorCollectionInfo {
    #[getter]
    pub(crate) fn name(&self) -> String {
        self.name.clone()
    }

    #[getter]
    pub(crate) fn dimensions(&self) -> u32 {
        self.dimensions
    }

    #[getter]
    pub(crate) fn metric(&self) -> i32 {
        self.metric
    }

    #[getter]
    pub(crate) fn vector_count(&self) -> u64 {
        self.vector_count
    }

    pub(crate) fn __repr__(&self) -> String {
        format!(
            "VectorCollectionInfo(name='{}', dimensions={}, metric={}, vector_count={})",
            self.name, self.dimensions, self.metric, self.vector_count
        )
    }
}

#[pymethods]
impl PyVectorInput {
    #[new]
    pub(crate) fn new(id: String, values: Vec<f32>) -> Self {
        Self { id, values }
    }

    #[getter]
    pub(crate) fn id(&self) -> String {
        self.id.clone()
    }

    #[getter]
    pub(crate) fn values(&self) -> Vec<f32> {
        self.values.clone()
    }

    pub(crate) fn __repr__(&self) -> String {
        format!(
            "VectorInput(id='{}', values_len={})",
            self.id,
            self.values.len()
        )
    }
}

#[pymethods]
impl PyVectorSearchResult {
    #[getter]
    pub(crate) fn id(&self) -> String {
        self.id.clone()
    }

    #[getter]
    pub(crate) fn distance(&self) -> f64 {
        self.distance
    }

    pub(crate) fn __repr__(&self) -> String {
        format!(
            "VectorSearchResult(id='{}', distance={})",
            self.id, self.distance
        )
    }
}

pub(crate) fn options_from_py(
    value: &Bound<'_, PyAny>,
) -> PyResult<zova_rust::VectorCollectionOptions> {
    let options = value.extract::<PyRef<'_, PyVectorCollectionOptions>>()?;
    Ok(zova_rust::VectorCollectionOptions {
        dimensions: options.dimensions,
        metric: metric_from_i32(options.metric)?,
    })
}

pub(crate) fn vector_inputs_from_py(value: &Bound<'_, PyAny>) -> PyResult<Vec<(String, Vec<f32>)>> {
    let mut vectors = Vec::new();
    for item in value.try_iter()? {
        let item = item?;
        let vector = item.extract::<PyRef<'_, PyVectorInput>>()?;
        vectors.push((vector.id.clone(), vector.values.clone()));
    }
    Ok(vectors)
}

pub(crate) fn vector_input_refs<'a>(
    vectors: &'a [(String, Vec<f32>)],
) -> Vec<zova_rust::VectorInput<'a>> {
    vectors
        .iter()
        .map(|(id, values)| zova_rust::VectorInput {
            id: id.as_str(),
            values: values.as_slice(),
        })
        .collect()
}

pub(crate) fn candidate_refs(candidate_ids: &[String]) -> Vec<&str> {
    candidate_ids.iter().map(String::as_str).collect()
}

pub(crate) fn py_vector(vector: zova_rust::Vector) -> PyVector {
    PyVector {
        id: vector.id,
        values: vector.values,
    }
}

pub(crate) fn py_collection_info(info: zova_rust::VectorCollectionInfo) -> PyVectorCollectionInfo {
    PyVectorCollectionInfo {
        name: info.name,
        dimensions: info.dimensions,
        metric: metric_to_i32(info.metric),
        vector_count: info.vector_count,
    }
}

pub(crate) fn py_search_results(
    results: Vec<zova_rust::VectorSearchResult>,
) -> Vec<PyVectorSearchResult> {
    results
        .into_iter()
        .map(|result| PyVectorSearchResult {
            id: result.id,
            distance: result.distance,
        })
        .collect()
}

pub(crate) fn metric_from_i32(metric: i32) -> PyResult<zova_rust::VectorMetric> {
    match metric {
        0 => Ok(zova_rust::VectorMetric::Cosine),
        1 => Ok(zova_rust::VectorMetric::L2),
        2 => Ok(zova_rust::VectorMetric::Dot),
        _ => Err(PyValueError::new_err(format!(
            "invalid vector metric {metric}; expected 0, 1, or 2"
        ))),
    }
}

pub(crate) fn metric_to_i32(metric: zova_rust::VectorMetric) -> i32 {
    match metric {
        zova_rust::VectorMetric::Cosine => 0,
        zova_rust::VectorMetric::L2 => 1,
        zova_rust::VectorMetric::Dot => 2,
    }
}

#[pyfunction]
pub(crate) fn encode_f32_le(values: Vec<f32>) -> PyResult<Vec<u8>> {
    let mut out = Vec::with_capacity(values.len() * 4);
    for value in values {
        if !value.is_finite() {
            return Err(PyValueError::new_err(
                "vector query values must be finite f32 values",
            ));
        }
        out.extend_from_slice(&value.to_le_bytes());
    }
    Ok(out)
}
