use crate::error::{closed_error, zova_error};
use pyo3::prelude::*;
use pyo3::types::PyAny;

#[pyclass(name = "Notification", frozen, skip_from_py_object)]
#[derive(Clone)]
pub(crate) struct PyNotification {
    #[pyo3(get)]
    channel: String,
    #[pyo3(get)]
    payload: String,
    #[pyo3(get)]
    sequence: u64,
    #[pyo3(get)]
    dropped_before: u64,
}

#[pyclass(name = "Subscription", unsendable)]
pub(crate) struct PySubscription {
    pub(crate) inner: Option<zova_rust::Subscription>,
}

pub(crate) fn py_notification(notification: zova_rust::Notification) -> PyNotification {
    PyNotification {
        channel: notification.channel,
        payload: notification.payload,
        sequence: notification.sequence,
        dropped_before: notification.dropped_before,
    }
}

#[pymethods]
impl PyNotification {
    pub(crate) fn __repr__(&self) -> String {
        format!(
            "Notification(channel={:?}, payload={:?}, sequence={}, dropped_before={})",
            self.channel, self.payload, self.sequence, self.dropped_before
        )
    }
}

#[pymethods]
impl PySubscription {
    pub(crate) fn try_receive(&mut self) -> PyResult<Option<PyNotification>> {
        let subscription = self
            .inner
            .as_mut()
            .ok_or_else(|| closed_error("subscription"))?;
        let notification = subscription.try_receive().map_err(zova_error)?;
        Ok(notification.map(py_notification))
    }

    pub(crate) fn close(&mut self) -> PyResult<()> {
        if let Some(mut subscription) = self.inner.take() {
            subscription.close().map_err(zova_error)?;
        }
        Ok(())
    }

    pub(crate) fn __enter__(slf: PyRefMut<'_, Self>) -> PyRefMut<'_, Self> {
        slf
    }

    pub(crate) fn __exit__(
        &mut self,
        _exc_type: Option<&Bound<'_, PyAny>>,
        _exc_value: Option<&Bound<'_, PyAny>>,
        _traceback: Option<&Bound<'_, PyAny>>,
    ) -> PyResult<bool> {
        self.close()?;
        Ok(false)
    }
}
