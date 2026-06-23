use crate::database::{cstring, db_status, DatabaseInner};
use crate::error::{Error, Result};
use std::marker::PhantomData;
use std::ptr::{self, NonNull};
use std::rc::Rc;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Step {
    Row,
    Done,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColumnType {
    Integer,
    Float,
    Text,
    Blob,
    Null,
}

pub struct Statement<'db> {
    inner: RawStatement,
    _database: PhantomData<&'db mut crate::Database>,
    _not_send_sync: PhantomData<Rc<()>>,
}

pub struct OwnedStatement {
    inner: RawStatement,
    _database: Rc<DatabaseInner>,
    _not_send_sync: PhantomData<Rc<()>>,
}

struct RawStatement {
    raw: NonNull<zova_sys::zova_statement>,
    db: *mut zova_sys::zova_database,
}

impl<'db> Statement<'db> {
    pub(crate) fn new(
        raw: NonNull<zova_sys::zova_statement>,
        db: *mut zova_sys::zova_database,
    ) -> Self {
        Self {
            inner: RawStatement { raw, db },
            _database: PhantomData,
            _not_send_sync: PhantomData,
        }
    }
}

impl OwnedStatement {
    pub(crate) fn new(raw: NonNull<zova_sys::zova_statement>, database: Rc<DatabaseInner>) -> Self {
        let db = database.raw_ptr();
        Self {
            inner: RawStatement { raw, db },
            _database: database,
            _not_send_sync: PhantomData,
        }
    }
}

macro_rules! impl_statement_api {
    ($statement:ty) => {
        pub fn parameter_count(&mut self) -> Result<usize> {
            self.inner.parameter_count()
        }

        pub fn parameter_index(&mut self, name: &str) -> Result<Option<usize>> {
            self.inner.parameter_index(name)
        }

        pub fn bind_null(&mut self, index: usize) -> Result<()> {
            self.inner.bind_null(index)
        }

        pub fn bind_i64(&mut self, index: usize, value: i64) -> Result<()> {
            self.inner.bind_i64(index, value)
        }

        pub fn bind_f64(&mut self, index: usize, value: f64) -> Result<()> {
            self.inner.bind_f64(index, value)
        }

        pub fn bind_text(&mut self, index: usize, value: &str) -> Result<()> {
            self.inner.bind_text(index, value)
        }

        pub fn bind_blob(&mut self, index: usize, value: &[u8]) -> Result<()> {
            self.inner.bind_blob(index, value)
        }

        pub fn step(&mut self) -> Result<Step> {
            self.inner.step()
        }

        pub fn reset(&mut self) -> Result<()> {
            self.inner.reset()
        }

        pub fn clear_bindings(&mut self) -> Result<()> {
            self.inner.clear_bindings()
        }

        pub fn column_count(&mut self) -> Result<usize> {
            self.inner.column_count()
        }

        pub fn column_name(&mut self, index: usize) -> Result<String> {
            self.inner.column_name(index)
        }

        pub fn column_type(&mut self, index: usize) -> Result<ColumnType> {
            self.inner.column_type(index)
        }

        pub fn column_i64(&mut self, index: usize) -> Result<i64> {
            self.inner.column_i64(index)
        }

        pub fn column_f64(&mut self, index: usize) -> Result<f64> {
            self.inner.column_f64(index)
        }

        pub fn column_text(&mut self, index: usize) -> Result<Option<String>> {
            self.inner.column_text(index)
        }

        pub fn column_blob(&mut self, index: usize) -> Result<Option<Vec<u8>>> {
            self.inner.column_blob(index)
        }
    };
}

impl Statement<'_> {
    impl_statement_api!(Statement<'_>);
}

impl OwnedStatement {
    impl_statement_api!(OwnedStatement);
}

impl RawStatement {
    fn parameter_count(&mut self) -> Result<usize> {
        let mut count = 0;
        let request = zova_sys::zova_statement_parameter_count_request {
            statement: self.raw.as_ptr(),
            out_count: &mut count,
        };
        self.status(unsafe { zova_sys::zova_statement_parameter_count(&request) })?;
        Ok(count as usize)
    }

