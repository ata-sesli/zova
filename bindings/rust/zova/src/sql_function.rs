//! Application-defined scalar SQL functions.
//!
//! Functions run inside the database handle's serialization boundary on the
//! thread that is stepping the statement. They must not use the same database
//! handle: Zova does not support re-entering a handle from its own callback.

use crate::database::cstring;
use crate::error::Result;
use crate::Database;
use std::cell::RefCell;
use std::os::raw::{c_int, c_void};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

/// One borrowed SQL argument.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum SqlValue<'a> {
    Null,
    Integer(i64),
    Float(f64),
    Text(&'a str),
    Blob(&'a [u8]),
}

/// The value an application SQL function returns.
#[derive(Debug, Clone, PartialEq)]
pub enum SqlFunctionResult {
    Null,
    Integer(i64),
    Float(f64),
    Text(String),
    Blob(Vec<u8>),
    /// Fail the SQL statement with this message.
    Error(String),
}

/// SQLite function properties. All default to false.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct SqlFunctionFlags {
    /// The same arguments always produce the same result.
    pub deterministic: bool,
    /// The function may only be called from top-level SQL, not from views,
    /// triggers, or schema expressions.
    pub direct_only: bool,
    /// The function has no side effects and is safe in any context.
    pub innocuous: bool,
}

impl SqlFunctionFlags {
    fn to_c(self) -> u32 {
        let mut flags = 0;
        if self.deterministic {
            flags |= zova_sys::ZOVA_SQL_FUNCTION_DETERMINISTIC;
        }
        if self.direct_only {
            flags |= zova_sys::ZOVA_SQL_FUNCTION_DIRECT_ONLY;
        }
        if self.innocuous {
            flags |= zova_sys::ZOVA_SQL_FUNCTION_INNOCUOUS;
        }
        flags
    }
}

