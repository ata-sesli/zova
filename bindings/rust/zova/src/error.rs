use std::ffi::{CStr, NulError};
use std::fmt;

pub type Result<T> = std::result::Result<T, Error>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[non_exhaustive]
pub enum Status {
    InvalidArgument,
    OutOfMemory,
    Busy,
    Locked,
    Constraint,
    CantOpen,
    ReadOnly,
    Corrupt,
    Misuse,
    SqliteError,
    NotZovaPath,
    NotZovaDatabase,
    UnsupportedZovaVersion,
    DestinationExists,
    ZovaNameConflict,
    ObjectNotFound,
    ObjectAlreadyExists,
    ObjectChunkNotFound,
    ObjectChunkHashMismatch,
    ObjectCorrupt,
    ObjectManifestInvalid,
    ObjectRangeInvalid,
    ObjectTooLarge,
    ObjectTransactionActive,
    ObjectWriterClosed,
    VectorCollectionExists,
    VectorCollectionNotFound,
    VectorNotFound,
    VectorDimensionMismatch,
    VectorCorrupt,
    VectorInvalid,
    Unknown(i32),
}

impl Status {
    pub fn from_raw(code: i32) -> Self {
        match code {
            zova_sys::ZOVA_INVALID_ARGUMENT => Self::InvalidArgument,
            zova_sys::ZOVA_OUT_OF_MEMORY => Self::OutOfMemory,
            zova_sys::ZOVA_BUSY => Self::Busy,
            zova_sys::ZOVA_LOCKED => Self::Locked,
            zova_sys::ZOVA_CONSTRAINT => Self::Constraint,
            zova_sys::ZOVA_CANT_OPEN => Self::CantOpen,
            zova_sys::ZOVA_READ_ONLY => Self::ReadOnly,
            zova_sys::ZOVA_CORRUPT => Self::Corrupt,
            zova_sys::ZOVA_MISUSE => Self::Misuse,
            zova_sys::ZOVA_SQLITE_ERROR => Self::SqliteError,
            zova_sys::ZOVA_NOT_ZOVA_PATH => Self::NotZovaPath,
            zova_sys::ZOVA_NOT_ZOVA_DATABASE => Self::NotZovaDatabase,
            zova_sys::ZOVA_UNSUPPORTED_ZOVA_VERSION => Self::UnsupportedZovaVersion,
            zova_sys::ZOVA_DESTINATION_EXISTS => Self::DestinationExists,
            zova_sys::ZOVA_ZOVA_NAME_CONFLICT => Self::ZovaNameConflict,
            zova_sys::ZOVA_OBJECT_NOT_FOUND => Self::ObjectNotFound,
            zova_sys::ZOVA_OBJECT_ALREADY_EXISTS => Self::ObjectAlreadyExists,
            zova_sys::ZOVA_OBJECT_CHUNK_NOT_FOUND => Self::ObjectChunkNotFound,
            zova_sys::ZOVA_OBJECT_CHUNK_HASH_MISMATCH => Self::ObjectChunkHashMismatch,
            zova_sys::ZOVA_OBJECT_CORRUPT => Self::ObjectCorrupt,
            zova_sys::ZOVA_OBJECT_MANIFEST_INVALID => Self::ObjectManifestInvalid,
            zova_sys::ZOVA_OBJECT_RANGE_INVALID => Self::ObjectRangeInvalid,
            zova_sys::ZOVA_OBJECT_TOO_LARGE => Self::ObjectTooLarge,
            zova_sys::ZOVA_OBJECT_TRANSACTION_ACTIVE => Self::ObjectTransactionActive,
            zova_sys::ZOVA_OBJECT_WRITER_CLOSED => Self::ObjectWriterClosed,
            zova_sys::ZOVA_VECTOR_COLLECTION_EXISTS => Self::VectorCollectionExists,
            zova_sys::ZOVA_VECTOR_COLLECTION_NOT_FOUND => Self::VectorCollectionNotFound,
            zova_sys::ZOVA_VECTOR_NOT_FOUND => Self::VectorNotFound,
            zova_sys::ZOVA_VECTOR_DIMENSION_MISMATCH => Self::VectorDimensionMismatch,
            zova_sys::ZOVA_VECTOR_CORRUPT => Self::VectorCorrupt,
            zova_sys::ZOVA_VECTOR_INVALID => Self::VectorInvalid,
            other => Self::Unknown(other),
        }
    }

