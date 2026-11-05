use crate::error::{Error, Result};
use crate::kv::{
    kv_clear_namespace_raw, kv_count_raw, kv_delete_many_raw, kv_delete_raw, kv_get_many_raw,
    kv_get_raw, kv_put_many_raw, kv_put_raw, KvEntry,
};
use crate::notification::{listen_raw, notify_raw, Subscription};
use crate::progress::{Progress, ProgressBridge, ProgressMember};
use crate::statement::{OwnedStatement, Statement};
use std::ffi::{c_char, CStr, CString};
use std::fmt;
use std::marker::PhantomData;
use std::ops::ControlFlow;
use std::path::{Path, PathBuf};
use std::ptr::{self, NonNull};
use std::rc::Rc;

pub struct Database {
    pub(crate) inner: Rc<DatabaseInner>,
}

#[cfg(test)]
#[path = "plugin_operation_tests.rs"]
mod plugin_operation_tests;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct OpenOptions {
    pub read_only: bool,
    pub busy_timeout_ms: u32,
}

/// Explicit native-code selection. Bundles must already be trusted; opening
/// never grants trust or loads executable paths from database metadata.
/// Each bundle must match the host OS/architecture and runtime dependencies.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ExtensionOptions {
    pub bundle_paths: Vec<PathBuf>,
    /// None selects the existing default trust store.
    pub trust_store_path: Option<PathBuf>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BackupOptions {
    pub verify: bool,
}

impl Default for BackupOptions {
    fn default() -> Self {
        Self { verify: true }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CompactOptions {
    pub verify: bool,
}

impl Default for CompactOptions {
    fn default() -> Self {
        Self { verify: true }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RestoreOptions {
    pub verify: bool,
}

impl Default for RestoreOptions {
    fn default() -> Self {
        Self { verify: true }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MigrateOptions {
    pub verify: bool,
}

impl Default for MigrateOptions {
    fn default() -> Self {
        Self { verify: true }
    }
}

/// Compatibility class assigned to a Zova storage format version.
///
/// `Current` marks this release's storage format, `Migratable` marks an older
/// format this release can migrate forward, `UnsupportedLegacy` marks formats
/// older than the earliest migratable format, and `UnsupportedFuture` marks
/// formats newer than this release.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[non_exhaustive]
pub enum FormatCompatibility {
    Current,
    Migratable,
    UnsupportedLegacy,
    UnsupportedFuture,
}

impl FormatCompatibility {
    pub(crate) fn from_raw(code: i32) -> Self {
        match code {
            zova_sys::ZOVA_FORMAT_MIGRATABLE => Self::Migratable,
            zova_sys::ZOVA_FORMAT_UNSUPPORTED_LEGACY => Self::UnsupportedLegacy,
            zova_sys::ZOVA_FORMAT_UNSUPPORTED_FUTURE => Self::UnsupportedFuture,
            _ => Self::Current,
        }
    }

    /// Stable machine-readable name shared by every Zova binding.
    pub fn name(self) -> &'static str {
        match self {
            Self::Current => "current",
            Self::Migratable => "migratable",
            Self::UnsupportedLegacy => "unsupported_legacy",
            Self::UnsupportedFuture => "unsupported_future",
        }
    }
}

/// Storage-format facts about a `.zova` file, reported without opening or
/// mutating the file.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FormatInfo {
    pub format_version: u32,
    pub compatibility: FormatCompatibility,
}

/// Options for [`Database::reclaim_space`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ReclaimOptions {
    /// Most pages released by the call across every member; 0 releases every
    /// free page.
    pub max_pages: u64,
    /// Pages released per write transaction, so other writers can run in
    /// between. 0 selects the default of 1024.
    pub step_pages: u32,
}

impl Default for ReclaimOptions {
    fn default() -> Self {
        Self {
            max_pages: 0,
            step_pages: 1024,
        }
    }
}

/// SQLite `auto_vacuum` mode of one member file.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum AutoVacuum {
    None,
    Full,
    Incremental,
}

impl AutoVacuum {
    /// Stable machine-readable name shared by every Zova binding.
    pub fn name(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Full => "full",
            Self::Incremental => "incremental",
        }
    }
}

/// What [`Database::reclaim_space`] did for one member file.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ReclaimedMember {
    pub member: ProgressMember,
    pub auto_vacuum: AutoVacuum,
    pub page_size: u32,
    /// Free pages released back to the filesystem by this call.
    pub pages_released: u64,
    /// Free pages still inside the file. When `auto_vacuum` is
    /// [`AutoVacuum::None`], only a compact copy drops them.
    pub free_pages_left: u64,
}

