//! Comment-preserving, in-place editing of a YAML/JSON document.
//!
//! Unlike [`crate::Value::serialize`], which reserializes a whole value,
//! [`Editor`] splices only the bytes of the node you change — comments, key
//! order, blank lines, and quoting style everywhere else are left byte-
//! identical. Inserted values are rendered by fig's serializer (via [`Value`]),
//! then spliced in; the Zig editor re-frames indentation and flow/block context
//! at the site.
//!
//! The value-taking methods come in two forms: [`Editor::replace_value`] &c.
//! take a [`Value`] directly and are always available; the `serde`-gated
//! [`Editor::replace`] &c. accept any `Serialize` type for convenience.

use std::ptr::NonNull;

use crate::error::Error;
use crate::value::{Value, value_text};
use crate::{Format, ffi};

/// One step of a path into a document: a mapping key or a sequence index.
#[derive(Clone, Copy, Debug)]
pub enum Segment<'a> {
    Key(&'a str),
    Index(usize),
}

impl<'a> From<&'a str> for Segment<'a> {
    fn from(key: &'a str) -> Self {
        Segment::Key(key)
    }
}

impl From<usize> for Segment<'_> {
    fn from(index: usize) -> Self {
        Segment::Index(index)
    }
}

/// Build the C path array. The returned segments borrow the key bytes of
/// `path`, so the result must not outlive `path` (it never does: it is consumed
/// within a single FFI call).
pub(crate) fn to_ffi_path(path: &[Segment]) -> Vec<ffi::FigPathSegment> {
    path.iter()
        .map(|seg| match seg {
            Segment::Key(k) => ffi::FigPathSegment {
                kind: 0,
                key_ptr: k.as_ptr(),
                key_len: k.len(),
                index: 0,
            },
            Segment::Index(i) => ffi::FigPathSegment {
                kind: 1,
                key_ptr: std::ptr::null(),
                key_len: 0,
                index: *i,
            },
        })
        .collect()
}

/// Build the C `FigStr` array for a key list. The returned entries borrow the
/// key bytes of `keys`, so the result must not outlive `keys` (it never does:
/// it is consumed within a single FFI call).
pub(crate) fn to_ffi_keys<S: AsRef<str>>(keys: &[S]) -> Vec<ffi::FigStr> {
    keys.iter()
        .map(|k| {
            let s = k.as_ref();
            ffi::FigStr {
                ptr: s.as_ptr(),
                len: s.len(),
            }
        })
        .collect()
}

/// An in-place editor over an owned copy of a document's source.
#[derive(Debug)]
pub struct Editor {
    raw: NonNull<ffi::FigEditor>,
    /// The document's format, used to render replacement/insertion splice text in
    /// the same dialect (e.g. a `Value::Str` becomes `"x"` for TOML/JSON but a
    /// bare `x` for YAML). Hardcoding one format would splice syntactically wrong
    /// text for the others and fail the editor's reparse.
    format: Format,
}

impl Editor {
    /// Open an editor over a copy of `input` in the given format.
    pub fn open(input: &[u8], format: Format) -> Result<Self, Error> {
        let mut raw = std::ptr::null_mut();
        let ffi_format: ffi::FigFormat = format.into();
        let status = unsafe {
            ffi::fig_editor_create(input.as_ptr(), input.len(), ffi_format as i32, &mut raw)
        };
        Error::from_status(status)?;
        let raw = NonNull::new(raw).ok_or(Error::Internal)?;
        Ok(Self { raw, format })
    }

    fn ptr(&self) -> *mut ffi::FigEditor {
        self.raw.as_ptr()
    }

    // ── value edits (over `Value`) ──────────────────────────────────────────

    /// Replace the value at `path` with `value`.
    pub fn replace_value(&mut self, path: &[Segment], value: &Value) -> Result<(), Error> {
        let repl = value_text(value, self.format)?;
        let p = to_ffi_path(path);
        let status = unsafe {
            ffi::fig_editor_replace_val(self.ptr(), p.as_ptr(), p.len(), repl.as_ptr(), repl.len())
        };
        Error::from_status(status)
    }

