use std::path::Path;
use std::sync::{Arc, Mutex};

use napi::bindgen_prelude::{BigInt, Uint8Array};
use napi::Result;
use napi_derive::napi;

use crate::error::{invalid_argument_error, misuse_error, zova_error};
use crate::statement::NativeStatement;
use crate::subscription::NativeSubscription;

struct DatabaseStateInner {
    database: Option<zova::SharedDatabase>,
    live_children: usize,
}

pub(crate) struct DatabaseState {
    inner: Mutex<DatabaseStateInner>,
}

impl DatabaseState {
    pub(crate) fn new(database: zova::SharedDatabase) -> Self {
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
#[derive(Default)]
pub struct NativeOpenOptions {
    pub read_only: Option<bool>,
    pub busy_timeout_ms: Option<u32>,
    pub extensions: Option<NativeExtensionOptions>,
}

#[napi(object)]
pub struct NativeExtensionOptions {
    pub bundle_paths: Vec<String>,
    pub trust_store_path: Option<String>,
    /// Addresses of `zova_plugin_descriptor_v1` values linked into this process.
    pub plugins: Option<Vec<BigInt>>,
}

/// Bundle selection plus linked plugins, copied out of JavaScript memory.
pub(crate) struct ExtensionSelection {
    pub(crate) options: zova::ExtensionOptions,
    pub(crate) plugins: Vec<zova::LinkedPlugin>,
}

impl NativeExtensionOptions {
    pub(crate) fn selection(options: Option<Self>) -> Result<ExtensionSelection> {
        let Some(options) = options else {
            return Ok(ExtensionSelection {
                options: zova::ExtensionOptions::default(),
                plugins: Vec::new(),
            });
        };
        let plugins = options
            .plugins
            .unwrap_or_default()
            .iter()
            .map(linked_plugin)
            .collect::<Result<Vec<_>>>()?;
        Ok(ExtensionSelection {
            options: zova::ExtensionOptions {
                bundle_paths: options.bundle_paths.into_iter().map(Into::into).collect(),
                trust_store_path: options.trust_store_path.map(Into::into),
            },
            plugins,
        })
    }
}

/// Wrap a descriptor address received from `LinkedPlugin.fromAddress`.
fn linked_plugin(address: &BigInt) -> Result<zova::LinkedPlugin> {
    let (negative, value, lossless) = address.get_u64();
    if negative || !lossless || value == 0 || usize::try_from(value).is_err() {
        return Err(invalid_argument_error(
            "linked plugin address must be a non-zero pointer",
        ));
    }
    let descriptor = value as usize as *const zova_sys::plugin::zova_plugin_descriptor_v1;
    // SAFETY: `LinkedPlugin.fromAddress` documents the caller's obligation: the
    // address names a descriptor that, with everything it points to, stays
    // valid and unchanged for the rest of the process and satisfies the
    // `zova_plugin.h` contract.
    Ok(unsafe { zova::LinkedPlugin::new(&*descriptor) })
}

fn open_options(options: &NativeOpenOptions) -> zova::OpenOptions {
    zova::OpenOptions {
        read_only: options.read_only.unwrap_or(false),
        busy_timeout_ms: options.busy_timeout_ms.unwrap_or(0),
    }
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

/// What `reclaimSpace` did for one member file.
#[napi(object)]
pub struct NativeReclaimedMember {
    pub member: String,
    pub auto_vacuum: String,
    pub page_size: u32,
    pub pages_released: f64,
    pub free_pages_left: f64,
}

impl From<zova::ReclaimedMember> for NativeReclaimedMember {
    fn from(member: zova::ReclaimedMember) -> Self {
        let name = match member.member {
            zova::ProgressMember::Main => "main",
            zova::ProgressMember::ObjectStore => "object_store",
            zova::ProgressMember::VectorStore => "vector_store",
            zova::ProgressMember::GraphStore => "graph_store",
            _ => "unknown",
        };
        Self {
            member: name.to_owned(),
            auto_vacuum: member.auto_vacuum.name().to_owned(),
            page_size: member.page_size,
            pages_released: member.pages_released as f64,
            free_pages_left: member.free_pages_left as f64,
        }
    }
}

/// Journal mode of one member of a database set.
#[napi(object)]
pub struct NativeJournalModeMember {
    pub member: String,
    pub journal_mode: String,
}

impl From<zova::JournalModeMember> for NativeJournalModeMember {
    fn from(member: zova::JournalModeMember) -> Self {
        Self {
            member: progress_member_name(member.member).to_owned(),
            journal_mode: member.journal_mode.name().to_owned(),
        }
    }
}

/// What `checkpoint` did for one member file.
#[napi(object)]
pub struct NativeCheckpointedMember {
    pub member: String,
    pub journal_mode: String,
    pub busy: bool,
    pub wal_frames: f64,
    pub checkpointed_frames: f64,
}

impl From<zova::CheckpointedMember> for NativeCheckpointedMember {
    fn from(member: zova::CheckpointedMember) -> Self {
        Self {
            member: progress_member_name(member.member).to_owned(),
            journal_mode: member.journal_mode.name().to_owned(),
            busy: member.busy,
            wal_frames: member.wal_frames as f64,
            checkpointed_frames: member.checkpointed_frames as f64,
        }
    }
}

fn progress_member_name(member: zova::ProgressMember) -> &'static str {
    match member {
        zova::ProgressMember::Main => "main",
        zova::ProgressMember::ObjectStore => "object_store",
        zova::ProgressMember::VectorStore => "vector_store",
        zova::ProgressMember::GraphStore => "graph_store",
        _ => "unknown",
    }
}

pub(crate) fn parse_journal_mode(mode: &str) -> Result<zova::JournalMode> {
    Ok(match mode {
        "delete" => zova::JournalMode::Delete,
        "truncate" => zova::JournalMode::Truncate,
        "persist" => zova::JournalMode::Persist,
        "memory" => zova::JournalMode::Memory,
        "wal" => zova::JournalMode::Wal,
        "off" => zova::JournalMode::Off,
        _ => {
            return Err(invalid_argument_error(
                "journal mode must be \"delete\", \"truncate\", \"persist\" or \"wal\"",
            ))
        }
    })
}

pub(crate) fn parse_commit_protocol(protocol: &str) -> Result<zova::CommitProtocol> {
    Ok(match protocol {
        "none" => zova::CommitProtocol::None,
        "cwal" => zova::CommitProtocol::Cwal,
        _ => {
            return Err(invalid_argument_error(
                "commit protocol must be \"none\" or \"cwal\"",
            ))
        }
    })
}

pub(crate) fn parse_checkpoint_mode(mode: Option<&str>) -> Result<zova::CheckpointMode> {
    Ok(match mode.unwrap_or("passive") {
        "passive" => zova::CheckpointMode::Passive,
        "full" => zova::CheckpointMode::Full,
        "restart" => zova::CheckpointMode::Restart,
        "truncate" => zova::CheckpointMode::Truncate,
        _ => {
            return Err(invalid_argument_error(
                "checkpoint mode must be \"passive\", \"full\", \"restart\" or \"truncate\"",
            ))
        }
    })
}

/// `reclaimSpace` options from JavaScript numbers. `max_pages` must be a
/// non-negative safe integer; omitted values select the Zova defaults.
pub(crate) fn reclaim_options(
    max_pages: Option<f64>,
    step_pages: Option<u32>,
) -> Result<zova::ReclaimOptions> {
    let defaults = zova::ReclaimOptions::default();
    let max_pages = match max_pages {
        None => defaults.max_pages,
        Some(value) if value >= 0.0 && value.fract() == 0.0 && value <= 9_007_199_254_740_991.0 => {
            value as u64
        }
        Some(_) => {
            return Err(invalid_argument_error(
                "maxPages must be a non-negative safe integer",
            ))
        }
    };
    Ok(zova::ReclaimOptions {
        max_pages,
        step_pages: step_pages.unwrap_or(defaults.step_pages),
    })
}

#[napi(object)]
pub struct NativeFormatInfo {
    pub format_version: u32,
    pub compatibility: String,
}

/// Probe a `.zova` file's storage format without opening or mutating it.
#[napi]
#[cfg_attr(test, allow(dead_code))]
pub fn probe_format(path: String) -> Result<NativeFormatInfo> {
    let info = zova::probe_format(path).map_err(zova_error)?;
    Ok(NativeFormatInfo {
        format_version: info.format_version,
        compatibility: info.compatibility.name().to_owned(),
    })
}

/// Migrate a `.zova` file forward to this release's storage format.
#[napi]
#[cfg_attr(test, allow(dead_code))]
pub fn migrate_database(
    source: String,
    destination: String,
    verify: Option<bool>,
    extensions: Option<NativeExtensionOptions>,
) -> Result<()> {
    let selection = NativeExtensionOptions::selection(extensions)?;
    zova::migrate_database_with_plugins(
        source,
        destination,
        zova::MigrateOptions {
            verify: verify.unwrap_or(true),
        },
        &selection.options,
        &selection.plugins,
    )
    .map_err(zova_error)
}

/// Load a `.zovaext` bundle's entrypoint and validate it without trusting it.
#[napi]
#[cfg_attr(test, allow(dead_code))]
pub fn verify_extension_bundle(
    bundle_path: String,
    trust_store_path: Option<String>,
) -> Result<()> {
    zova::verify_extension_bundle(bundle_path, trust_store_path.as_deref().map(Path::new))
        .map_err(zova_error)
}

/// Record a bundle's manifest and library hash in the selected trust store.
#[napi]
#[cfg_attr(test, allow(dead_code))]
pub fn trust_extension_bundle(bundle_path: String, trust_store_path: Option<String>) -> Result<()> {
    zova::trust_extension_bundle(bundle_path, trust_store_path.as_deref().map(Path::new))
        .map_err(zova_error)
}

/// Remove trust records matching a bundle path or extension name.
#[napi]
#[cfg_attr(test, allow(dead_code))]
pub fn untrust_extension_bundle(
    identifier: String,
    trust_store_path: Option<String>,
) -> Result<bool> {
    zova::untrust_extension_bundle(&identifier, trust_store_path.as_deref().map(Path::new))
        .map_err(zova_error)
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
pub fn restore_backup_to_memory(source: String, verify: Option<bool>) -> Result<NativeDatabase> {
    let database = zova::SharedDatabase::restore_backup_to_memory(
        source,
        zova::RestoreOptions {
            verify: verify.unwrap_or(true),
        },
    )
    .map_err(zova_error)?;
    Ok(NativeDatabase {
        state: Arc::new(DatabaseState::new(database)),
    })
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

impl NativeDatabase {
    fn from_shared(database: zova::SharedDatabase) -> Self {
        Self {
            state: Arc::new(DatabaseState::new(database)),
        }
    }
}

#[napi]
impl NativeDatabase {
    #[napi(factory)]
    pub fn create(path: String, extensions: Option<NativeExtensionOptions>) -> Result<Self> {
        let selection = NativeExtensionOptions::selection(extensions)?;
        let database = if selection.plugins.is_empty() {
            zova::SharedDatabase::create_with_extensions(path, &selection.options)
        } else {
            zova::SharedDatabase::create_with_plugins(path, &selection.options, &selection.plugins)
        }
        .map_err(zova_error)?;
        Ok(Self::from_shared(database))
    }

    /// Create a database with creation-time settings. `page_size` 0 or absent
    /// keeps SQLite's default.
    #[napi(factory)]
    pub fn create_with_options(path: String, page_size: Option<u32>) -> Result<Self> {
        let database = zova::SharedDatabase::create_with_options(
            path,
            zova::CreateOptions {
                page_size: page_size.unwrap_or(0),
            },
        )
        .map_err(zova_error)?;
        Ok(Self::from_shared(database))
    }

    #[napi(factory)]
    pub fn create_memory() -> Result<Self> {
        let database = zova::SharedDatabase::create_memory().map_err(zova_error)?;
        Ok(Self::from_shared(database))
    }

    #[napi(factory)]
    pub fn open(path: String, options: Option<NativeOpenOptions>) -> Result<Self> {
        let options = options.unwrap_or_default();
        let open = open_options(&options);
        let selection = NativeExtensionOptions::selection(options.extensions)?;
        let database = if selection.plugins.is_empty() {
            zova::SharedDatabase::open_with_extensions(path, open, &selection.options)
        } else {
            zova::SharedDatabase::open_with_plugins(
                path,
                open,
                &selection.options,
                &selection.plugins,
            )
        }
        .map_err(zova_error)?;
        Ok(Self::from_shared(database))
    }

    /// Open for extension maintenance without running installed extension
    /// hooks, so `extensionUpgrade` and `extensionRebuild` can repair a
    /// database whose extension check fails.
    #[napi(factory)]
    pub fn open_for_extension_upgrade(
        path: String,
        options: Option<NativeOpenOptions>,
    ) -> Result<Self> {
        let options = options.unwrap_or_default();
        let open = open_options(&options);
        let selection = NativeExtensionOptions::selection(options.extensions)?;
        let database = if selection.plugins.is_empty() {
            zova::SharedDatabase::open_for_extension_upgrade(path, open, &selection.options)
        } else {
            zova::SharedDatabase::open_for_extension_upgrade_with_plugins(
                path,
                open,
                &selection.options,
                &selection.plugins,
            )
        }
        .map_err(zova_error)?;
        Ok(Self::from_shared(database))
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

    /// Run an installed extension's upgrade hook to the loaded version.
    #[napi]
    pub fn extension_upgrade(&self, name: String) -> Result<()> {
        self.state
            .database()?
            .extension_upgrade(&name)
            .map_err(zova_error)
    }

    /// Run an installed extension's rebuild hook to recreate derived state.
    #[napi]
    pub fn extension_rebuild(&self, name: String) -> Result<()> {
        self.state
            .database()?
            .extension_rebuild(&name)
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
    pub fn reclaim_space(
        &self,
        max_pages: Option<f64>,
        step_pages: Option<u32>,
    ) -> Result<Vec<NativeReclaimedMember>> {
        let options = reclaim_options(max_pages, step_pages)?;
        let members = self
            .state
            .database()?
            .reclaim_space(options)
            .map_err(zova_error)?;
        Ok(members
            .into_iter()
            .map(NativeReclaimedMember::from)
            .collect())
    }

    #[napi]
    pub fn set_journal_mode(&self, mode: String) -> Result<Vec<NativeJournalModeMember>> {
        let mode = parse_journal_mode(&mode)?;
        let members = self
            .state
            .database()?
            .set_journal_mode(mode)
            .map_err(zova_error)?;
        Ok(members
            .into_iter()
            .map(NativeJournalModeMember::from)
            .collect())
    }

    #[napi]
    pub fn journal_modes(&self) -> Result<Vec<NativeJournalModeMember>> {
        let members = self.state.database()?.journal_modes().map_err(zova_error)?;
        Ok(members
            .into_iter()
            .map(NativeJournalModeMember::from)
            .collect())
    }

    #[napi]
    pub fn checkpoint(&self, mode: Option<String>) -> Result<Vec<NativeCheckpointedMember>> {
        let mode = parse_checkpoint_mode(mode.as_deref())?;
        let members = self
            .state
            .database()?
            .checkpoint(mode)
            .map_err(zova_error)?;
        Ok(members
            .into_iter()
            .map(NativeCheckpointedMember::from)
            .collect())
    }

    #[napi]
    pub fn set_commit_protocol(&self, protocol: String) -> Result<()> {
        let protocol = parse_commit_protocol(&protocol)?;
        self.state
            .database()?
            .set_commit_protocol(protocol)
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

    #[napi]
    pub fn kv_get(&self, namespace: Uint8Array, key: Uint8Array) -> Result<Option<Uint8Array>> {
        let database = self.state.database()?;
        let value = database
            .kv_get(namespace.as_ref(), key.as_ref())
            .map_err(zova_error)?;
        Ok(value.map(|value| Uint8Array::new(value)))
    }

    #[napi]
    pub fn kv_get_many(
        &self,
        namespace: Uint8Array,
        keys: Vec<Uint8Array>,
    ) -> Result<Vec<Option<Uint8Array>>> {
        let database = self.state.database()?;
        let key_refs: Vec<&[u8]> = keys.iter().map(|key| key.as_ref()).collect();
        let values = database
            .kv_get_many(namespace.as_ref(), &key_refs)
            .map_err(zova_error)?;
        Ok(values
            .into_iter()
            .map(|value| value.map(|value| Uint8Array::new(value)))
            .collect())
    }

    #[napi]
    pub fn kv_put(&self, namespace: Uint8Array, key: Uint8Array, value: Uint8Array) -> Result<()> {
        self.state
            .database()?
            .kv_put(namespace.as_ref(), key.as_ref(), value.as_ref())
            .map_err(zova_error)
    }

    #[napi]
    pub fn kv_put_many(&self, namespace: Uint8Array, entries: Vec<NativeKvEntry>) -> Result<()> {
        let owned: Vec<(Vec<u8>, Vec<u8>)> = entries
            .into_iter()
            .map(|entry| (entry.key.to_vec(), entry.value.to_vec()))
            .collect();
        let entries = owned
            .iter()
            .map(|(key, value)| zova::KvEntry {
                key: key.as_slice(),
                value: value.as_slice(),
            })
            .collect::<Vec<_>>();
        self.state
            .database()?
            .kv_put_many(namespace.as_ref(), &entries)
            .map_err(zova_error)
    }

    #[napi]
    pub fn kv_delete(&self, namespace: Uint8Array, key: Uint8Array) -> Result<()> {
        self.state
            .database()?
            .kv_delete(namespace.as_ref(), key.as_ref())
            .map_err(zova_error)
    }

    #[napi]
    pub fn kv_delete_many(&self, namespace: Uint8Array, keys: Vec<Uint8Array>) -> Result<()> {
        let key_refs: Vec<&[u8]> = keys.iter().map(|key| key.as_ref()).collect();
        self.state
            .database()?
            .kv_delete_many(namespace.as_ref(), &key_refs)
            .map_err(zova_error)
    }

    #[napi]
    pub fn kv_count(&self, namespace: Uint8Array) -> Result<BigInt> {
        let database = self.state.database()?;
        let count = database.kv_count(namespace.as_ref()).map_err(zova_error)?;
        Ok(BigInt::from(count))
    }

    #[napi]
    pub fn kv_clear_namespace(&self, namespace: Uint8Array) -> Result<()> {
        self.state
            .database()?
            .kv_clear_namespace(namespace.as_ref())
            .map_err(zova_error)
    }

    #[napi]
    pub fn kv_scan(
        &self,
        namespace: Uint8Array,
        options: NativeKvScanOptions,
    ) -> Result<NativeKvScanPage> {
        let options = OwnedKvScanOptions::new(options)?;
        let page = options
            .scan(&self.state.database()?, namespace.as_ref())
            .map_err(zova_error)?;
        Ok(native_kv_scan_page(page))
    }

    #[napi]
    pub fn kv_put_if_absent(
        &self,
        namespace: Uint8Array,
        key: Uint8Array,
        value: Uint8Array,
    ) -> Result<bool> {
        self.state
            .database()?
            .kv_put_if_absent(namespace.as_ref(), key.as_ref(), value.as_ref())
            .map_err(zova_error)
    }

    #[napi]
    pub fn kv_compare_and_put(
        &self,
        namespace: Uint8Array,
        key: Uint8Array,
        expected: Uint8Array,
        value: Uint8Array,
    ) -> Result<bool> {
        self.state
            .database()?
            .kv_compare_and_put(
                namespace.as_ref(),
                key.as_ref(),
                expected.as_ref(),
                value.as_ref(),
            )
            .map_err(zova_error)
    }

    #[napi]
    pub fn kv_compare_and_delete(
        &self,
        namespace: Uint8Array,
        key: Uint8Array,
        expected: Uint8Array,
    ) -> Result<bool> {
        self.state
            .database()?
            .kv_compare_and_delete(namespace.as_ref(), key.as_ref(), expected.as_ref())
            .map_err(zova_error)
    }

    #[napi]
    pub fn listen(&self, channel: String) -> Result<NativeSubscription> {
        let database = self.state.register_child()?;
        match database.listen(&channel) {
            Ok(subscription) => Ok(NativeSubscription::new(subscription, self.state.clone())),
            Err(error) => {
                self.state.child_closed();
                Err(zova_error(error))
            }
        }
    }

    #[napi]
    pub fn notify(&self, channel: String, payload: String) -> Result<()> {
        self.state
            .database()?
            .notify(&channel, &payload)
            .map_err(zova_error)
    }
}

#[napi(object)]
pub struct NativeKvEntry {
    pub key: Uint8Array,
    pub value: Uint8Array,
}

#[napi(object)]
pub struct NativeKvScanOptions {
    pub prefix: Option<Uint8Array>,
    pub start: Option<Uint8Array>,
    pub end: Option<Uint8Array>,
    pub after: Option<Uint8Array>,
    pub limit: f64,
    pub keys_only: Option<bool>,
}

#[napi(object)]
pub struct NativeKvScanPage {
    pub entries: Vec<NativeKvEntry>,
    pub has_more: bool,
}

/// Scan options copied out of JavaScript memory, so they can cross threads.
pub(crate) struct OwnedKvScanOptions {
    prefix: Vec<u8>,
    start: Option<Vec<u8>>,
    end: Option<Vec<u8>>,
    after: Option<Vec<u8>>,
    limit: usize,
    keys_only: bool,
}

impl OwnedKvScanOptions {
    pub(crate) fn new(options: NativeKvScanOptions) -> Result<Self> {
        let limit = options.limit;
        if !limit.is_finite() || limit < 0.0 || limit.fract() != 0.0 || limit > usize::MAX as f64 {
            return Err(invalid_argument_error(
                "kv scan limit must be a non-negative integer",
            ));
        }
        Ok(Self {
            prefix: options
                .prefix
                .map(|bytes| bytes.to_vec())
                .unwrap_or_default(),
            start: options.start.map(|bytes| bytes.to_vec()),
            end: options.end.map(|bytes| bytes.to_vec()),
            after: options.after.map(|bytes| bytes.to_vec()),
            limit: limit as usize,
            keys_only: options.keys_only.unwrap_or(false),
        })
    }

    pub(crate) fn scan(
        &self,
        database: &zova::SharedDatabase,
        namespace: &[u8],
    ) -> zova::Result<zova::KvScanPage> {
        database.kv_scan(
            namespace,
            &zova::KvScanOptions {
                prefix: &self.prefix,
                start: self.start.as_deref(),
                end: self.end.as_deref(),
                after: self.after.as_deref(),
                limit: self.limit,
                keys_only: self.keys_only,
            },
        )
    }
}

pub(crate) fn native_kv_scan_page(page: zova::KvScanPage) -> NativeKvScanPage {
    NativeKvScanPage {
        entries: page
            .entries
            .into_iter()
            .map(|entry| NativeKvEntry {
                key: Uint8Array::new(entry.key),
                value: Uint8Array::new(entry.value),
            })
            .collect(),
        has_more: page.has_more,
    }
}