    fn parameter_index(&mut self, name: &str) -> Result<Option<usize>> {
        let name = cstring(name, "parameter name")?;
        let mut index = 0;
        let request = zova_sys::zova_statement_parameter_index_request {
            statement: self.raw.as_ptr(),
            name: name.as_ptr(),
            out_index: &mut index,
        };
        self.status(unsafe { zova_sys::zova_statement_parameter_index(&request) })?;
        if index == 0 {
            Ok(None)
        } else {
            Ok(Some(index as usize))
        }
    }

    fn bind_null(&mut self, index: usize) -> Result<()> {
        let request = zova_sys::zova_statement_bind_null_request {
            statement: self.raw.as_ptr(),
            index: checked_parameter_index(index)?,
        };
        self.status(unsafe { zova_sys::zova_statement_bind_null(&request) })
    }

    fn bind_i64(&mut self, index: usize, value: i64) -> Result<()> {
        let request = zova_sys::zova_statement_bind_int64_request {
            statement: self.raw.as_ptr(),
            index: checked_parameter_index(index)?,
            value,
        };
        self.status(unsafe { zova_sys::zova_statement_bind_int64(&request) })
    }

    fn bind_f64(&mut self, index: usize, value: f64) -> Result<()> {
        let request = zova_sys::zova_statement_bind_double_request {
            statement: self.raw.as_ptr(),
            index: checked_parameter_index(index)?,
            value,
        };
        self.status(unsafe { zova_sys::zova_statement_bind_double(&request) })
    }

    fn bind_text(&mut self, index: usize, value: &str) -> Result<()> {
        let request = zova_sys::zova_statement_bind_text_request {
            statement: self.raw.as_ptr(),
            index: checked_parameter_index(index)?,
            data: value.as_bytes().as_ptr(),
            len: value.len(),
        };
        self.status(unsafe { zova_sys::zova_statement_bind_text(&request) })
    }

    fn bind_blob(&mut self, index: usize, value: &[u8]) -> Result<()> {
        let request = zova_sys::zova_statement_bind_blob_request {
            statement: self.raw.as_ptr(),
            index: checked_parameter_index(index)?,
            data: value.as_ptr(),
            len: value.len(),
        };
        self.status(unsafe { zova_sys::zova_statement_bind_blob(&request) })
    }

    fn step(&mut self) -> Result<Step> {
        let mut result = 0;
        let request = zova_sys::zova_statement_step_request {
            statement: self.raw.as_ptr(),
            out_result: &mut result,
        };
        self.status(unsafe { zova_sys::zova_statement_step(&request) })?;
        match result {
            zova_sys::ZOVA_STEP_ROW => Ok(Step::Row),
            zova_sys::ZOVA_STEP_DONE => Ok(Step::Done),
            _ => Err(Error::from_status(zova_sys::ZOVA_MISUSE, None)),
        }
    }

    fn reset(&mut self) -> Result<()> {
        self.status(unsafe { zova_sys::zova_statement_reset(self.raw.as_ptr()) })
    }

    fn clear_bindings(&mut self) -> Result<()> {
        self.status(unsafe { zova_sys::zova_statement_clear_bindings(self.raw.as_ptr()) })
    }

    fn column_count(&mut self) -> Result<usize> {
        let mut count = 0;
        let request = zova_sys::zova_statement_column_count_request {
            statement: self.raw.as_ptr(),
            out_count: &mut count,
        };
        self.status(unsafe { zova_sys::zova_statement_column_count(&request) })?;
        Ok(count as usize)
    }

    fn column_name(&mut self, index: usize) -> Result<String> {
        let mut text = zova_sys::zova_text {
            data: ptr::null_mut(),
            len: 0,
        };
        let request = zova_sys::zova_statement_column_name_request {
            statement: self.raw.as_ptr(),
            index: checked_index(index)?,
            out_name: &mut text,
        };
        self.status(unsafe { zova_sys::zova_statement_column_name(&request) })?;
        let bytes = unsafe { std::slice::from_raw_parts(text.data.cast::<u8>(), text.len) };
        let value = String::from_utf8(bytes.to_vec()).map_err(|_| Error::InvalidUtf8Text);
        unsafe {
            zova_sys::zova_text_free(&mut text);
        }
        value
    }