    /// Replace the key at `path` with `key`.
    pub fn replace_key(&mut self, path: &[Segment], key: &str) -> Result<(), Error> {
        let repl = value_text(&Value::Str(key.to_string()), self.format)?;
        let p = to_ffi_path(path);
        let status = unsafe {
            ffi::fig_editor_replace_key(self.ptr(), p.as_ptr(), p.len(), repl.as_ptr(), repl.len())
        };
        Error::from_status(status)
    }

    /// Insert `key: value` into the mapping at `path` (empty path = root).
    pub fn insert_value(
        &mut self,
        path: &[Segment],
        key: &str,
        value: &Value,
    ) -> Result<(), Error> {
        let key_text = value_text(&Value::Str(key.to_string()), self.format)?;
        let val = value_text(value, self.format)?;
        let p = to_ffi_path(path);
        let status = unsafe {
            ffi::fig_editor_insert_key(
                self.ptr(),
                p.as_ptr(),
                p.len(),
                key_text.as_ptr(),
                key_text.len(),
                val.as_ptr(),
                val.len(),
            )
        };
        Error::from_status(status)
    }

    /// Append `value` to the sequence at `path`.
    pub fn append_value(&mut self, path: &[Segment], value: &Value) -> Result<(), Error> {
        let val = value_text(value, self.format)?;
        let p = to_ffi_path(path);
        let status = unsafe {
            ffi::fig_editor_append_seq(self.ptr(), p.as_ptr(), p.len(), val.as_ptr(), val.len())
        };
        Error::from_status(status)
    }

    /// Prepend `value` to the sequence at `path`.
    pub fn prepend_value(&mut self, path: &[Segment], value: &Value) -> Result<(), Error> {
        let val = value_text(value, self.format)?;
        let p = to_ffi_path(path);
        let status = unsafe {
            ffi::fig_editor_prepend_seq(self.ptr(), p.as_ptr(), p.len(), val.as_ptr(), val.len())
        };
        Error::from_status(status)
    }

    // ── value edits (serde convenience) ─────────────────────────────────────

    /// Replace the value at `path` with the serialized form of `value`.
    #[cfg(feature = "serde")]
    pub fn replace<T: serde::Serialize + ?Sized>(
        &mut self,
        path: &[Segment],
        value: &T,
    ) -> Result<(), Error> {
        self.replace_value(path, &crate::ser::to_value(value)?)
    }

    /// Insert `key: value` into the mapping at `path` (empty path = root).
    #[cfg(feature = "serde")]
    pub fn insert<T: serde::Serialize + ?Sized>(
        &mut self,
        path: &[Segment],
        key: &str,
        value: &T,
    ) -> Result<(), Error> {
        self.insert_value(path, key, &crate::ser::to_value(value)?)
    }

    /// Append the serialized form of `value` to the sequence at `path`.
    #[cfg(feature = "serde")]
    pub fn append<T: serde::Serialize + ?Sized>(
        &mut self,
        path: &[Segment],
        value: &T,
    ) -> Result<(), Error> {
        self.append_value(path, &crate::ser::to_value(value)?)
    }

    /// Prepend the serialized form of `value` to the sequence at `path`.
    #[cfg(feature = "serde")]
    pub fn prepend<T: serde::Serialize + ?Sized>(
        &mut self,
        path: &[Segment],
        value: &T,
    ) -> Result<(), Error> {
        self.prepend_value(path, &crate::ser::to_value(value)?)
    }

    // ── comment editing ─────────────────────────────────────────────────────

    /// Add an own-line comment ABOVE the node at `path` (the key's line for a
    /// mapping entry), at its indentation, nearest the node. `text` may be
    /// multi-line (one comment line per row). The marker (`#` for YAML, `//` for
    /// JSONC/JSON5) is added for you; strict JSON returns
    /// [`Error::UnsupportedFormat`].
    pub fn add_leading_comment(&mut self, path: &[Segment], text: &str) -> Result<(), Error> {
        let p = to_ffi_path(path);
        let status = unsafe {
            ffi::fig_editor_add_leading_comment(self.ptr(), p.as_ptr(), p.len(), text.as_ptr(), text.len())
        };
        Error::from_status(status)
    }

