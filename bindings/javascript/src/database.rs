use std::sync::{Arc, Mutex};

use napi::bindgen_prelude::BigInt;
use napi::Result;
use napi_derive::napi;

use crate::error::{misuse_error, zova_error};
use crate::statement::NativeStatement;

struct DatabaseStateInner {
    database: Option<zova::SharedDatabase>,
    live_children: usize,
}

pub(crate) struct DatabaseState {
    inner: Mutex<DatabaseStateInner>,
}

impl DatabaseState {
    fn new(database: zova::SharedDatabase) -> Self {
        Self {
            inner: Mutex::new(DatabaseStateInner {
                database: Some(database),
                live_children: 0,
            }),
        }
    }

    pub(crate) fn database(&self) -> Result<zova::SharedDatabase> {
        self.inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .database
            .clone()
            .ok_or_else(|| misuse_error("database is closed"))
    }

    pub(crate) fn register_child(&self) -> Result<zova::SharedDatabase> {
        let mut inner = self
            .inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let database = inner
            .database
            .clone()
            .ok_or_else(|| misuse_error("database is closed"))?;
        inner.live_children += 1;
        Ok(database)
    }

    pub(crate) fn child_closed(&self) {
        let mut inner = self
            .inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        debug_assert!(inner.live_children > 0);
        inner.live_children = inner.live_children.saturating_sub(1);
    }

    fn close(&self) -> Result<()> {
        let mut inner = self
            .inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if inner.database.is_none() {
            return Ok(());
        }
        if inner.live_children != 0 {
            return Err(misuse_error(format!(
                "database has {} live child handle(s)",
                inner.live_children
            )));
        }
        inner.database.take();
        Ok(())
    }
}

#[napi(object)]
pub struct NativeOpenOptions {
    pub read_only: Option<bool>,
    pub busy_timeout_ms: Option<u32>,
}

#[napi(object)]
pub struct NativeExtensionInfo {
    pub name: String,
    pub version: String,
    pub storage_prefix: String,
    pub zova_abi_min: String,
    pub capabilities: String,
    pub required: bool,
    pub installed_at_unix: BigInt,
    pub manifest_json: String,
}

fn extension_info(info: zova::ExtensionInfo) -> NativeExtensionInfo {
    NativeExtensionInfo {
        name: info.name,
        version: info.version,
        storage_prefix: info.storage_prefix,
        zova_abi_min: info.zova_abi_min,
        capabilities: info.capabilities,
        required: info.required,
        installed_at_unix: BigInt::from(info.installed_at_unix),
        manifest_json: info.manifest_json,
    }
}

#[napi]
#[cfg_attr(test, allow(dead_code))]
pub fn restore_backup(source: String, destination: String, verify: Option<bool>) -> Result<()> {
    zova::restore_backup(
        source,
        destination,
        zova::RestoreOptions {
            verify: verify.unwrap_or(true),
        },
    )
    .map_err(zova_error)
}

#[napi]
#[cfg_attr(test, allow(dead_code))]
pub fn convert_sqlite_to_zova(source: String, destination: String) -> Result<()> {
    zova::SharedDatabase::convert_sqlite_to_zova(source, destination).map_err(zova_error)
}

#[napi(js_name = "NativeDatabase")]
pub struct NativeDatabase {
    pub(crate) state: Arc<DatabaseState>,
}

#[napi]
impl NativeDatabase {
    #[napi(factory)]
    pub fn create(path: String) -> Result<Self> {
        let database = zova::SharedDatabase::create(path).map_err(zova_error)?;
        Ok(Self {
            state: Arc::new(DatabaseState::new(database)),
        })
    }

    #[napi(factory)]
    pub fn open(path: String, options: Option<NativeOpenOptions>) -> Result<Self> {
        let options = options.unwrap_or(NativeOpenOptions {
            read_only: None,
            busy_timeout_ms: None,
        });
        let database = zova::SharedDatabase::open_with_options(
            path,
            zova::OpenOptions {
                read_only: options.read_only.unwrap_or(false),
                busy_timeout_ms: options.busy_timeout_ms.unwrap_or(0),
            },
        )
        .map_err(zova_error)?;
        Ok(Self {
            state: Arc::new(DatabaseState::new(database)),
        })
    }

    #[napi]
    pub fn close(&self) -> Result<()> {
        self.state.close()
    }

    #[napi(getter)]
    pub fn closed(&self) -> bool {
        self.state
            .inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .database
            .is_none()
    }

