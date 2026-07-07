use pyo3::exceptions::PyValueError;
use pyo3::prelude::*;
use pyo3::types::{PyAny, PyList};

#[pyclass(name = "VectorCollectionOptions", frozen, skip_from_py_object)]
#[derive(Clone, Copy)]
pub(crate) struct PyVectorCollectionOptions {
    dimensions: u32,
    metric: i32,
    element_type: i32,
}

#[pyclass(name = "Vector", frozen, skip_from_py_object)]
#[derive(Clone)]
pub(crate) struct PyVector {
    id: String,
    values: PyVectorValues,
}

#[derive(Clone)]
pub(crate) enum PyVectorValues {
    F32(Vec<f32>),
    F16(Vec<u16>),
    I8(Vec<i8>),
}

#[pyclass(name = "VectorCollectionInfo", frozen, skip_from_py_object)]
#[derive(Clone)]
pub(crate) struct PyVectorCollectionInfo {
    name: String,
    dimensions: u32,
    metric: i32,
    element_type: i32,
    vector_count: u64,
}

#[pyclass(name = "VectorInput", frozen, skip_from_py_object)]
#[derive(Clone)]
pub(crate) struct PyVectorInput {
    id: String,
    values: PyVectorValues,
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
    #[pyo3(signature = (dimensions, metric, element_type = 0))]
    pub(crate) fn new(dimensions: u32, metric: i32, element_type: i32) -> PyResult<Self> {
        let _ = metric_from_i32(metric)?;
        let _ = element_type_from_i32(element_type)?;
        Ok(Self {
            dimensions,
            metric,
            element_type,
        })
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
    pub(crate) fn element_type(&self) -> i32 {
        self.element_type
    }

    pub(crate) fn __repr__(&self) -> String {
        format!(
            "VectorCollectionOptions(dimensions={}, metric={}, element_type={})",
            self.dimensions, self.metric, self.element_type
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
    pub(crate) fn element_type(&self) -> i32 {
        self.values.element_type_i32()
    }

    #[getter]
    pub(crate) fn values(&self, py: Python<'_>) -> PyResult<Py<PyAny>> {
        self.values.to_py(py)
    }

    pub(crate) fn __repr__(&self) -> String {
        format!(
            "Vector(id='{}', element_type={}, values_len={})",
            self.id,
            self.values.element_type_i32(),
            self.values.len()
        )
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
    pub(crate) fn element_type(&self) -> i32 {
        self.element_type
    }

    #[getter]
    pub(crate) fn vector_count(&self) -> u64 {
        self.vector_count
    }

    pub(crate) fn __repr__(&self) -> String {
        format!(
            "VectorCollectionInfo(name='{}', dimensions={}, metric={}, element_type={}, vector_count={})",
            self.name, self.dimensions, self.metric, self.element_type, self.vector_count
        )
    }
}

#[pymethods]
impl PyVectorInput {
    #[new]
    pub(crate) fn new(id: String, element_type: i32, values: &Bound<'_, PyAny>) -> PyResult<Self> {
        Ok(Self {
            id,
            values: vector_values_from_py(element_type, values)?,
        })
    }

    #[getter]
    pub(crate) fn id(&self) -> String {
        self.id.clone()
    }

    #[getter]
    pub(crate) fn element_type(&self) -> i32 {
        self.values.element_type_i32()
    }

    #[getter]
    pub(crate) fn values(&self, py: Python<'_>) -> PyResult<Py<PyAny>> {
        self.values.to_py(py)
    }

    pub(crate) fn __repr__(&self) -> String {
        format!(
            "VectorInput(id='{}', element_type={}, values_len={})",
            self.id,
            self.values.element_type_i32(),
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

pub(crate) fn collection_options_from_py(
    value: &Bound<'_, PyAny>,
) -> PyResult<zova_rust::VectorCollectionOptions> {
    let options = value.extract::<PyRef<'_, PyVectorCollectionOptions>>()?;
    Ok(zova_rust::VectorCollectionOptions {
        dimensions: options.dimensions,
        metric: metric_from_i32(options.metric)?,
        element_type: element_type_from_i32(options.element_type)?,
    })
}

pub(crate) fn vector_inputs_from_py(value: &Bound<'_, PyAny>) -> PyResult<Vec<PyVectorInput>> {
    let mut vectors = Vec::new();
    for item in value.try_iter()? {
        let item = item?;
        let vector = item.extract::<PyRef<'_, PyVectorInput>>()?;
        vectors.push(vector.clone());
    }
    Ok(vectors)
}

pub(crate) fn vector_input_refs<'a>(
    vectors: &'a [PyVectorInput],
) -> Vec<zova_rust::VectorInput<'a>> {
    vectors
        .iter()
        .map(|vector| zova_rust::VectorInput {
            id: vector.id.as_str(),
            values: vector.values.as_rust(),
        })
        .collect()
}

pub(crate) fn candidate_refs(candidate_ids: &[String]) -> Vec<&str> {
    candidate_ids.iter().map(String::as_str).collect()
}

pub(crate) fn py_vector(vector: zova_rust::Vector) -> PyVector {
    PyVector {
        id: vector.id,
        values: match vector.values {
            zova_rust::VectorValuesOwned::F32(values) => PyVectorValues::F32(values),
            zova_rust::VectorValuesOwned::F16(values) => PyVectorValues::F16(values),
            zova_rust::VectorValuesOwned::I8(values) => PyVectorValues::I8(values),
        },
    }
}

pub(crate) fn py_collection_info(info: zova_rust::VectorCollectionInfo) -> PyVectorCollectionInfo {
    PyVectorCollectionInfo {
        name: info.name,
        dimensions: info.dimensions,
        metric: metric_to_i32(info.metric),
        element_type: element_type_to_i32(info.element_type),
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

impl PyVectorValues {
    pub(crate) fn as_rust(&self) -> zova_rust::VectorValues<'_> {
        match self {
            Self::F32(values) => zova_rust::VectorValues::F32(values.as_slice()),
            Self::F16(values) => zova_rust::VectorValues::F16(values.as_slice()),
            Self::I8(values) => zova_rust::VectorValues::I8(values.as_slice()),
        }
    }

    fn element_type_i32(&self) -> i32 {
        match self {
            Self::F32(_) => 0,
            Self::F16(_) => 1,
            Self::I8(_) => 2,
        }
    }

    fn len(&self) -> usize {
        match self {
            Self::F32(values) => values.len(),
            Self::F16(values) => values.len(),
            Self::I8(values) => values.len(),
        }
    }

    fn to_py(&self, py: Python<'_>) -> PyResult<Py<PyAny>> {
        let list = match self {
            Self::F32(values) => PyList::new(py, values)?,
            Self::F16(values) => PyList::new(py, values)?,
            Self::I8(values) => PyList::new(py, values)?,
        };
        Ok(list.into_any().unbind())
    }
}

pub(crate) fn vector_values_from_py(
    element_type: i32,
    values: &Bound<'_, PyAny>,
) -> PyResult<PyVectorValues> {
    match element_type_from_i32(element_type)? {
        zova_rust::VectorElementType::F32 => Ok(PyVectorValues::F32(values.extract()?)),
        zova_rust::VectorElementType::F16 => Ok(PyVectorValues::F16(values.extract()?)),
        zova_rust::VectorElementType::I8 => Ok(PyVectorValues::I8(values.extract()?)),
    }
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

pub(crate) fn element_type_from_i32(element_type: i32) -> PyResult<zova_rust::VectorElementType> {
    match element_type {
        0 => Ok(zova_rust::VectorElementType::F32),
        1 => Ok(zova_rust::VectorElementType::F16),
        2 => Ok(zova_rust::VectorElementType::I8),
        _ => Err(PyValueError::new_err(format!(
            "invalid vector element type {element_type}; expected 0, 1, or 2"
        ))),
    }
}

pub(crate) fn element_type_to_i32(element_type: zova_rust::VectorElementType) -> i32 {
    match element_type {
        zova_rust::VectorElementType::F32 => 0,
        zova_rust::VectorElementType::F16 => 1,
        zova_rust::VectorElementType::I8 => 2,
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