    /// Set the same-line trailing comment on the value at `path`, replacing an
    /// existing one or appending if absent. `text` must be a single line
    /// ([`Error::InvalidArgument`] otherwise); strict JSON returns
    /// [`Error::UnsupportedFormat`].
    pub fn set_trailing_comment(&mut self, path: &[Segment], text: &str) -> Result<(), Error> {
        let p = to_ffi_path(path);
        let status = unsafe {
            ffi::fig_editor_set_trailing_comment(self.ptr(), p.as_ptr(), p.len(), text.as_ptr(), text.len())
        };
        Error::from_status(status)
    }

    /// Remove the own-line comment block immediately above the node at `path`.
    /// A no-op (still `Ok`) when there is none.
    pub fn delete_leading_comments(&mut self, path: &[Segment]) -> Result<(), Error> {
        let p = to_ffi_path(path);
        let status = unsafe { ffi::fig_editor_delete_leading_comments(self.ptr(), p.as_ptr(), p.len()) };
        Error::from_status(status)
    }

    /// Remove the same-line trailing comment on the value at `path`. A no-op
    /// (still `Ok`) when there is none.
    pub fn delete_trailing_comment(&mut self, path: &[Segment]) -> Result<(), Error> {
        let p = to_ffi_path(path);
        let status = unsafe { ffi::fig_editor_delete_trailing_comment(self.ptr(), p.as_ptr(), p.len()) };
        Error::from_status(status)
    }

    /// Read the own-line comment block immediately above the node at `path`
    /// (lines joined by `\n`, markers and indentation stripped). `None` when
    /// there is no such block; `Some("")` for a present-but-empty bare marker.
    /// Strict JSON returns [`Error::UnsupportedFormat`].
    pub fn leading_comment(&self, path: &[Segment]) -> Result<Option<String>, Error> {
        self.read_comment(path, false)
    }

    /// Read the same-line trailing comment on the value at `path` (marker
    /// stripped). `None` when there is none; `Some("")` for a bare marker.
    /// Strict JSON returns [`Error::UnsupportedFormat`].
    pub fn trailing_comment(&self, path: &[Segment]) -> Result<Option<String>, Error> {
        self.read_comment(path, true)
    }

    /// Shared body for the two comment reads. Returns an owned `String` (copied
    /// out of the handle's reused scratch buffer) so the result stays valid
    /// across later reads, and maps `NOT_FOUND` to `Ok(None)` — distinguishing an
    /// absent comment from a present-but-empty one (`Some(String::new())`).
    fn read_comment(&self, path: &[Segment], trailing: bool) -> Result<Option<String>, Error> {
        let p = to_ffi_path(path);
        let mut ptr: *const u8 = std::ptr::null();
        let mut len: usize = 0;
        let status = unsafe {
            if trailing {
                ffi::fig_editor_get_trailing_comment(self.ptr(), p.as_ptr(), p.len(), &mut ptr, &mut len)
            } else {
                ffi::fig_editor_get_leading_comment(self.ptr(), p.as_ptr(), p.len(), &mut ptr, &mut len)
            }
        };
        if status.0 == ffi::FigStatus::NOT_FOUND {
            return Ok(None);
        }
        Error::from_status(status)?;
        Ok(Some(borrow_str(ptr, len)?.to_string()))
    }

    // ── structural edits (no value) ─────────────────────────────────────────

    /// Delete the mapping entry named by `path`.
    pub fn delete(&mut self, path: &[Segment]) -> Result<(), Error> {
        let p = to_ffi_path(path);
        let status = unsafe { ffi::fig_editor_delete_key(self.ptr(), p.as_ptr(), p.len()) };
        Error::from_status(status)
    }