    pub fn raw(self) -> i32 {
        match self {
            Self::InvalidArgument => zova_sys::ZOVA_INVALID_ARGUMENT,
            Self::OutOfMemory => zova_sys::ZOVA_OUT_OF_MEMORY,
            Self::Busy => zova_sys::ZOVA_BUSY,
            Self::Locked => zova_sys::ZOVA_LOCKED,
            Self::Constraint => zova_sys::ZOVA_CONSTRAINT,
            Self::CantOpen => zova_sys::ZOVA_CANT_OPEN,
            Self::ReadOnly => zova_sys::ZOVA_READ_ONLY,
            Self::Corrupt => zova_sys::ZOVA_CORRUPT,
            Self::Misuse => zova_sys::ZOVA_MISUSE,
            Self::SqliteError => zova_sys::ZOVA_SQLITE_ERROR,
            Self::NotZovaPath => zova_sys::ZOVA_NOT_ZOVA_PATH,
            Self::NotZovaDatabase => zova_sys::ZOVA_NOT_ZOVA_DATABASE,
            Self::UnsupportedZovaVersion => zova_sys::ZOVA_UNSUPPORTED_ZOVA_VERSION,
            Self::DestinationExists => zova_sys::ZOVA_DESTINATION_EXISTS,
            Self::ZovaNameConflict => zova_sys::ZOVA_ZOVA_NAME_CONFLICT,
            Self::ObjectNotFound => zova_sys::ZOVA_OBJECT_NOT_FOUND,
            Self::ObjectAlreadyExists => zova_sys::ZOVA_OBJECT_ALREADY_EXISTS,
            Self::ObjectChunkNotFound => zova_sys::ZOVA_OBJECT_CHUNK_NOT_FOUND,
            Self::ObjectChunkHashMismatch => zova_sys::ZOVA_OBJECT_CHUNK_HASH_MISMATCH,
            Self::ObjectCorrupt => zova_sys::ZOVA_OBJECT_CORRUPT,
            Self::ObjectManifestInvalid => zova_sys::ZOVA_OBJECT_MANIFEST_INVALID,
            Self::ObjectRangeInvalid => zova_sys::ZOVA_OBJECT_RANGE_INVALID,
            Self::ObjectTooLarge => zova_sys::ZOVA_OBJECT_TOO_LARGE,
            Self::ObjectTransactionActive => zova_sys::ZOVA_OBJECT_TRANSACTION_ACTIVE,
            Self::ObjectWriterClosed => zova_sys::ZOVA_OBJECT_WRITER_CLOSED,
            Self::VectorCollectionExists => zova_sys::ZOVA_VECTOR_COLLECTION_EXISTS,
            Self::VectorCollectionNotFound => zova_sys::ZOVA_VECTOR_COLLECTION_NOT_FOUND,
            Self::VectorNotFound => zova_sys::ZOVA_VECTOR_NOT_FOUND,
            Self::VectorDimensionMismatch => zova_sys::ZOVA_VECTOR_DIMENSION_MISMATCH,
            Self::VectorCorrupt => zova_sys::ZOVA_VECTOR_CORRUPT,
            Self::VectorInvalid => zova_sys::ZOVA_VECTOR_INVALID,
            Self::Unknown(code) => code,
        }
    }

    pub fn name(self) -> String {
        unsafe {
            let ptr = zova_sys::zova_status_name(self.raw());
            if ptr.is_null() {
                return format!("ZOVA_UNKNOWN_STATUS_{}", self.raw());
            }
            CStr::from_ptr(ptr).to_string_lossy().into_owned()
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    Zova {
        status: Status,
        status_name: String,
        message: Option<String>,
    },
    InteriorNul {
        context: &'static str,
    },
    NonUtf8Path,
    InvalidUtf8Text,
}

impl Error {
    pub(crate) fn from_status(code: i32, message: Option<String>) -> Self {
        let status = Status::from_raw(code);
        Self::Zova {
            status,
            status_name: status.name(),
            message,
        }
    }

    pub fn status(&self) -> Option<Status> {
        match self {
            Self::Zova { status, .. } => Some(*status),
            _ => None,
        }
    }
}

impl From<NulError> for Error {
    fn from(_: NulError) -> Self {
        Self::InteriorNul { context: "string" }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Zova {
                status_name,
                message,
                ..
            } => match message {
                Some(message) if !message.is_empty() => write!(f, "{status_name}: {message}"),
                _ => write!(f, "{status_name}"),
            },
            Self::InteriorNul { context } => write!(f, "{context} contains an interior NUL byte"),
            Self::NonUtf8Path => write!(f, "path is not valid UTF-8"),
            Self::InvalidUtf8Text => write!(f, "SQL text column is not valid UTF-8"),
        }
    }
}

impl std::error::Error for Error {}