pub(crate) fn reclaim_request(
    db: *mut zova_sys::zova_database,
    options: ReclaimOptions,
    out: &mut zova_sys::zova_reclaim_result,
) -> zova_sys::zova_database_reclaim_request {
    zova_sys::zova_database_reclaim_request {
        db,
        max_pages: options.max_pages,
        step_pages: options.step_pages,
        out_result: out,
    }
}

pub(crate) fn reclaimed_members(raw: &zova_sys::zova_reclaim_result) -> Vec<ReclaimedMember> {
    let count = raw.member_count.min(raw.members.len());
    raw.members[..count]
        .iter()
        .filter_map(|entry| {
            let member = match entry.member {
                zova_sys::ZOVA_PROGRESS_MEMBER_MAIN => ProgressMember::Main,
                zova_sys::ZOVA_PROGRESS_MEMBER_OBJECT_STORE => ProgressMember::ObjectStore,
                zova_sys::ZOVA_PROGRESS_MEMBER_VECTOR_STORE => ProgressMember::VectorStore,
                zova_sys::ZOVA_PROGRESS_MEMBER_GRAPH_STORE => ProgressMember::GraphStore,
                _ => return None,
            };
            let auto_vacuum = match entry.auto_vacuum {
                zova_sys::ZOVA_AUTO_VACUUM_NONE => AutoVacuum::None,
                zova_sys::ZOVA_AUTO_VACUUM_FULL => AutoVacuum::Full,
                zova_sys::ZOVA_AUTO_VACUUM_INCREMENTAL => AutoVacuum::Incremental,
                _ => return None,
            };
            Some(ReclaimedMember {
                member,
                auto_vacuum,
                page_size: entry.page_size,
                pages_released: entry.pages_released,
                free_pages_left: entry.free_pages_left,
            })
        })
        .collect()
}

/// C strings for one synchronous extension-selecting request. The pointers
/// returned by the accessors stay valid while this value is alive.
struct ExtensionCArgs {
    _bundles: Vec<CString>,
    pointers: Vec<*const c_char>,
    trust: Option<CString>,
}

impl ExtensionCArgs {
    fn new(extensions: &ExtensionOptions) -> Result<Self> {
        let bundles = extensions
            .bundle_paths
            .iter()
            .map(|p| path_to_cstring(p))
            .collect::<Result<Vec<_>>>()?;
        let pointers = bundles.iter().map(|p| p.as_ptr()).collect::<Vec<_>>();
        let trust = extensions
            .trust_store_path
            .as_deref()
            .map(path_to_cstring)
            .transpose()?;
        Ok(Self {
            _bundles: bundles,
            pointers,
            trust,
        })
    }

    fn bundle_paths(&self) -> *const *const c_char {
        if self.pointers.is_empty() {
            ptr::null()
        } else {
            self.pointers.as_ptr()
        }
    }

    fn bundle_count(&self) -> usize {
        self.pointers.len()
    }

    fn trust_store_path(&self) -> *const c_char {
        self.trust.as_ref().map_or(ptr::null(), |p| p.as_ptr())
    }
}

/// Synchronous C request shared by both safe handle types. The C handle owns
/// its registry/libraries after success, never these temporary C strings.
pub(crate) fn open_with_extensions_raw(
    path: &Path,
    create: bool,
    options: OpenOptions,
    extensions: &ExtensionOptions,
) -> Result<*mut zova_sys::zova_database> {
    let path = path_to_cstring(path)?;
    let extension_args = ExtensionCArgs::new(extensions)?;
    let mut db = ptr::null_mut();
    let mut message = empty_message();
    let request = zova_sys::zova_database_open_extensions_request {
        path: path.as_ptr(),
        flags: if options.read_only {
            zova_sys::ZOVA_OPEN_READ_ONLY
        } else {
            0
        },
        busy_timeout_ms: options.busy_timeout_ms,
        extension_bundle_paths: extension_args.bundle_paths(),
        extension_bundle_count: extension_args.bundle_count(),
        trust_store_path: extension_args.trust_store_path(),
        out_db: &mut db,
        out_error_message: &mut message,
    };
    // SAFETY: all inputs and outputs stay live throughout the synchronous call.
    let status = unsafe {
        if create {
            zova_sys::zova_database_create_with_extensions(&request)
        } else {
            zova_sys::zova_database_open_with_extensions(&request)
        }
    };
    if status != zova_sys::ZOVA_OK {
        return Err(Error::from_status(status, take_message(&mut message)));
    }
    Ok(db)
}

pub(crate) struct DatabaseInner {
    raw: NonNull<zova_sys::zova_database>,
    _not_send_sync: PhantomData<Rc<()>>,
}