    /// Remove the item at `index` from the sequence at `path`.
    pub fn remove_item(&mut self, path: &[Segment], index: usize) -> Result<(), Error> {
        let p = to_ffi_path(path);
        let status =
            unsafe { ffi::fig_editor_remove_seq_item(self.ptr(), p.as_ptr(), p.len(), index) };
        Error::from_status(status)
    }

    /// Move the mapping entry at `src_path` to immediately before the entry at
    /// `dest_path`. Both must name keys in the same mapping. The moved entry
    /// keeps its owned comments; bytes between the two entries are preserved.
    pub fn move_key(&mut self, src_path: &[Segment], dest_path: &[Segment]) -> Result<(), Error> {
        let s = to_ffi_path(src_path);
        let d = to_ffi_path(dest_path);
        let status = unsafe {
            ffi::fig_editor_move_key(self.ptr(), s.as_ptr(), s.len(), d.as_ptr(), d.len())
        };
        Error::from_status(status)
    }

    /// Reorder the entries of the mapping at `path` (empty path = root) so
    /// `keys` come first in that order; entries whose key is not listed keep
    /// their original relative order and follow. Unknown keys are ignored. Each
    /// entry's comments and interleaved trivia are preserved.
    pub fn reorder_keys<S: AsRef<str>>(
        &mut self,
        path: &[Segment],
        keys: &[S],
    ) -> Result<(), Error> {
        let p = to_ffi_path(path);
        let k = to_ffi_keys(keys);
        let status = unsafe {
            ffi::fig_editor_reorder_keys(self.ptr(), p.as_ptr(), p.len(), k.as_ptr(), k.len())
        };
        Error::from_status(status)
    }

    /// Move the sequence item at index `from` to index `to` (array-move
    /// semantics). A block item keeps its owned comments; a flow sequence keeps
    /// its separators. No-op when `from == to`.
    pub fn move_item(&mut self, path: &[Segment], from: usize, to: usize) -> Result<(), Error> {
        let p = to_ffi_path(path);
        let status =
            unsafe { ffi::fig_editor_move_item(self.ptr(), p.as_ptr(), p.len(), from, to) };
        Error::from_status(status)
    }

    /// Reorder the items of the sequence at `path` so the items at `indices`
    /// (positions in the current order) come first, in that order; items not
    /// listed keep their original relative order and follow. Out-of-range
    /// indices are ignored.
    pub fn reorder_items(&mut self, path: &[Segment], indices: &[usize]) -> Result<(), Error> {
        let p = to_ffi_path(path);
        let status = unsafe {
            ffi::fig_editor_reorder_items(
                self.ptr(),
                p.as_ptr(),
                p.len(),
                indices.as_ptr(),
                indices.len(),
            )
        };
        Error::from_status(status)
    }

    /// The current source. Borrows editor memory; invalidated by the next edit.
    pub fn source(&self) -> Result<&str, Error> {
        let mut ptr: *const u8 = std::ptr::null();
        let mut len: usize = 0;
        let status = unsafe { ffi::fig_editor_source(self.raw.as_ptr(), &mut ptr, &mut len) };
        Error::from_status(status)?;
        borrow_str(ptr, len)
    }
}

impl Drop for Editor {
    fn drop(&mut self) {
        unsafe { ffi::fig_editor_destroy(self.raw.as_ptr()) };
    }
}

/// Interpret `len` bytes at `ptr` (owned by a fig handle, valid for `'a`) as a
/// UTF-8 string slice.
pub(crate) fn borrow_str<'a>(ptr: *const u8, len: usize) -> Result<&'a str, Error> {
    if len == 0 {
        return Ok("");
    }
    // Safety: on success the ABI guarantees `len` bytes at `ptr` owned by the
    // handle and valid until the next mutation / destroy; the caller bounds the
    // returned borrow accordingly.
    let bytes = unsafe { std::slice::from_raw_parts(ptr, len) };
    std::str::from_utf8(bytes).map_err(|_| Error::Utf8)
}
