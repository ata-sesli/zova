use std::ptr;
use std::thread::{self, ThreadId};

use napi::bindgen_prelude::{BigInt, Either4, Function, FunctionRef, Uint8Array};
use napi::{sys, Env, Result};
use napi_derive::napi;

use crate::database::NativeDatabase;
use crate::error::zova_error;

type SqlArguments = Vec<Option<Either4<BigInt, f64, String, Uint8Array>>>;

/// A JavaScript SQL function's result, already classified by the TypeScript
/// wrapper so no exception or unsupported value reaches native code.
#[napi(object)]
pub struct NativeSqlFunctionResult {
    /// `null`, `integer`, `float`, `text`, `blob`, or `error`.
    pub kind: String,
    pub integer: Option<BigInt>,
    pub float: Option<f64>,
    pub text: Option<String>,
    pub blob: Option<Uint8Array>,
}

#[napi(object)]
pub struct NativeSqlFunctionFlags {
    pub deterministic: Option<bool>,
    pub direct_only: Option<bool>,
    pub innocuous: Option<bool>,
}

/// The registered function, callable only on the JavaScript thread that
/// registered it.
struct JsSqlFunction {
    env: sys::napi_env,
    thread: ThreadId,
    function: FunctionRef<SqlArguments, NativeSqlFunctionResult>,
}

// SAFETY: `env` is only dereferenced after `call` checks that it runs on the
// registering JavaScript thread, and `FunctionRef` is `Send` and releases
// itself on its owning thread wherever it is dropped.
unsafe impl Send for JsSqlFunction {}

impl JsSqlFunction {
    fn call(&self, args: &[zova::SqlValue<'_>]) -> zova::SqlFunctionResult {
        if thread::current().id() != self.thread {
            return zova::SqlFunctionResult::Error(
                "JavaScript SQL functions run only on the JavaScript thread".to_owned(),
            );
        }
        // Each call gets its own handle scope, so a long scan does not keep
        // every row's argument values alive until the statement returns.
        let mut scope = ptr::null_mut();
        // SAFETY: this is the registering JavaScript thread, inside a native
        // call made by JavaScript, so `env` is live.
        if unsafe { sys::napi_open_handle_scope(self.env, &mut scope) } != sys::Status::napi_ok {
            return zova::SqlFunctionResult::Error("cannot open a handle scope".to_owned());
        }
        let result = self.call_in_scope(args);
        // SAFETY: `scope` was opened above on this thread.
        unsafe { sys::napi_close_handle_scope(self.env, scope) };
        result
    }

    fn call_in_scope(&self, args: &[zova::SqlValue<'_>]) -> zova::SqlFunctionResult {
        let args = args
            .iter()
            .map(|value| match value {
                zova::SqlValue::Null => None,
                zova::SqlValue::Integer(value) => Some(Either4::A(BigInt::from(*value))),
                zova::SqlValue::Float(value) => Some(Either4::B(*value)),
                zova::SqlValue::Text(value) => Some(Either4::C((*value).to_owned())),
                zova::SqlValue::Blob(value) => Some(Either4::D(Uint8Array::new(value.to_vec()))),
            })
            .collect::<SqlArguments>();
        let env = Env::from_raw(self.env);
        let result = self
            .function
            .borrow_back(&env)
            .and_then(|function| function.call(args));
        match result {
            Ok(result) => sql_result(result),
            Err(error) => zova::SqlFunctionResult::Error(error.reason),
        }
    }
}

fn sql_result(result: NativeSqlFunctionResult) -> zova::SqlFunctionResult {
    let NativeSqlFunctionResult {
        kind,
        integer,
        float,
        text,
        blob,
    } = result;
    match (kind.as_str(), integer, float, text, blob) {
        ("null", ..) => zova::SqlFunctionResult::Null,
        ("integer", Some(value), ..) => match value.get_i64() {
            (value, true) => zova::SqlFunctionResult::Integer(value),
            _ => zova::SqlFunctionResult::Error(
                "SQL function result is outside the signed 64-bit range".to_owned(),
            ),
        },
        ("float", _, Some(value), ..) => zova::SqlFunctionResult::Float(value),
        ("text", _, _, Some(value), _) => zova::SqlFunctionResult::Text(value),
        ("blob", .., Some(value)) => zova::SqlFunctionResult::Blob(value.to_vec()),
        ("error", _, _, Some(message), _) => zova::SqlFunctionResult::Error(message),
        (kind, ..) => {
            zova::SqlFunctionResult::Error(format!("malformed SQL function result: {kind}"))
        }
    }
}

#[napi]
impl NativeDatabase {
    /// Register a scalar SQL function on this connection. `function` receives
    /// the argument array and returns a classified result.
    #[napi(
        ts_args_type = "name: string, arity: number, flags: NativeSqlFunctionFlags, callback: (args: Array<bigint | number | string | Uint8Array | null>) => NativeSqlFunctionResult"
    )]
    pub fn register_function(
        &self,
        env: Env,
        name: String,
        arity: i32,
        flags: NativeSqlFunctionFlags,
        callback: Function<SqlArguments, NativeSqlFunctionResult>,
    ) -> Result<()> {
        let function = JsSqlFunction {
            env: env.raw(),
            thread: thread::current().id(),
            function: callback.create_ref()?,
        };
        self.state
            .database()?
            .register_function(
                &name,
                arity,
                zova::SqlFunctionFlags {
                    deterministic: flags.deterministic.unwrap_or(false),
                    direct_only: flags.direct_only.unwrap_or(false),
                    innocuous: flags.innocuous.unwrap_or(false),
                },
                move |args| function.call(args),
            )
            .map_err(zova_error)
    }
}