impl Database {
    pub fn create(path: impl AsRef<Path>) -> Result<Self> {
        Self::open_or_create(path, true)
    }

    /// Create with explicitly selected, previously trusted native bundles.
    pub fn create_with_extensions(
        path: impl AsRef<Path>,
        extensions: &ExtensionOptions,
    ) -> Result<Self> {
        Self::with_extensions(path.as_ref(), true, OpenOptions::default(), extensions)
    }

    /// Open with explicitly selected native bundles. Child handles retain the
    /// connection and its libraries; no caller input is retained by native code.
    pub fn open_with_extensions(
        path: impl AsRef<Path>,
        options: OpenOptions,
        extensions: &ExtensionOptions,
    ) -> Result<Self> {
        Self::with_extensions(path.as_ref(), false, options, extensions)
    }

    fn with_extensions(
        path: &Path,
        create: bool,
        options: OpenOptions,
        extensions: &ExtensionOptions,
    ) -> Result<Self> {
        let db = open_with_extensions_raw(path, create, options, extensions)?;
        let raw = NonNull::new(db)
            .ok_or_else(|| Error::from_status(zova_sys::ZOVA_INVALID_ARGUMENT, None))?;
        Ok(Self {
            inner: Rc::new(DatabaseInner {
                raw,
                _not_send_sync: PhantomData,
            }),
        })
    }

