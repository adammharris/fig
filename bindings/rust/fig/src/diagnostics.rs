//! Serialization diagnostics: what a cross-format conversion would silently lose.
//!
//! [`crate::Document::diagnose`] and [`crate::Value::diagnose`] run the same
//! pipeline the serializers print from and report each lossy event as a
//! [`Warning`], so a host can warn/block/ignore. Mirrors the C ABI's
//! `fig_*_diagnose` + `FigWarning`.

use std::os::raw::c_int;

use crate::ffi;

/// What kind of loss a [`Warning`] describes. Mirrors `FigWarningCode`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WarningCode {
    /// A carried comment is not emitted at all.
    CommentDropped,
    /// A block comment is rendered as a run of line comments.
    CommentStyleDegraded,
    /// A node is removed entirely (the target cannot represent it even degraded).
    ValueDropped,
    /// An extended/non-finite value is rendered as a poorer type.
    TypeDegraded,
    /// A code this binding does not recognize (a future core may add codes).
    Unknown(c_int),
}

impl WarningCode {
    fn from_c(c: c_int) -> Self {
        match c {
            0 => WarningCode::CommentDropped,
            1 => WarningCode::CommentStyleDegraded,
            2 => WarningCode::ValueDropped,
            3 => WarningCode::TypeDegraded,
            other => WarningCode::Unknown(other),
        }
    }
}

/// Why a [`Warning`]'s loss happens. Mirrors `FigWarningCause`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WarningCause {
    /// The target format inherently cannot represent it.
    FormatLimitation,
    /// A caller option forced it (e.g. `strip_comments`).
    ExplicitOption,
    /// A cause this binding does not recognize (forward-compat).
    Unknown(c_int),
}

impl WarningCause {
    fn from_c(c: c_int) -> Self {
        match c {
            0 => WarningCause::FormatLimitation,
            1 => WarningCause::ExplicitOption,
            other => WarningCause::Unknown(other),
        }
    }
}

/// One lossy event a serialization would produce.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Warning {
    pub code: WarningCode,
    pub cause: WarningCause,
    /// Dotted / `[i]` location of the node; empty for the document root.
    pub path: String,
    /// For [`WarningCode::TypeDegraded`], the degraded-to type (e.g. `"string"`);
    /// empty otherwise.
    pub note: String,
}

impl Warning {
    /// Decode one filled `FigWarning`, copying its borrowed `path`/`note` bytes
    /// into owned `String`s before they can be invalidated by the next diagnose.
    ///
    /// # Safety
    /// `w.path`/`w.note` must point to `w.path_len`/`w.note_len` valid bytes (as
    /// the ABI guarantees for a warning just returned by `fig_*_warning`).
    pub(crate) unsafe fn from_ffi(w: &ffi::FigWarning) -> Self {
        Warning {
            code: WarningCode::from_c(w.code),
            cause: WarningCause::from_c(w.cause),
            path: unsafe { borrowed_string(w.path, w.path_len) },
            note: unsafe { borrowed_string(w.note, w.note_len) },
        }
    }
}

/// Copy a borrowed `(ptr, len)` slice into an owned (lossy-UTF-8) `String`.
unsafe fn borrowed_string(ptr: *const u8, len: usize) -> String {
    if ptr.is_null() || len == 0 {
        return String::new();
    }
    let bytes = unsafe { std::slice::from_raw_parts(ptr, len) };
    String::from_utf8_lossy(bytes).into_owned()
}
