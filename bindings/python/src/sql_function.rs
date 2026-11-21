//! Application-defined scalar SQL functions backed by Python callables.

use pyo3::prelude::*;
use pyo3::types::{
    PyAny, PyBool, PyByteArray, PyBytes, PyFloat, PyInt, PyMemoryView, PyString, PyTuple,
};
use zova_rust::{SqlFunctionResult, SqlValue};

/// Call `function` with SQL arguments converted to None, int, float, str, or
/// bytes, and convert its return value back. An exception, or a return value
/// of another type, fails the SQL statement with its message.
pub(crate) fn call(function: &Py<PyAny>, args: &[SqlValue<'_>]) -> SqlFunctionResult {
    Python::attach(|py| {
        let args = args
            .iter()
            .map(|value| match *value {
                SqlValue::Null => py.None(),
                SqlValue::Integer(value) => PyInt::new(py, value).into_any().unbind(),
                SqlValue::Float(value) => PyFloat::new(py, value).into_any().unbind(),
                SqlValue::Text(value) => PyString::new(py, value).into_any().unbind(),
                SqlValue::Blob(value) => PyBytes::new(py, value).into_any().unbind(),
            })
            .collect::<Vec<_>>();
        let result = match PyTuple::new(py, args).and_then(|args| function.bind(py).call1(args)) {
            Ok(result) => result,
            Err(err) => return SqlFunctionResult::Error(err.to_string()),
        };
        sql_result(&result).unwrap_or_else(|err| SqlFunctionResult::Error(err.to_string()))
    })
}

fn sql_result(value: &Bound<'_, PyAny>) -> PyResult<SqlFunctionResult> {
    if value.is_none() {
        Ok(SqlFunctionResult::Null)
    } else if value.is_instance_of::<PyBool>() || value.is_instance_of::<PyInt>() {
        Ok(SqlFunctionResult::Integer(value.extract()?))
    } else if value.is_instance_of::<PyFloat>() {
        Ok(SqlFunctionResult::Float(value.extract()?))
    } else if value.is_instance_of::<PyString>() {
        Ok(SqlFunctionResult::Text(value.extract()?))
    } else if value.is_instance_of::<PyBytes>()
        || value.is_instance_of::<PyByteArray>()
        || value.is_instance_of::<PyMemoryView>()
    {
        Ok(SqlFunctionResult::Blob(value.extract()?))
    } else {
        Ok(SqlFunctionResult::Error(format!(
            "unsupported SQL function result type {}",
            value.get_type().name()?
        )))
    }
}