    /// Create a new fully initialized volatile in-memory database.
    ///
    /// The database never creates database, WAL, or journal files, is isolated
    /// from every other in-memory database, and is reclaimed when dropped.
    pub fn create_memory() -> Result<Self> {
        let mut db = ptr::null_mut();
        let mut message = empty_message();
        let request = zova_sys::zova_database_create_memory_request {
            out_db: &mut db,
            out_error_message: &mut message,
        };
        let status = unsafe { zova_sys::zova_database_create_memory(&request) };
        if status != zova_sys::ZOVA_OK {
            return Err(Error::from_status(status, take_message(&mut message)));
        }
        let raw = NonNull::new(db)
            .ok_or_else(|| Error::from_status(zova_sys::ZOVA_INVALID_ARGUMENT, None))?;
        Ok(Self {
            inner: Rc::new(DatabaseInner {
                raw,
                _not_send_sync: PhantomData,
            }),
        })
    }

    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        Self::open_or_create(path, false)
    }

    pub fn open_with_options(path: impl AsRef<Path>, options: OpenOptions) -> Result<Self> {
        let path = path_to_cstring(path.as_ref())?;
        let mut db = ptr::null_mut();
        let mut message = empty_message();
        let flags = if options.read_only {
            zova_sys::ZOVA_OPEN_READ_ONLY
        } else {
            0
        };
        let request = zova_sys::zova_database_open_options_request {
            path: path.as_ptr(),
            flags,
            busy_timeout_ms: options.busy_timeout_ms,
            out_db: &mut db,
            out_error_message: &mut message,
        };
        let status = unsafe { zova_sys::zova_database_open_with_options(&request) };
        if status != zova_sys::ZOVA_OK {
            return Err(Error::from_status(status, take_message(&mut message)));
        }
        let raw = NonNull::new(db)
            .ok_or_else(|| Error::from_status(zova_sys::ZOVA_INVALID_ARGUMENT, None))?;
        Ok(Self {
            inner: Rc::new(DatabaseInner {
                raw,
                _not_send_sync: PhantomData,
            }),
        })
    }

    pub fn convert_sqlite_to_zova(
        source: impl AsRef<Path>,
        destination: impl AsRef<Path>,
    ) -> Result<()> {
        let source = path_to_cstring(source.as_ref())?;
        let destination = path_to_cstring(destination.as_ref())?;
        let mut message = empty_message();
        let request = zova_sys::zova_convert_sqlite_to_zova_request {
            source_path: source.as_ptr(),
            dest_path: destination.as_ptr(),
            out_error_message: &mut message,
        };
        let status = unsafe { zova_sys::zova_convert_sqlite_to_zova(&request) };
        if status == zova_sys::ZOVA_OK {
            return Ok(());
        }
        Err(Error::from_status(status, take_message(&mut message)))
    }

    pub fn backup_to(
        &mut self,
        destination: impl AsRef<Path>,
        options: BackupOptions,
    ) -> Result<()> {
        let destination = path_to_cstring(destination.as_ref())?;
        let request = zova_sys::zova_database_backup_request {
            db: self.raw_ptr(),
            destination_path: destination.as_ptr(),
            flags: backup_flags(options.verify),
        };
        self.status(unsafe { zova_sys::zova_database_backup(&request) })
    }

    pub fn compact_to(
        &mut self,
        destination: impl AsRef<Path>,
        options: CompactOptions,
    ) -> Result<()> {
        let destination = path_to_cstring(destination.as_ref())?;
        let request = zova_sys::zova_database_compact_request {
            db: self.raw_ptr(),
            destination_path: destination.as_ptr(),
            flags: compact_flags(options.verify),
        };
        self.status(unsafe { zova_sys::zova_database_compact(&request) })
    }

    /// [`Database::backup_to`] that reports [`Progress`] to `progress`.
    ///
    /// The closure runs on the calling thread while the call holds the
    /// handle. Returning [`ControlFlow::Break`] cancels the backup: it fails
    /// with [`crate::Status::Interrupted`] and leaves no destination.
    pub fn backup_to_with_progress(
        &mut self,
        destination: impl AsRef<Path>,
        options: BackupOptions,
        mut progress: impl FnMut(Progress) -> ControlFlow<()>,
    ) -> Result<()> {
        let destination = path_to_cstring(destination.as_ref())?;
        let mut bridge = ProgressBridge::new(&mut progress);
        let request = zova_sys::zova_database_backup_progress_request {
            db: self.raw_ptr(),
            destination_path: destination.as_ptr(),
            flags: backup_flags(options.verify),
            progress: bridge.callback(),
            progress_user_data: bridge.user_data(),
        };
        // SAFETY: the request, path, and bridge outlive the synchronous call.
        let status = unsafe { zova_sys::zova_database_backup_with_progress(&request) };
        let result = self.status(status);
        bridge.finish(result)
    }

    /// [`Database::compact_to`] that reports [`Progress`] to `progress`;
    /// cancellation works as in [`Database::backup_to_with_progress`].
    pub fn compact_to_with_progress(
        &mut self,
        destination: impl AsRef<Path>,
        options: CompactOptions,
        mut progress: impl FnMut(Progress) -> ControlFlow<()>,
    ) -> Result<()> {
        let destination = path_to_cstring(destination.as_ref())?;
        let mut bridge = ProgressBridge::new(&mut progress);
        let request = zova_sys::zova_database_compact_progress_request {
            db: self.raw_ptr(),
            destination_path: destination.as_ptr(),
            flags: compact_flags(options.verify),
            progress: bridge.callback(),
            progress_user_data: bridge.user_data(),
        };
        // SAFETY: the request, path, and bridge outlive the synchronous call.
        let status = unsafe { zova_sys::zova_database_compact_with_progress(&request) };
        let result = self.status(status);
        bridge.finish(result)
    }

    /// Release free pages of incremental auto-vacuum member files in place.
    ///
    /// Each step is its own short write transaction. Members are reported in
    /// a fixed order: the main database, then each attached object, vector,
    /// and graph store. A member whose `auto_vacuum` is [`AutoVacuum::None`]
    /// releases nothing; [`Database::compact_to`] writes a copy without its
    /// free pages. Fails with [`crate::Status::ObjectTransactionActive`]
    /// inside an explicit transaction; open object readers are allowed.
    pub fn reclaim_space(&mut self, options: ReclaimOptions) -> Result<Vec<ReclaimedMember>> {
        let mut out = zova_sys::zova_reclaim_result::default();
        let request = reclaim_request(self.raw_ptr(), options, &mut out);
        // SAFETY: the request and result outlive the synchronous call.
        self.status(unsafe { zova_sys::zova_database_reclaim(&request) })?;
        Ok(reclaimed_members(&out))
    }

    pub fn exec(&mut self, sql: &str) -> Result<()> {
        let sql = cstring(sql, "sql")?;
        let request = zova_sys::zova_database_exec_request {
            db: self.raw_ptr(),
            sql: sql.as_ptr(),
        };
        self.status(unsafe { zova_sys::zova_database_exec(&request) })
    }

    pub fn prepare(&mut self, sql: &str) -> Result<Statement<'_>> {
        let sql = cstring(sql, "sql")?;
        let mut statement = ptr::null_mut();
        let request = zova_sys::zova_database_prepare_request {
            db: self.raw_ptr(),
            sql: sql.as_ptr(),
            out_statement: &mut statement,
        };
        self.status(unsafe { zova_sys::zova_database_prepare(&request) })?;
        let raw = NonNull::new(statement)
            .ok_or_else(|| Error::from_status(zova_sys::ZOVA_INVALID_ARGUMENT, None))?;
        Ok(Statement::new(raw, self.raw_ptr()))
    }

    pub fn prepare_owned(&mut self, sql: &str) -> Result<OwnedStatement> {
        let sql = cstring(sql, "sql")?;
        let mut statement = ptr::null_mut();
        let request = zova_sys::zova_database_prepare_request {
            db: self.raw_ptr(),
            sql: sql.as_ptr(),
            out_statement: &mut statement,
        };
        self.status(unsafe { zova_sys::zova_database_prepare(&request) })?;
        let raw = NonNull::new(statement)
            .ok_or_else(|| Error::from_status(zova_sys::ZOVA_INVALID_ARGUMENT, None))?;
        Ok(OwnedStatement::new(raw, self.inner.clone()))
    }

    /// Get one key-value entry. Returns `Ok(None)` when the key is absent.
    pub fn kv_get(&mut self, namespace: &[u8], key: &[u8]) -> Result<Option<Vec<u8>>> {
        let db = self.raw_ptr();
        let status = |status| self.status(status);
        kv_get_raw(db, status, namespace, key)
    }

    /// Get several key-value entries, preserving input order and duplicates.
    /// Missing keys map to `None`.
    pub fn kv_get_many(
        &mut self,
        namespace: &[u8],
        keys: &[&[u8]],
    ) -> Result<Vec<Option<Vec<u8>>>> {
        let db = self.raw_ptr();
        let status = |status| self.status(status);
        kv_get_many_raw(db, status, namespace, keys)
    }

    /// Insert or replace one key-value entry.
    pub fn kv_put(&mut self, namespace: &[u8], key: &[u8], value: &[u8]) -> Result<()> {
        let db = self.raw_ptr();
        let status = |status| self.status(status);
        kv_put_raw(db, status, namespace, key, value)
    }

    /// Insert or replace several key-value entries in one atomic operation.
    pub fn kv_put_many(&mut self, namespace: &[u8], entries: &[KvEntry<'_>]) -> Result<()> {
        let db = self.raw_ptr();
        let status = |status| self.status(status);
        kv_put_many_raw(db, status, namespace, entries)
    }

    /// Delete one key-value entry. Deleting a missing key is not an error.
    pub fn kv_delete(&mut self, namespace: &[u8], key: &[u8]) -> Result<()> {
        let db = self.raw_ptr();
        let status = |status| self.status(status);
        kv_delete_raw(db, status, namespace, key)
    }

    /// Delete several key-value entries in one atomic operation. Missing keys
    /// are ignored.
    pub fn kv_delete_many(&mut self, namespace: &[u8], keys: &[&[u8]]) -> Result<()> {
        let db = self.raw_ptr();
        let status = |status| self.status(status);
        kv_delete_many_raw(db, status, namespace, keys)
    }

    /// Count entries in a namespace.
    pub fn kv_count(&mut self, namespace: &[u8]) -> Result<u64> {
        let db = self.raw_ptr();
        let status = |status| self.status(status);
        kv_count_raw(db, status, namespace)
    }

    /// Delete every entry in a namespace. An empty namespace is not an error.
    pub fn kv_clear_namespace(&mut self, namespace: &[u8]) -> Result<()> {
        let db = self.raw_ptr();
        let status = |status| self.status(status);
        kv_clear_namespace_raw(db, status, namespace)
    }

    pub fn begin(&mut self) -> Result<()> {
        self.simple(zova_sys::zova_database_begin)
    }

    pub fn begin_immediate(&mut self) -> Result<()> {
        self.simple(zova_sys::zova_database_begin_immediate)
    }

    pub fn commit(&mut self) -> Result<()> {
        self.simple(zova_sys::zova_database_commit)
    }

    pub fn rollback(&mut self) -> Result<()> {
        self.simple(zova_sys::zova_database_rollback)
    }

    pub fn savepoint(&mut self, name: &str) -> Result<()> {
        self.savepoint_call(name, zova_sys::zova_database_savepoint)
    }

    pub fn rollback_to_savepoint(&mut self, name: &str) -> Result<()> {
        self.savepoint_call(name, zova_sys::zova_database_rollback_to_savepoint)
    }

    pub fn release_savepoint(&mut self, name: &str) -> Result<()> {
        self.savepoint_call(name, zova_sys::zova_database_release_savepoint)
    }

    pub fn with_savepoint<T>(
        &mut self,
        name: &str,
        f: impl FnOnce(&mut Database) -> Result<T>,
    ) -> Result<T> {
        self.savepoint(name)?;
        match f(self) {
            Ok(value) => {
                self.release_savepoint(name)?;
                Ok(value)
            }
            Err(error) => {
                self.rollback_to_savepoint(name)?;
                self.release_savepoint(name)?;
                Err(error)
            }
        }
    }

    pub fn notify(&mut self, channel: &str, payload: &str) -> Result<()> {
        notify_raw(self.raw_ptr(), channel, payload)
    }

    pub fn listen(&mut self, channel: &str) -> Result<Subscription> {
        let raw = listen_raw(self.raw_ptr(), channel)?;
        Ok(Subscription::new(raw, self.inner.clone()))
    }

    pub fn vacuum(&mut self) -> Result<()> {
        self.simple(zova_sys::zova_database_vacuum)
    }

    pub fn set_busy_timeout(&mut self, milliseconds: u32) -> Result<()> {
        let request = zova_sys::zova_database_busy_timeout_request {
            db: self.raw_ptr(),
            milliseconds,
        };
        self.status(unsafe { zova_sys::zova_database_set_busy_timeout(&request) })
    }

    pub fn last_insert_rowid(&mut self) -> Result<i64> {
        let mut rowid = 0;
        let request = zova_sys::zova_database_last_insert_rowid_request {
            db: self.raw_ptr(),
            out_rowid: &mut rowid,
        };
        self.status(unsafe { zova_sys::zova_database_last_insert_rowid(&request) })?;
        Ok(rowid)
    }

    pub fn changes(&mut self) -> Result<i64> {
        let mut changes = 0;
        let request = zova_sys::zova_database_changes_request {
            db: self.raw_ptr(),
            out_changes: &mut changes,
        };
        self.status(unsafe { zova_sys::zova_database_changes(&request) })?;
        Ok(changes)
    }

    pub fn total_changes(&mut self) -> Result<i64> {
        let mut total_changes = 0;
        let request = zova_sys::zova_database_total_changes_request {
            db: self.raw_ptr(),
            out_total_changes: &mut total_changes,
        };
        self.status(unsafe { zova_sys::zova_database_total_changes(&request) })?;
        Ok(total_changes)
    }

    fn open_or_create(path: impl AsRef<Path>, create: bool) -> Result<Self> {
        let path = path_to_cstring(path.as_ref())?;
        let mut db = ptr::null_mut();
        let mut message = empty_message();
        let request = zova_sys::zova_database_open_request {
            path: path.as_ptr(),
            out_db: &mut db,
            out_error_message: &mut message,
        };
        let status = unsafe {
            if create {
                zova_sys::zova_database_create(&request)
            } else {
                zova_sys::zova_database_open(&request)
            }
        };
        if status != zova_sys::ZOVA_OK {
            return Err(Error::from_status(status, take_message(&mut message)));
        }
        let raw = NonNull::new(db)
            .ok_or_else(|| Error::from_status(zova_sys::ZOVA_INVALID_ARGUMENT, None))?;
        Ok(Self {
            inner: Rc::new(DatabaseInner {
                raw,
                _not_send_sync: PhantomData,
            }),
        })
    }

    fn simple(
        &mut self,
        function: unsafe extern "C" fn(
            *const zova_sys::zova_database_simple_request,
        ) -> zova_sys::zova_status,
    ) -> Result<()> {
        let request = zova_sys::zova_database_simple_request { db: self.raw_ptr() };
        self.status(unsafe { function(&request) })
    }

    fn savepoint_call(
        &mut self,
        name: &str,
        function: unsafe extern "C" fn(
            *const zova_sys::zova_database_savepoint_request,
        ) -> zova_sys::zova_status,
    ) -> Result<()> {
        let name = cstring(name, "savepoint name")?;
        let request = zova_sys::zova_database_savepoint_request {
            db: self.raw_ptr(),
            name: name.as_ptr(),
        };
        self.status(unsafe { function(&request) })
    }

    pub(crate) fn status(&mut self, status: i32) -> Result<()> {
        db_status(self.raw_ptr(), status)
    }

    pub(crate) fn raw_ptr(&mut self) -> *mut zova_sys::zova_database {
        self.inner.raw_ptr()
    }
}

