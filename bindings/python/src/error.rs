use pyo3::exceptions::{PyException, PyRuntimeError, PyValueError};
use pyo3::prelude::*;
use pyo3::{create_exception, PyTypeInfo};

create_exception!(zova._native, ZovaError, PyException);
create_exception!(zova._native, ClosedHandleError, PyRuntimeError);

pub(crate) fn closed_error(kind: &str) -> PyErr {
    ClosedHandleError::new_err(format!("{kind} is closed"))
}

pub(crate) fn zova_error(err: zova_rust::Error) -> PyErr {
    match &err {
        zova_rust::Error::InteriorNul { .. }
        | zova_rust::Error::NonUtf8Path
        | zova_rust::Error::InvalidUtf8Text => PyValueError::new_err(err.to_string()),
        zova_rust::Error::Zova {
            status,
            status_name,
            message,
        } => Python::attach(|py| {
            let display = err.to_string();
            let exc = match ZovaError::type_object(py).call1((display.clone(),)) {
                Ok(exc) => exc,
                Err(_) => return ZovaError::new_err(display),
            };
            let _ = exc.setattr("status", status.raw());
            let _ = exc.setattr("status_name", status_name.clone());
            let _ = exc.setattr("message", message.clone());
            PyErr::from_value(exc)
        }),
    }
}
