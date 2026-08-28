use napi::{Error as NapiError, Status as NapiStatus};

const ERROR_PREFIX: &str = "__ZOVA_ERROR__";

pub(crate) fn zova_error(error: zova::Error) -> NapiError {
    match &error {
        zova::Error::Zova {
            status,
            status_name,
            ..
        } => encoded_error(status.raw(), status_name, error.to_string()),
        zova::Error::InteriorNul { .. }
        | zova::Error::NonUtf8Path
        | zova::Error::InvalidUtf8Text => invalid_argument_error(error.to_string()),
    }
}

pub(crate) fn invalid_argument_error(message: impl Into<String>) -> NapiError {
    encoded_error(
        zova_sys::ZOVA_INVALID_ARGUMENT,
        "ZOVA_INVALID_ARGUMENT",
        message,
    )
}

pub(crate) fn misuse_error(message: impl Into<String>) -> NapiError {
    encoded_error(zova_sys::ZOVA_MISUSE, "ZOVA_MISUSE", message)
}

fn encoded_error(status: i32, status_name: &str, message: impl Into<String>) -> NapiError {
    NapiError::new(
        NapiStatus::GenericFailure,
        format!("{ERROR_PREFIX}:{status}:{status_name}:{}", message.into()),
    )
}

#[cfg(test)]
mod tests {
    use super::{invalid_argument_error, misuse_error, zova_error, ERROR_PREFIX};

    #[test]
    fn encoded_errors_retain_status_name_and_message() {
        let error = invalid_argument_error("bad input");
        assert_eq!(
            error.reason,
            format!("{ERROR_PREFIX}:1:ZOVA_INVALID_ARGUMENT:bad input")
        );

        let error = misuse_error("closed");
        assert!(error.reason.contains(":ZOVA_MISUSE:closed"));
    }

    #[test]
    fn every_zova_status_keeps_its_raw_code_and_name() {
        let statuses = [
            zova::Status::InvalidArgument,
            zova::Status::OutOfMemory,
            zova::Status::Busy,
            zova::Status::Locked,
            zova::Status::Constraint,
            zova::Status::CantOpen,
            zova::Status::ReadOnly,
            zova::Status::Corrupt,
            zova::Status::Misuse,
            zova::Status::SqliteError,
            zova::Status::NotZovaPath,
            zova::Status::NotZovaDatabase,
            zova::Status::UnsupportedZovaVersion,
            zova::Status::DestinationExists,
            zova::Status::ZovaNameConflict,
            zova::Status::ObjectNotFound,
            zova::Status::ObjectAlreadyExists,
            zova::Status::ObjectChunkNotFound,
            zova::Status::ObjectChunkHashMismatch,
            zova::Status::ObjectCorrupt,
            zova::Status::ObjectManifestInvalid,
            zova::Status::ObjectRangeInvalid,
            zova::Status::ObjectTooLarge,
            zova::Status::ObjectTransactionActive,
            zova::Status::ObjectWriterClosed,
            zova::Status::BoundStoreExists,
            zova::Status::BoundStoreNotFound,
            zova::Status::BoundStoreInvalid,
            zova::Status::VectorCollectionExists,
            zova::Status::VectorCollectionNotFound,
            zova::Status::VectorNotFound,
            zova::Status::VectorDimensionMismatch,
            zova::Status::VectorCorrupt,
            zova::Status::VectorInvalid,
            zova::Status::GraphExists,
            zova::Status::GraphNotFound,
            zova::Status::GraphNodeNotFound,
            zova::Status::GraphEdgeNotFound,
            zova::Status::GraphInvalid,
            zova::Status::ExtensionNotFound,
            zova::Status::ExtensionExists,
            zova::Status::ExtensionInvalid,
            zova::Status::ExtensionIncompatible,
            zova::Status::ExtensionUnavailable,
            zova::Status::MigrationRequired,
            zova::Status::UnsupportedFutureFormat,
            zova::Status::UnsupportedLegacyFormat,
            zova::Status::NoMigrationPath,
            zova::Status::Unknown(-91),
        ];

        for status in statuses {
            let status_name = status.name();
            let raw = status.raw();
            let error = zova_error(zova::Error::Zova {
                status,
                status_name: status_name.clone(),
                message: Some("details".to_owned()),
            });
            assert!(error.reason.contains(&format!(":{raw}:{status_name}:")));
            assert!(error.reason.ends_with("details"));
        }

        for error in [
            zova::Error::InteriorNul { context: "test" },
            zova::Error::NonUtf8Path,
            zova::Error::InvalidUtf8Text,
        ] {
            assert!(zova_error(error)
                .reason
                .contains(":1:ZOVA_INVALID_ARGUMENT:"));
        }
    }
}
