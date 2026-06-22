//! Safe Rust bindings for Zova's C ABI.
//!
//! This first Rust slice covers database lifecycle, records through prepared
//! SQL statements, transactions, and explicit vacuum. Objects and vectors are
//! added in later binding slices.

mod database;
mod error;
mod statement;

pub use database::Database;
pub use error::{Error, Result, Status};
pub use statement::{ColumnType, Statement, Step};
