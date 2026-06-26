use crate::error::{Error, Result};
use crate::statement::{OwnedStatement, Statement};
use std::ffi::{CStr, CString};
use std::fmt;
use std::marker::PhantomData;
use std::path::Path;
use std::ptr::{self, NonNull};
use std::rc::Rc;

pub struct Database {
    pub(crate) inner: Rc<DatabaseInner>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct OpenOptions {
    pub read_only: bool,
    pub busy_timeout_ms: u32,
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

pub(crate) struct DatabaseInner {
    raw: NonNull<zova_sys::zova_database>,
    _not_send_sync: PhantomData<Rc<()>>,
}

impl Database {
    pub fn create(path: impl AsRef<Path>) -> Result<Self> {
        Self::open_or_create(path, true)
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

pub(crate) fn restore_flags(verify: bool) -> u32 {
    if verify {
        0
    } else {
        zova_sys::ZOVA_RESTORE_NO_VERIFY
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
