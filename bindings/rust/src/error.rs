use std::fmt;

use crate::ffi;

/// Errors produced while parsing or deserializing.
///
/// Stands in for `serde_yaml_ng::Error`: it implements [`std::error::Error`]
/// and [`serde::de::Error`], so it can flow through serde and be reported to
/// users the same way.
#[derive(Debug)]
pub enum Error {
    /// A null or otherwise invalid argument reached the C ABI.
    InvalidArgument,
    /// The input could not be parsed as the requested format.
    ///
    /// fig's parse ABI does not yet return a message or source location, so
    /// this variant is intentionally coarse. See the error-handling item in
    /// `fig.md`.
    Parse,
    /// Allocation failed inside the parser.
    OutOfMemory,
    /// The requested format is not supported.
    UnsupportedFormat,
    /// A path, key, or embedded region was not found.
    NotFound,
    /// An unexpected internal error occurred.
    Internal,
    /// A scalar's bytes were not valid UTF-8.
    Utf8,
    /// A numeric scalar could not be parsed (message holds the raw text).
    Number(String),
    /// A serde-level error, e.g. a type mismatch or a missing field.
    Message(String),
}

impl Error {
    pub(crate) fn from_status(status: ffi::FigStatus) -> Result<(), Self> {
        match status {
            ffi::FigStatus::Ok => Ok(()),
            ffi::FigStatus::InvalidArgument => Err(Self::InvalidArgument),
            ffi::FigStatus::ParseError => Err(Self::Parse),
            ffi::FigStatus::OutOfMemory => Err(Self::OutOfMemory),
            ffi::FigStatus::UnsupportedFormat => Err(Self::UnsupportedFormat),
            ffi::FigStatus::NotFound => Err(Self::NotFound),
            ffi::FigStatus::InternalError => Err(Self::Internal),
        }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::InvalidArgument => f.write_str("invalid argument"),
            Error::Parse => f.write_str("failed to parse input"),
            Error::OutOfMemory => f.write_str("out of memory"),
            Error::UnsupportedFormat => f.write_str("unsupported format"),
            Error::NotFound => f.write_str("path or region not found"),
            Error::Internal => f.write_str("internal error"),
            Error::Utf8 => f.write_str("scalar was not valid UTF-8"),
            Error::Number(raw) => write!(f, "invalid number: {raw}"),
            Error::Message(msg) => f.write_str(msg),
        }
    }
}

impl std::error::Error for Error {}

impl serde::de::Error for Error {
    fn custom<T: fmt::Display>(msg: T) -> Self {
        Error::Message(msg.to_string())
    }
}

impl serde::ser::Error for Error {
    fn custom<T: fmt::Display>(msg: T) -> Self {
        Error::Message(msg.to_string())
    }
}
