use std::ops::ControlFlow;

use pyo3::prelude::*;

use crate::error::zova_error;

/// One progress event from `backup_to`, `compact_to`, or `migrate_database`.
///
/// `phase` is "copy" (pages), "migrate" (format steps), "verify" (stored
/// items), or "publish" (files) and fixes the unit of `done` and `total`.
/// `member` is "main", "object_store", "vector_store", "graph_store", or
/// `None` for the whole-set "verify" and "publish" phases.
#[pyclass(name = "Progress", frozen, skip_from_py_object)]
pub(crate) struct PyProgress {
    #[pyo3(get)]
    phase: &'static str,
    #[pyo3(get)]
    member: Option<&'static str>,
    #[pyo3(get)]
    done: u64,
    #[pyo3(get)]
    total: u64,
}

#[pymethods]
impl PyProgress {
    fn __repr__(&self) -> String {
        format!(
            "Progress(phase={:?}, member={}, done={}, total={})",
            self.phase,
            self.member.map_or("None".to_owned(), |m| format!("{m:?}")),
            self.done,
            self.total
        )
    }
}

impl From<zova_rust::Progress> for PyProgress {
    fn from(progress: zova_rust::Progress) -> Self {
        let phase = match progress.phase {
            zova_rust::ProgressPhase::Copy => "copy",
            zova_rust::ProgressPhase::Migrate => "migrate",
            zova_rust::ProgressPhase::Verify => "verify",
            zova_rust::ProgressPhase::Publish => "publish",
            _ => "unknown",
        };
        let member = progress.member.map(|member| match member {
            zova_rust::ProgressMember::Main => "main",
            zova_rust::ProgressMember::ObjectStore => "object_store",
            zova_rust::ProgressMember::VectorStore => "vector_store",
            zova_rust::ProgressMember::GraphStore => "graph_store",
            _ => "unknown",
        });
        Self {
            phase,
            member,
            done: progress.done,
            total: progress.total,
        }
    }
}

/// Calls a Python progress callable. An exception raised by the callable
/// cancels the operation and is re-raised once the operation returns.
pub(crate) struct ProgressHandler {
    callback: Py<PyAny>,
    error: Option<PyErr>,
}

impl ProgressHandler {
    pub(crate) fn new(callback: Py<PyAny>) -> Self {
        Self {
            callback,
            error: None,
        }
    }

    pub(crate) fn call(&mut self, progress: zova_rust::Progress) -> ControlFlow<()> {
        if self.error.is_some() {
            return ControlFlow::Break(());
        }
        Python::attach(
            |py| match self.callback.call1(py, (PyProgress::from(progress),)) {
                Ok(_) => ControlFlow::Continue(()),
                Err(err) => {
                    self.error = Some(err);
                    ControlFlow::Break(())
                }
            },
        )
    }

    pub(crate) fn finish<T>(self, result: zova_rust::Result<T>) -> PyResult<T> {
        if let Some(err) = self.error {
            return Err(err);
        }
        result.map_err(zova_error)
    }
}