impl DatabaseInner {
    pub(crate) fn raw_ptr(&self) -> *mut zova_sys::zova_database {
        self.raw.as_ptr()
    }
}

impl Drop for DatabaseInner {
    fn drop(&mut self) {
        unsafe {
            let _ = zova_sys::zova_database_close(self.raw.as_ptr());
        }
    }
}

impl fmt::Debug for Database {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Database").finish_non_exhaustive()
    }
}

pub(crate) fn db_status(db: *mut zova_sys::zova_database, status: i32) -> Result<()> {
    if status == zova_sys::ZOVA_OK {
        return Ok(());
    }
    let message = unsafe {
        let ptr = zova_sys::zova_database_last_error_message(db);
        if ptr.is_null() {
            None
        } else {
            Some(CStr::from_ptr(ptr).to_string_lossy().into_owned())
        }
    };
    Err(Error::from_status(status, message))
}

pub(crate) fn cstring(value: &str, context: &'static str) -> Result<CString> {
    CString::new(value).map_err(|_| Error::InteriorNul { context })
}

pub(crate) fn path_to_cstring(path: &Path) -> Result<CString> {
    let value = path.to_str().ok_or(Error::NonUtf8Path)?;
    cstring(value, "path")
}

pub fn restore_backup(
    source: impl AsRef<Path>,
    destination: impl AsRef<Path>,
    options: RestoreOptions,
) -> Result<()> {
    let source = path_to_cstring(source.as_ref())?;
    let destination = path_to_cstring(destination.as_ref())?;
    let mut message = empty_message();
    let request = zova_sys::zova_database_restore_request {
        source_path: source.as_ptr(),
        destination_path: destination.as_ptr(),
        flags: restore_flags(options.verify),
        out_error_message: &mut message,
    };
    let status = unsafe { zova_sys::zova_database_restore(&request) };
    if status == zova_sys::ZOVA_OK {
        return Ok(());
    }
    Err(Error::from_status(status, take_message(&mut message)))
}

