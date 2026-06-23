use std::fmt;

use crate::ffi;

/// Errors produced while parsing, serializing, or deserializing.
///
/// Implements [`std::error::Error`], and (with the `serde` feature)
/// [`serde::de::Error`]/[`serde::ser::Error`] so it can flow through serde.
#[derive(Debug)]
// `Number`/`Message` are only constructed on the serde paths.
#[cfg_attr(not(feature = "serde"), allow(dead_code))]
pub enum Error {
    /// A null or otherwise invalid argument reached the C ABI.
    InvalidArgument,
    /// The input could not be parsed as the requested format. Carries a
    /// [`ParseError`] with the core's message and (when known) source location.
    Parse(ParseError),
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
    /// A required field was absent while building a derived `FromValue` type.
    ///
    /// Both parts are compile-time `&'static str`s, so constructing this is
    /// allocation-free and the message text is assembled lazily in `Display`
    /// rather than `format!`-ed at every derived call site.
    MissingField { field: &'static str, ty: &'static str },
    /// A derived `FromValue` impl expected a mapping but found another kind.
    ExpectedMapping { ty: &'static str },
    /// A derived enum `FromValue` impl saw a variant/tag it doesn't recognize.
    /// `got` is the (runtime) text that didn't match any known variant.
    UnknownVariant { enum_name: &'static str, got: String },
    /// A derived tuple-variant `FromValue` impl got the wrong element count.
    WrongSeqLen { label: &'static str, expected: usize, got: usize },
    /// A static, fully compile-time-known message (no runtime interpolation).
    /// Used by derived code in place of `Message(String::from("..."))` so the
    /// `String` allocation is dropped from every call site.
    Static(&'static str),
    /// A primitive conversion expected one kind of value but found another.
    /// `found` is one of the `&'static str` kind names from `kind_of`.
    TypeMismatch { expected: &'static str, found: &'static str },
    /// An integer value was outside the range of the target type. Only the
    /// target type name is kept (a `&'static str`) — deliberately *not* the
    /// offending value, since an `i128` payload would force 16-byte alignment
    /// on the whole `Error` enum and bloat every `Result<_, Error>` site.
    IntOutOfRange { ty: &'static str },
}

/// Details of a parse failure, projected from the C ABI's `FigError`.
#[derive(Debug, Clone)]
pub struct ParseError {
    /// A human-readable message. Currently the core's error name (e.g.
    /// `"UnclosedObject"`); a richer message may follow in a later release.
    pub message: String,
    /// Byte offset of the failure within the input, when known. `None` means
    /// unknown — the core does not yet surface offsets, so this is `None` in the
    /// current release (the field is wired for when it does).
    pub byte_offset: Option<usize>,
    /// 1-based line of the failure, when known (see `byte_offset`).
    pub line: Option<u32>,
    /// 1-based column of the failure, when known (see `byte_offset`).
    pub column: Option<u32>,
}

impl ParseError {
    /// Build from a filled `FigError`. `byte_offset`/`line`/`column` of 0 are the
    /// ABI's "unknown" sentinel and map to `None`. The message is read from
    /// `message[..message_len]` as lossy UTF-8.
    pub(crate) fn from_ffi(e: &ffi::FigError) -> Self {
        let len = e.message_len.min(e.message.len());
        let message = String::from_utf8_lossy(&e.message[..len]).into_owned();
        ParseError {
            message,
            byte_offset: (e.byte_offset != 0).then_some(e.byte_offset),
            line: (e.line != 0).then_some(e.line),
            column: (e.column != 0).then_some(e.column),
        }
    }

    /// A detail-free parse error for paths that have no `FigError` (e.g. the
    /// editor's internal parse, which does not use the `_ex` entry point).
    pub(crate) fn generic() -> Self {
        ParseError {
            message: String::from("failed to parse input"),
            byte_offset: None,
            line: None,
            column: None,
        }
    }
}

impl Error {
    /// `#[cold]`/`#[inline(never)]` constructors keep derived `from_value`
    /// bodies tiny: the error-building code lives here (compiled once) instead
    /// of being inlined — with `format!`/`String` machinery — at every field,
    /// variant, and tag site across the whole dependency graph.
    #[cold]
    #[inline(never)]
    pub fn missing_field(field: &'static str, ty: &'static str) -> Self {
        Error::MissingField { field, ty }
    }

    #[cold]
    #[inline(never)]
    pub fn expected_mapping(ty: &'static str) -> Self {
        Error::ExpectedMapping { ty }
    }

    #[cold]
    #[inline(never)]
    pub fn unknown_variant(enum_name: &'static str, got: &str) -> Self {
        Error::UnknownVariant { enum_name, got: got.to_string() }
    }

    #[cold]
    #[inline(never)]
    pub fn wrong_seq_len(label: &'static str, expected: usize, got: usize) -> Self {
        Error::WrongSeqLen { label, expected, got }
    }

    #[cold]
    #[inline(never)]
    pub fn msg_static(msg: &'static str) -> Self {
        Error::Static(msg)
    }

    #[cold]
    #[inline(never)]
    pub fn type_mismatch(expected: &'static str, found: &'static str) -> Self {
        Error::TypeMismatch { expected, found }
    }

    #[cold]
    #[inline(never)]
    pub fn int_out_of_range(ty: &'static str) -> Self {
        Error::IntOutOfRange { ty }
    }

    pub(crate) fn from_status(status: ffi::FigStatus) -> Result<(), Self> {
        match status.0 {
            ffi::FigStatus::OK => Ok(()),
            ffi::FigStatus::INVALID_ARGUMENT => Err(Self::InvalidArgument),
            ffi::FigStatus::PARSE_ERROR => Err(Self::Parse(ParseError::generic())),
            ffi::FigStatus::OUT_OF_MEMORY => Err(Self::OutOfMemory),
            ffi::FigStatus::UNSUPPORTED_FORMAT => Err(Self::UnsupportedFormat),
            ffi::FigStatus::NOT_FOUND => Err(Self::NotFound),
            // `INTERNAL_ERROR` and any code fig may add in a later release fold
            // into `Internal`: an unrecognized status is never mistaken for `Ok`.
            _ => Err(Self::Internal),
        }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::InvalidArgument => f.write_str("invalid argument"),
            Error::Parse(e) => {
                write!(f, "failed to parse input: {}", e.message)?;
                match (e.line, e.column) {
                    (Some(l), Some(c)) => write!(f, " (line {l}, column {c})"),
                    _ => match e.byte_offset {
                        Some(off) => write!(f, " (byte offset {off})"),
                        None => Ok(()),
                    },
                }
            }
            Error::OutOfMemory => f.write_str("out of memory"),
            Error::UnsupportedFormat => f.write_str("unsupported format"),
            Error::NotFound => f.write_str("path or region not found"),
            Error::Internal => f.write_str("internal error"),
            Error::Utf8 => f.write_str("scalar was not valid UTF-8"),
            Error::Number(raw) => write!(f, "invalid number: {raw}"),
            Error::Message(msg) => f.write_str(msg),
            Error::MissingField { field, ty } => {
                write!(f, "missing field `{field}` while building `{ty}`")
            }
            Error::ExpectedMapping { ty } => write!(f, "expected a mapping to build `{ty}`"),
            Error::UnknownVariant { enum_name, got } => {
                write!(f, "unknown variant `{got}` for enum `{enum_name}`")
            }
            Error::WrongSeqLen { label, expected, got } => {
                write!(f, "expected {expected} element(s) for `{label}`, found {got}")
            }
            Error::Static(msg) => f.write_str(msg),
            Error::TypeMismatch { expected, found } => {
                write!(f, "expected {expected}, found {found}")
            }
            Error::IntOutOfRange { ty } => {
                write!(f, "integer out of range for {ty}")
            }
        }
    }
}

impl std::error::Error for Error {}

#[cfg(feature = "serde")]
impl serde::de::Error for Error {
    fn custom<T: fmt::Display>(msg: T) -> Self {
        Error::Message(msg.to_string())
    }
}

#[cfg(feature = "serde")]
impl serde::ser::Error for Error {
    fn custom<T: fmt::Display>(msg: T) -> Self {
        Error::Message(msg.to_string())
    }
}
