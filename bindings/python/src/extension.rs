use pyo3::prelude::*;

#[pyclass(name = "ExtensionInfo", frozen, skip_from_py_object)]
#[derive(Clone)]
pub(crate) struct PyExtensionInfo {
    #[pyo3(get)]
    name: String,
    #[pyo3(get)]
    version: String,
    #[pyo3(get)]
    storage_prefix: String,
    #[pyo3(get)]
    zova_abi_min: String,
    #[pyo3(get)]
    capabilities: String,
    #[pyo3(get)]
    required: bool,
    #[pyo3(get)]
    installed_at_unix: i64,
    #[pyo3(get)]
    manifest_json: String,
}

#[pymethods]
impl PyExtensionInfo {
    pub(crate) fn __repr__(&self) -> String {
        format!(
            "ExtensionInfo(name='{}', version='{}', storage_prefix='{}')",
            self.name, self.version, self.storage_prefix
        )
    }
}

pub(crate) fn py_extension_info(info: zova_rust::ExtensionInfo) -> PyExtensionInfo {
    PyExtensionInfo {
        name: info.name,
        version: info.version,
        storage_prefix: info.storage_prefix,
        zova_abi_min: info.zova_abi_min,
        capabilities: info.capabilities,
        required: info.required,
        installed_at_unix: info.installed_at_unix,
        manifest_json: info.manifest_json,
    }
}

pub(crate) fn py_extension_infos(items: Vec<zova_rust::ExtensionInfo>) -> Vec<PyExtensionInfo> {
    items.into_iter().map(py_extension_info).collect()
}