/// Restore a valid `.zova` backup file into a new volatile in-memory database.
///
/// The returned database owns the source's schema and data entirely in memory
/// and never creates database, WAL, or journal files.
pub fn restore_backup_to_memory(
    source: impl AsRef<Path>,
    options: RestoreOptions,
) -> Result<Database> {
    let source = path_to_cstring(source.as_ref())?;
    let mut db = ptr::null_mut();
    let mut message = empty_message();
    let request = zova_sys::zova_database_restore_to_memory_request {
        source_path: source.as_ptr(),
        flags: restore_flags(options.verify),
        out_db: &mut db,
        out_error_message: &mut message,
    };
    let status = unsafe { zova_sys::zova_database_restore_to_memory(&request) };
    if status != zova_sys::ZOVA_OK {
        return Err(Error::from_status(status, take_message(&mut message)));
    }
    let raw = NonNull::new(db)
        .ok_or_else(|| Error::from_status(zova_sys::ZOVA_INVALID_ARGUMENT, None))?;
    Ok(Database {
        inner: Rc::new(DatabaseInner {
            raw,
            _not_send_sync: PhantomData,
        }),
    })
}

pub(crate) fn backup_flags(verify: bool) -> u32 {
    if verify {
        0
    } else {
        zova_sys::ZOVA_BACKUP_NO_VERIFY
    }
}