impl Database {
    /// Register a scalar SQL function on this connection.
    ///
    /// `name` is an ASCII identifier of 1-64 bytes without a `zova_` or
    /// `_zova_` prefix. `arity` is -1 for any argument count or 0-127. A
    /// name and arity pair can be registered once per connection. Text
    /// arguments that are not valid UTF-8 and panics in `function` become SQL
    /// errors.
    pub fn register_function<F>(
        &mut self,
        name: &str,
        arity: i32,
        flags: SqlFunctionFlags,
        function: F,
    ) -> Result<()>
    where
        F: Fn(&[SqlValue<'_>]) -> SqlFunctionResult + 'static,
    {
        let db = self.raw_ptr();
        register_function_raw(
            db,
            |status| self.status(status),
            name,
            arity,
            flags,
            function,
        )
    }
}

/// Register `function` on `db`. The caller chooses the `Send` bound: a
/// `SharedDatabase` may run and drop the function on any of its threads.
pub(crate) fn register_function_raw<F>(
    db: *mut zova_sys::zova_database,
    status: impl FnOnce(i32) -> Result<()>,
    name: &str,
    arity: i32,
    flags: SqlFunctionFlags,
    function: F,
) -> Result<()>
where
    F: Fn(&[SqlValue<'_>]) -> SqlFunctionResult + 'static,
{
    let name = cstring(name, "SQL function name")?;
    let destroyed = Arc::new(AtomicBool::new(false));
    let state = Box::into_raw(Box::new(FunctionState {
        function,
        result: RefCell::new(SqlFunctionResult::Null),
        destroyed: Arc::clone(&destroyed),
    }));
    let request = zova_sys::zova_sql_function_register_request {
        db,
        name: name.as_ptr(),
        arity: arity as c_int,
        flags: flags.to_c(),
        user_data: state.cast::<c_void>(),
        callback: Some(call_function::<F>),
        destroy: Some(destroy_function::<F>),
    };
    let code = unsafe { zova_sys::zova_database_register_function(&request) };
    if code != zova_sys::ZOVA_OK && !destroyed.load(Ordering::Acquire) {
        // Validation failures return before native code takes ownership.
        drop(unsafe { Box::from_raw(state) });
    }
    status(code)
}

struct FunctionState<F> {
    function: F,
    /// Holds the last result until Zova copies its bytes after the callback.
    result: RefCell<SqlFunctionResult>,
    destroyed: Arc<AtomicBool>,
}

unsafe extern "C" fn call_function<F>(
    user_data: *mut c_void,
    call: *const zova_sys::zova_sql_function_call,
    out_result: *mut zova_sys::zova_sql_result,
) where
    F: Fn(&[SqlValue<'_>]) -> SqlFunctionResult + 'static,
{
    if user_data.is_null() || call.is_null() || out_result.is_null() {
        return;
    }
    let state = &*(user_data as *const FunctionState<F>);
    let call = &*call;
    let raw_args = if call.argv.is_null() || call.argc == 0 {
        &[][..]
    } else {
        std::slice::from_raw_parts(call.argv, call.argc)
    };
    let result = match sql_values(raw_args) {
        Ok(args) => catch_unwind(AssertUnwindSafe(|| (state.function)(&args)))
            .unwrap_or_else(|_| SqlFunctionResult::Error("Rust SQL function panicked".to_owned())),
        Err(message) => SqlFunctionResult::Error(message),
    };
    // A nested call through another connection finished before this point,
    // so no other borrow of the result slot is live.
    let mut slot = state.result.borrow_mut();
    *slot = result;
    *out_result = sql_result(&slot);
}

unsafe extern "C" fn destroy_function<F>(user_data: *mut c_void) {
    if user_data.is_null() {
        return;
    }
    let state = Box::from_raw(user_data as *mut FunctionState<F>);
    state.destroyed.store(true, Ordering::Release);
    drop(state);
}

fn sql_values(raw: &[zova_sys::zova_sql_value]) -> std::result::Result<Vec<SqlValue<'_>>, String> {
    raw.iter()
        .enumerate()
        .map(|(index, value)| {
            let bytes = || {
                if value.data.is_null() || value.data_len == 0 {
                    &[][..]
                } else {
                    unsafe { std::slice::from_raw_parts(value.data.cast::<u8>(), value.data_len) }
                }
            };
            Ok(match value.value_type {
                zova_sys::ZOVA_SQL_VALUE_INTEGER => SqlValue::Integer(value.int64_value),
                zova_sys::ZOVA_SQL_VALUE_FLOAT => SqlValue::Float(value.double_value),
                zova_sys::ZOVA_SQL_VALUE_TEXT => SqlValue::Text(
                    std::str::from_utf8(bytes())
                        .map_err(|_| format!("SQL function argument {index} is not valid UTF-8"))?,
                ),
                zova_sys::ZOVA_SQL_VALUE_BLOB => SqlValue::Blob(bytes()),
                _ => SqlValue::Null,
            })
        })
        .collect()
}

fn sql_result(result: &SqlFunctionResult) -> zova_sys::zova_sql_result {
    let mut raw = zova_sys::zova_sql_result {
        result_type: zova_sys::ZOVA_SQL_RESULT_NULL,
        int64_value: 0,
        double_value: 0.0,
        data: ptr::null(),
        data_len: 0,
        error_message: ptr::null(),
        error_message_len: 0,
    };
    match result {
        SqlFunctionResult::Null => {}
        SqlFunctionResult::Integer(value) => {
            raw.result_type = zova_sys::ZOVA_SQL_RESULT_INTEGER;
            raw.int64_value = *value;
        }
        SqlFunctionResult::Float(value) => {
            raw.result_type = zova_sys::ZOVA_SQL_RESULT_FLOAT;
            raw.double_value = *value;
        }
        SqlFunctionResult::Text(value) => {
            raw.result_type = zova_sys::ZOVA_SQL_RESULT_TEXT;
            raw.data = value.as_ptr().cast();
            raw.data_len = value.len();
        }
        SqlFunctionResult::Blob(value) => {
            raw.result_type = zova_sys::ZOVA_SQL_RESULT_BLOB;
            raw.data = value.as_ptr().cast();
            raw.data_len = value.len();
        }
        SqlFunctionResult::Error(message) => {
            raw.result_type = zova_sys::ZOVA_SQL_RESULT_ERROR;
            raw.error_message = message.as_ptr().cast();
            raw.error_message_len = message.len();
        }
    }
    raw
}
