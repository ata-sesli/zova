use std::sync::Arc;

use napi::bindgen_prelude::{BigInt, Uint8Array};
use napi::Result;
use napi_derive::napi;

use crate::database::DatabaseState;
use crate::error::{invalid_argument_error, misuse_error, zova_error};

#[napi(js_name = "NativeStatement")]
pub struct NativeStatement {
    statement: Option<zova::SharedStatement>,
    database: Arc<DatabaseState>,
}

impl NativeStatement {
    pub(crate) fn new(statement: zova::SharedStatement, database: Arc<DatabaseState>) -> Self {
        Self {
            statement: Some(statement),
            database,
        }
    }

    fn statement(&mut self) -> Result<&mut zova::SharedStatement> {
        self.statement
            .as_mut()
            .ok_or_else(|| misuse_error("statement is closed"))
    }

    fn close_inner(&mut self) {
        if self.statement.take().is_some() {
            self.database.child_closed();
        }
    }
}

#[napi]
impl NativeStatement {
    #[napi]
    pub fn close(&mut self) {
        self.close_inner();
    }

    #[napi(getter)]
    pub fn closed(&self) -> bool {
        self.statement.is_none()
    }

    #[napi]
    pub fn parameter_count(&mut self) -> Result<u32> {
        let count = self.statement()?.parameter_count().map_err(zova_error)?;
        u32::try_from(count).map_err(|_| invalid_argument_error("parameter count exceeds u32"))
    }

    #[napi]
    pub fn parameter_index(&mut self, name: String) -> Result<Option<u32>> {
        self.statement()?
            .parameter_index(&name)
            .map_err(zova_error)?
            .map(|index| {
                u32::try_from(index)
                    .map_err(|_| invalid_argument_error("parameter index exceeds u32"))
            })
            .transpose()
    }

    #[napi]
    pub fn bind_null(&mut self, index: u32) -> Result<()> {
        self.statement()?
            .bind_null(index as usize)
            .map_err(zova_error)
    }

    #[napi]
    pub fn bind_integer(&mut self, index: u32, value: BigInt) -> Result<()> {
        let (value, lossless) = value.get_i64();
        if !lossless {
            return Err(invalid_argument_error(
                "integer must fit in a signed 64-bit value",
            ));
        }
        self.statement()?
            .bind_i64(index as usize, value)
            .map_err(zova_error)
    }

    #[napi]
    pub fn bind_float(&mut self, index: u32, value: f64) -> Result<()> {
        self.statement()?
            .bind_f64(index as usize, value)
            .map_err(zova_error)
    }

    #[napi]
    pub fn bind_text(&mut self, index: u32, value: String) -> Result<()> {
        self.statement()?
            .bind_text(index as usize, &value)
            .map_err(zova_error)
    }

    #[napi]
    pub fn bind_blob(&mut self, index: u32, value: Uint8Array) -> Result<()> {
        self.statement()?
            .bind_blob(index as usize, value.as_ref())
            .map_err(zova_error)
    }

    #[napi]
    pub fn step(&mut self) -> Result<&'static str> {
        match self.statement()?.step().map_err(zova_error)? {
            zova::Step::Row => Ok("row"),
            zova::Step::Done => Ok("done"),
        }
    }

    #[napi]
    pub fn reset(&mut self) -> Result<()> {
        self.statement()?.reset().map_err(zova_error)
    }

    #[napi]
    pub fn clear_bindings(&mut self) -> Result<()> {
        self.statement()?.clear_bindings().map_err(zova_error)
    }

    #[napi]
    pub fn column_count(&mut self) -> Result<u32> {
        let count = self.statement()?.column_count().map_err(zova_error)?;
        u32::try_from(count).map_err(|_| invalid_argument_error("column count exceeds u32"))
    }

    #[napi]
    pub fn column_name(&mut self, index: u32) -> Result<String> {
        self.statement()?
            .column_name(index as usize)
            .map_err(zova_error)
    }

    #[napi]
    pub fn column_type(&mut self, index: u32) -> Result<&'static str> {
        match self
            .statement()?
            .column_type(index as usize)
            .map_err(zova_error)?
        {
            zova::ColumnType::Integer => Ok("integer"),
            zova::ColumnType::Float => Ok("float"),
            zova::ColumnType::Text => Ok("text"),
            zova::ColumnType::Blob => Ok("blob"),
            zova::ColumnType::Null => Ok("null"),
        }
    }

    #[napi]
    pub fn column_integer(&mut self, index: u32) -> Result<BigInt> {
        self.statement()?
            .column_i64(index as usize)
            .map(BigInt::from)
            .map_err(zova_error)
    }

    #[napi]
    pub fn column_float(&mut self, index: u32) -> Result<f64> {
        self.statement()?
            .column_f64(index as usize)
            .map_err(zova_error)
    }

    #[napi]
    pub fn column_text(&mut self, index: u32) -> Result<Option<String>> {
        self.statement()?
            .column_text(index as usize)
            .map_err(zova_error)
    }

    #[napi]
    pub fn column_blob(&mut self, index: u32) -> Result<Option<Uint8Array>> {
        self.statement()?
            .column_blob(index as usize)
            .map(|value| value.map(Uint8Array::new))
            .map_err(zova_error)
    }
}

impl Drop for NativeStatement {
    fn drop(&mut self) {
        self.close_inner();
    }
}