    #[napi]
    pub fn exec(&self, sql: String) -> Result<()> {
        self.state.database()?.exec(&sql).map_err(zova_error)
    }

    #[napi]
    pub fn prepare(&self, sql: String) -> Result<NativeStatement> {
        let database = self.state.register_child()?;
        match database.prepare(&sql) {
            Ok(statement) => Ok(NativeStatement::new(statement, self.state.clone())),
            Err(error) => {
                self.state.child_closed();
                Err(zova_error(error))
            }
        }
    }

    #[napi]
    pub fn begin(&self) -> Result<()> {
        self.state.database()?.begin().map_err(zova_error)
    }

    #[napi]
    pub fn begin_immediate(&self) -> Result<()> {
        self.state.database()?.begin_immediate().map_err(zova_error)
    }

    #[napi]
    pub fn commit(&self) -> Result<()> {
        self.state.database()?.commit().map_err(zova_error)
    }

    #[napi]
    pub fn rollback(&self) -> Result<()> {
        self.state.database()?.rollback().map_err(zova_error)
    }

    #[napi]
    pub fn savepoint(&self, name: String) -> Result<()> {
        self.state.database()?.savepoint(&name).map_err(zova_error)
    }

    #[napi]
    pub fn rollback_to_savepoint(&self, name: String) -> Result<()> {
        self.state
            .database()?
            .rollback_to_savepoint(&name)
            .map_err(zova_error)
    }

    #[napi]
    pub fn release_savepoint(&self, name: String) -> Result<()> {
        self.state
            .database()?
            .release_savepoint(&name)
            .map_err(zova_error)
    }

    #[napi]
    pub fn set_busy_timeout(&self, milliseconds: u32) -> Result<()> {
        self.state
            .database()?
            .set_busy_timeout(milliseconds)
            .map_err(zova_error)
    }

    #[napi]
    pub fn vacuum(&self) -> Result<()> {
        self.state.database()?.vacuum().map_err(zova_error)
    }

    #[napi]
    pub fn install_extension(&self, name: String) -> Result<()> {
        self.state
            .database()?
            .install_extension(&name)
            .map_err(zova_error)
    }

    #[napi]
    pub fn list_extensions(&self) -> Result<Vec<NativeExtensionInfo>> {
        self.state
            .database()?
            .list_extensions()
            .map(|items| items.into_iter().map(extension_info).collect())
            .map_err(zova_error)
    }

    #[napi]
    pub fn extension_info(&self, name: String) -> Result<NativeExtensionInfo> {
        self.state
            .database()?
            .extension_info(&name)
            .map(extension_info)
            .map_err(zova_error)
    }

    #[napi]
    pub fn check_extension(&self, name: String) -> Result<()> {
        self.state
            .database()?
            .check_extension(&name)
            .map_err(zova_error)
    }

    #[napi]
    pub fn check_extensions(&self) -> Result<()> {
        self.state
            .database()?
            .check_extensions()
            .map_err(zova_error)
    }

    #[napi]
    pub fn drop_extension(&self, name: String) -> Result<()> {
        self.state
            .database()?
            .drop_extension(&name)
            .map_err(zova_error)
    }

    #[napi]
    pub fn backup_to(&self, destination: String, verify: Option<bool>) -> Result<()> {
        self.state
            .database()?
            .backup_to(
                destination,
                zova::BackupOptions {
                    verify: verify.unwrap_or(true),
                },
            )
            .map_err(zova_error)
    }

    #[napi]
    pub fn compact_to(&self, destination: String, verify: Option<bool>) -> Result<()> {
        self.state
            .database()?
            .compact_to(
                destination,
                zova::CompactOptions {
                    verify: verify.unwrap_or(true),
                },
            )
            .map_err(zova_error)
    }

    #[napi]
    pub fn last_insert_rowid(&self) -> Result<BigInt> {
        self.state
            .database()?
            .last_insert_rowid()
            .map(BigInt::from)
            .map_err(zova_error)
    }

    #[napi]
    pub fn changes(&self) -> Result<BigInt> {
        self.state
            .database()?
            .changes()
            .map(BigInt::from)
            .map_err(zova_error)
    }

    #[napi]
    pub fn total_changes(&self) -> Result<BigInt> {
        self.state
            .database()?
            .total_changes()
            .map(BigInt::from)
            .map_err(zova_error)
    }
}