pub(crate) fn compact_flags(verify: bool) -> u32 {
    if verify {
        0
    } else {
        zova_sys::ZOVA_COMPACT_NO_VERIFY
    }
}

/// Probe a `.zova` file's storage format without opening or mutating it.
///
/// The probe never requires an open database handle and never writes to the
/// probed file.
pub fn probe_format(path: impl AsRef<Path>) -> Result<FormatInfo> {
    let path = path_to_cstring(path.as_ref())?;
    let mut info = zova_sys::zova_database_format_info {
        format_version: 0,
        compatibility: zova_sys::ZOVA_FORMAT_CURRENT,
    };
    let mut message = empty_message();
    let request = zova_sys::zova_database_probe_format_request {
        path: path.as_ptr(),
        out_info: &mut info,
        out_error_message: &mut message,
    };
    let status = unsafe { zova_sys::zova_database_probe_format(&request) };
    if status != zova_sys::ZOVA_OK {
        return Err(Error::from_status(status, take_message(&mut message)));
    }
    Ok(FormatInfo {
        format_version: info.format_version,
        compatibility: FormatCompatibility::from_raw(info.compatibility),
    })
}

/// Migrate a `.zova` file forward to this release's storage format.
///
/// Migration is explicit, copy-forward, and source-preserving: the source file
/// is never mutated, the destination must not already exist, and any failure
/// removes attempted output. When `options.verify` is true (the default), the
/// migrated destination is verified after the copy.
pub fn migrate_database(
    source: impl AsRef<Path>,
    destination: impl AsRef<Path>,
    options: MigrateOptions,
) -> Result<()> {
    let source = path_to_cstring(source.as_ref())?;
    let destination = path_to_cstring(destination.as_ref())?;
    let mut message = empty_message();
    let request = zova_sys::zova_database_migrate_request {
        source_path: source.as_ptr(),
        destination_path: destination.as_ptr(),
        flags: migrate_flags(options.verify),
        out_error_message: &mut message,
    };
    let status = unsafe { zova_sys::zova_database_migrate(&request) };
    if status == zova_sys::ZOVA_OK {
        return Ok(());
    }
    Err(Error::from_status(status, take_message(&mut message)))
}