    fn column_type(&mut self, index: usize) -> Result<ColumnType> {
        let mut value = 0;
        let request = zova_sys::zova_statement_column_type_request {
            statement: self.raw.as_ptr(),
            index: checked_index(index)?,
            out_type: &mut value,
        };
        self.status(unsafe { zova_sys::zova_statement_column_type(&request) })?;
        match value {
            zova_sys::ZOVA_COLUMN_INTEGER => Ok(ColumnType::Integer),
            zova_sys::ZOVA_COLUMN_FLOAT => Ok(ColumnType::Float),
            zova_sys::ZOVA_COLUMN_TEXT => Ok(ColumnType::Text),
            zova_sys::ZOVA_COLUMN_BLOB => Ok(ColumnType::Blob),
            zova_sys::ZOVA_COLUMN_NULL => Ok(ColumnType::Null),
            _ => Err(Error::from_status(zova_sys::ZOVA_MISUSE, None)),
        }
    }

    fn column_i64(&mut self, index: usize) -> Result<i64> {
        let mut value = 0;
        let request = zova_sys::zova_statement_column_int64_request {
            statement: self.raw.as_ptr(),
            index: checked_index(index)?,
            out_value: &mut value,
        };
        self.status(unsafe { zova_sys::zova_statement_column_int64(&request) })?;
        Ok(value)
    }

    fn column_f64(&mut self, index: usize) -> Result<f64> {
        let mut value = 0.0;
        let request = zova_sys::zova_statement_column_double_request {
            statement: self.raw.as_ptr(),
            index: checked_index(index)?,
            out_value: &mut value,
        };
        self.status(unsafe { zova_sys::zova_statement_column_double(&request) })?;
        Ok(value)
    }

    fn column_text(&mut self, index: usize) -> Result<Option<String>> {
        let mut text = zova_sys::zova_text {
            data: ptr::null_mut(),
            len: 0,
        };
        let request = zova_sys::zova_statement_column_text_request {
            statement: self.raw.as_ptr(),
            index: checked_index(index)?,
            out_text: &mut text,
        };
        self.status(unsafe { zova_sys::zova_statement_column_text(&request) })?;
        if text.data.is_null() {
            return Ok(None);
        }
        let bytes = unsafe { std::slice::from_raw_parts(text.data.cast::<u8>(), text.len) };
        let value = String::from_utf8(bytes.to_vec()).map_err(|_| Error::InvalidUtf8Text);
        unsafe {
            zova_sys::zova_text_free(&mut text);
        }
        value.map(Some)
    }

    fn column_blob(&mut self, index: usize) -> Result<Option<Vec<u8>>> {
        let mut buffer = zova_sys::zova_buffer {
            data: ptr::null_mut(),
            len: 0,
        };
        let request = zova_sys::zova_statement_column_blob_request {
            statement: self.raw.as_ptr(),
            index: checked_index(index)?,
            out_buffer: &mut buffer,
        };
        self.status(unsafe { zova_sys::zova_statement_column_blob(&request) })?;
        if buffer.data.is_null() {
            return match self.column_type(index)? {
                ColumnType::Null => Ok(None),
                ColumnType::Blob => Ok(Some(Vec::new())),
                _ => Ok(None),
            };
        }
        let bytes = unsafe { std::slice::from_raw_parts(buffer.data, buffer.len) };
        let value = bytes.to_vec();
        unsafe {
            zova_sys::zova_buffer_free(&mut buffer);
        }
        Ok(Some(value))
    }

    fn status(&mut self, status: i32) -> Result<()> {
        db_status(self.db, status)
    }
}

impl Drop for RawStatement {
    fn drop(&mut self) {
        unsafe {
            let _ = zova_sys::zova_statement_finalize(self.raw.as_ptr());
        }
    }
}

fn checked_index(index: usize) -> Result<i32> {
    i32::try_from(index).map_err(|_| Error::from_status(zova_sys::ZOVA_INVALID_ARGUMENT, None))
}

fn checked_parameter_index(index: usize) -> Result<i32> {
    if index == 0 {
        return Err(Error::from_status(zova_sys::ZOVA_INVALID_ARGUMENT, None));
    }
    checked_index(index)
}
