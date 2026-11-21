use std::path::Path;

use pyo3::exceptions::PyValueError;
use pyo3::prelude::*;

use crate::error::zova_error;

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

/// A C-v1 plugin descriptor linked into this process.
///
/// Linked plugins need no `.zovaext` bundle and no trust record: the process
/// vouches for code it links. Pass them through `plugins=` when creating,
/// opening, or migrating a database.
#[pyclass(name = "LinkedPlugin", frozen, skip_from_py_object)]
#[derive(Clone, Copy)]
pub(crate) struct PyLinkedPlugin {
    pub(crate) plugin: zova_rust::LinkedPlugin,
}

#[pymethods]
impl PyLinkedPlugin {
    /// Wrap the `zova_plugin_descriptor_v1` at `address`, for example
    /// `ctypes.addressof(descriptor)` or the address a native module returns.
    ///
    /// This is unchecked: the descriptor and everything it points to must
    /// stay valid and unchanged for the rest of the process, its strings must
    /// be NUL-terminated, and its hooks must be safe to call from any thread
    /// that uses a database opened with it. Violations crash the process.
    #[staticmethod]
    fn from_address(address: usize) -> PyResult<Self> {
        if address == 0 {
            return Err(PyValueError::new_err("plugin descriptor address is null"));
        }
        let descriptor = address as *const zova_sys::plugin::zova_plugin_descriptor_v1;
        // Safety: the caller vouches for the descriptor as documented above.
        let plugin = unsafe { zova_rust::LinkedPlugin::new(&*descriptor) };
        Ok(Self { plugin })
    }

    fn __repr__(&self) -> String {
        format!("{:?}", self.plugin)
    }
}

pub(crate) fn linked_plugins(
    plugins: Option<Vec<PyRef<'_, PyLinkedPlugin>>>,
) -> Vec<zova_rust::LinkedPlugin> {
    plugins
        .unwrap_or_default()
        .iter()
        .map(|plugin| plugin.plugin)
        .collect()
}

/// Load a `.zovaext` bundle's entrypoint and validate it without trusting it.
/// `trust_store_path=None` selects Zova's default trust store.
#[pyfunction]
#[pyo3(signature = (bundle_path, *, trust_store_path = None))]
pub(crate) fn verify_extension_bundle(
    bundle_path: &str,
    trust_store_path: Option<String>,
) -> PyResult<()> {
    zova_rust::verify_extension_bundle(bundle_path, trust_store_path.as_deref().map(Path::new))
        .map_err(zova_error)
}

/// Record a bundle's manifest and library hash in the selected trust store.
#[pyfunction]
#[pyo3(signature = (bundle_path, *, trust_store_path = None))]
pub(crate) fn trust_extension_bundle(
    bundle_path: &str,
    trust_store_path: Option<String>,
) -> PyResult<()> {
    zova_rust::trust_extension_bundle(bundle_path, trust_store_path.as_deref().map(Path::new))
        .map_err(zova_error)
}

/// Remove trust records matching a bundle path or an extension name. Returns
/// whether any record was removed.
#[pyfunction]
#[pyo3(signature = (identifier, *, trust_store_path = None))]
pub(crate) fn untrust_extension_bundle(
    identifier: &str,
    trust_store_path: Option<String>,
) -> PyResult<bool> {
    zova_rust::untrust_extension_bundle(identifier, trust_store_path.as_deref().map(Path::new))
        .map_err(zova_error)
}