/// `migrate_database` with explicitly selected native bundles.
///
/// Migration verifies the destination with every installed extension, so a
/// database with a non-bundled extension installed needs that extension's
/// bundle here. Bundles go through the same trust checks as
/// [`Database::open_with_extensions`]; empty options behave exactly like
/// [`migrate_database`], and any failure publishes nothing.
pub fn migrate_database_with_extensions(
    source: impl AsRef<Path>,
    destination: impl AsRef<Path>,
    options: MigrateOptions,
    extensions: &ExtensionOptions,
) -> Result<()> {
    let source = path_to_cstring(source.as_ref())?;
    let destination = path_to_cstring(destination.as_ref())?;
    let extension_args = ExtensionCArgs::new(extensions)?;
    let mut message = empty_message();
    let request = zova_sys::zova_database_migrate_extensions_request {
        source_path: source.as_ptr(),
        destination_path: destination.as_ptr(),
        flags: migrate_flags(options.verify),
        extension_bundle_paths: extension_args.bundle_paths(),
        extension_bundle_count: extension_args.bundle_count(),
        trust_store_path: extension_args.trust_store_path(),
        plugins: ptr::null(),
        plugin_count: 0,
        out_error_message: &mut message,
    };
    // SAFETY: all inputs and outputs stay live throughout the synchronous call.
    let status = unsafe { zova_sys::zova_database_migrate_with_extensions(&request) };
    if status == zova_sys::ZOVA_OK {
        return Ok(());
    }
    Err(Error::from_status(status, take_message(&mut message)))
}

/// [`migrate_database_with_extensions`] that reports [`Progress`] to
/// `progress`.
///
/// The closure runs on the calling thread. Returning [`ControlFlow::Break`]
/// cancels the migration: it fails with [`crate::Status::Interrupted`], leaves
/// the source set unchanged, and creates no destination files. The last
/// [`crate::ProgressPhase::Publish`] event follows the commit, so its return
/// value is ignored.
pub fn migrate_database_with_progress(
    source: impl AsRef<Path>,
    destination: impl AsRef<Path>,
    options: MigrateOptions,
    extensions: &ExtensionOptions,
    mut progress: impl FnMut(Progress) -> ControlFlow<()>,
) -> Result<()> {
    let source = path_to_cstring(source.as_ref())?;
    let destination = path_to_cstring(destination.as_ref())?;
    let extension_args = ExtensionCArgs::new(extensions)?;
    let mut message = empty_message();
    let mut bridge = ProgressBridge::new(&mut progress);
    let request = zova_sys::zova_database_migrate_progress_request {
        source_path: source.as_ptr(),
        destination_path: destination.as_ptr(),
        flags: migrate_flags(options.verify),
        extension_bundle_paths: extension_args.bundle_paths(),
        extension_bundle_count: extension_args.bundle_count(),
        trust_store_path: extension_args.trust_store_path(),
        plugins: ptr::null(),
        plugin_count: 0,
        progress: bridge.callback(),
        progress_user_data: bridge.user_data(),
        out_error_message: &mut message,
    };
    // SAFETY: all inputs, outputs, and the bridge stay live throughout the
    // synchronous call.
    let status = unsafe { zova_sys::zova_database_migrate_with_progress(&request) };
    let result = if status == zova_sys::ZOVA_OK {
        Ok(())
    } else {
        Err(Error::from_status(status, take_message(&mut message)))
    };
    bridge.finish(result)
}

pub(crate) fn restore_flags(verify: bool) -> u32 {
    if verify {
        0
    } else {
        zova_sys::ZOVA_RESTORE_NO_VERIFY
    }
}

pub(crate) fn migrate_flags(verify: bool) -> u32 {
    if verify {
        0
    } else {
        zova_sys::ZOVA_MIGRATE_NO_VERIFY
    }
}

pub(crate) fn empty_message() -> zova_sys::zova_message {
    zova_sys::zova_message {
        data: ptr::null_mut(),
        len: 0,
    }
}

pub(crate) fn take_message(message: &mut zova_sys::zova_message) -> Option<String> {
    if message.data.is_null() {
        return None;
    }
    let bytes = unsafe { std::slice::from_raw_parts(message.data.cast::<u8>(), message.len) };
    let text = String::from_utf8_lossy(bytes).into_owned();
    unsafe {
        zova_sys::zova_message_free(message);
    }
    Some(text)
}
