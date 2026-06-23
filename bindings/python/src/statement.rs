use crate::error::{closed_error, zova_error};
use pyo3::prelude::*;
use pyo3::types::PyBytes;

#[pyclass(name = "Statement", unsendable)]
pub(crate) struct PyStatement {
    inner: Option<zova_rust::OwnedStatement>,
}

impl PyStatement {
    pub(crate) fn new(statement: zova_rust::OwnedStatement) -> Self {
        Self {
            inner: Some(statement),
        }
    }

    fn statement_mut(&mut self) -> PyResult<&mut zova_rust::OwnedStatement> {
        self.inner.as_mut().ok_or_else(|| closed_error("statement"))
    }
}

#[pymethods]
impl PyStatement {
    pub(crate) fn close(&mut self) {
        self.inner.take();
    }

    pub(crate) fn parameter_count(&mut self) -> PyResult<usize> {
        self.statement_mut()?.parameter_count().map_err(zova_error)
    }

    pub(crate) fn parameter_index(&mut self, name: &str) -> PyResult<Option<usize>> {
        self.statement_mut()?
            .parameter_index(name)
            .map_err(zova_error)
    }

    pub(crate) fn bind_null(&mut self, index: usize) -> PyResult<()> {
        self.statement_mut()?.bind_null(index).map_err(zova_error)
    }

    pub(crate) fn bind_int(&mut self, index: usize, value: i64) -> PyResult<()> {
        self.statement_mut()?
            .bind_i64(index, value)
            .map_err(zova_error)
    }

    pub(crate) fn bind_float(&mut self, index: usize, value: f64) -> PyResult<()> {
        self.statement_mut()?
            .bind_f64(index, value)
            .map_err(zova_error)
    }

    pub(crate) fn bind_text(&mut self, index: usize, value: &str) -> PyResult<()> {
        self.statement_mut()?
            .bind_text(index, value)
            .map_err(zova_error)
    }

    pub(crate) fn bind_blob(&mut self, index: usize, value: Vec<u8>) -> PyResult<()> {
        self.statement_mut()?
            .bind_blob(index, &value)
            .map_err(zova_error)
    }

    pub(crate) fn step(&mut self) -> PyResult<i32> {
        let step = self.statement_mut()?.step().map_err(zova_error)?;
        Ok(match step {
            zova_rust::Step::Row => 1,
            zova_rust::Step::Done => 2,
        })
    }

    pub(crate) fn reset(&mut self) -> PyResult<()> {
        self.statement_mut()?.reset().map_err(zova_error)
    }

    pub(crate) fn clear_bindings(&mut self) -> PyResult<()> {
        self.statement_mut()?.clear_bindings().map_err(zova_error)
    }

    pub(crate) fn column_count(&mut self) -> PyResult<usize> {
        self.statement_mut()?.column_count().map_err(zova_error)
    }

    pub(crate) fn column_name(&mut self, index: usize) -> PyResult<String> {
        self.statement_mut()?.column_name(index).map_err(zova_error)
    }

    pub(crate) fn column_type(&mut self, index: usize) -> PyResult<i32> {
        let column_type = self
            .statement_mut()?
            .column_type(index)
            .map_err(zova_error)?;
        Ok(match column_type {
            zova_rust::ColumnType::Integer => 1,
            zova_rust::ColumnType::Float => 2,
            zova_rust::ColumnType::Text => 3,
            zova_rust::ColumnType::Blob => 4,
            zova_rust::ColumnType::Null => 5,
        })
    }

    pub(crate) fn column_int(&mut self, index: usize) -> PyResult<i64> {
        self.statement_mut()?.column_i64(index).map_err(zova_error)
    }

    pub(crate) fn column_float(&mut self, index: usize) -> PyResult<f64> {
        self.statement_mut()?.column_f64(index).map_err(zova_error)
    }

    pub(crate) fn column_text(&mut self, index: usize) -> PyResult<Option<String>> {
        self.statement_mut()?.column_text(index).map_err(zova_error)
    }

    pub(crate) fn column_blob<'py>(
        &mut self,
        py: Python<'py>,
        index: usize,
    ) -> PyResult<Option<Bound<'py, PyBytes>>> {
        let value = self
            .statement_mut()?
            .column_blob(index)
            .map_err(zova_error)?;
        Ok(value.map(|bytes| PyBytes::new(py, &bytes)))
    }

    pub(crate) fn __enter__(slf: PyRefMut<'_, Self>) -> PyRefMut<'_, Self> {
        slf
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
