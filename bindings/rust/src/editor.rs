//! Comment-preserving, in-place editing of a YAML/JSON document.
//!
//! Unlike [`crate::to_string`], which reserializes a whole value, [`Editor`]
//! splices only the bytes of the node you change — comments, key order, blank
//! lines, and quoting style everywhere else are left byte-identical. Values are
//! serialized with the same [`crate::to_string`] machinery, then spliced in;
//! the Zig editor re-frames indentation and flow/block context at the site.

use std::ptr::NonNull;

use serde::Serialize;

use crate::error::Error;
use crate::{ffi, Format};

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

/// Serialize a value to the YAML text used as splice input. The trailing
/// newline `to_string` always appends is removed; the Zig editor owns
/// indentation and newline framing.
pub(crate) fn value_text<T: Serialize + ?Sized>(value: &T) -> Result<String, Error> {
    let mut s = crate::to_string(value)?;
    if s.ends_with('\n') {
        s.pop();
    }
    Ok(s)
}

/// An in-place editor over an owned copy of a document's source.
#[derive(Debug)]
pub struct Editor {
    raw: NonNull<ffi::FigEditor>,
}

impl Editor {
    /// Open an editor over a copy of `input` in the given format.
    pub fn open(input: &[u8], format: Format) -> Result<Self, Error> {
        let mut raw = std::ptr::null_mut();
        let ffi_format: ffi::FigFormat = format.into();
        let status =
            unsafe { ffi::fig_editor_create(input.as_ptr(), input.len(), ffi_format as i32, &mut raw) };
        Error::from_status(status)?;
        let raw = NonNull::new(raw).ok_or(Error::Internal)?;
        Ok(Self { raw })
    }

    fn ptr(&self) -> *mut ffi::FigEditor {
        self.raw.as_ptr()
    }

    /// Replace the value at `path` with the serialized form of `value`.
    pub fn replace<T: Serialize + ?Sized>(&mut self, path: &[Segment], value: &T) -> Result<(), Error> {
        let repl = value_text(value)?;
        let p = to_ffi_path(path);
        let status = unsafe {
            ffi::fig_editor_replace_val(self.ptr(), p.as_ptr(), p.len(), repl.as_ptr(), repl.len())
        };
        Error::from_status(status)
    }

    /// Replace the key at `path` with the serialized form of `key`.
    pub fn replace_key(&mut self, path: &[Segment], key: &str) -> Result<(), Error> {
        let repl = value_text(key)?;
        let p = to_ffi_path(path);
        let status = unsafe {
            ffi::fig_editor_replace_key(self.ptr(), p.as_ptr(), p.len(), repl.as_ptr(), repl.len())
        };
        Error::from_status(status)
    }

    /// Insert `key: value` into the mapping at `path` (empty path = root).
    pub fn insert<T: Serialize + ?Sized>(
        &mut self,
        path: &[Segment],
        key: &str,
        value: &T,
    ) -> Result<(), Error> {
        let key_text = value_text(key)?;
        let val = value_text(value)?;
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

    /// Delete the mapping entry named by `path`.
    pub fn delete(&mut self, path: &[Segment]) -> Result<(), Error> {
        let p = to_ffi_path(path);
        let status = unsafe { ffi::fig_editor_delete_key(self.ptr(), p.as_ptr(), p.len()) };
        Error::from_status(status)
    }

    /// Append `value` to the sequence at `path`.
    pub fn append<T: Serialize + ?Sized>(&mut self, path: &[Segment], value: &T) -> Result<(), Error> {
        let val = value_text(value)?;
        let p = to_ffi_path(path);
        let status =
            unsafe { ffi::fig_editor_append_seq(self.ptr(), p.as_ptr(), p.len(), val.as_ptr(), val.len()) };
        Error::from_status(status)
    }

    /// Prepend `value` to the sequence at `path`.
    pub fn prepend<T: Serialize + ?Sized>(&mut self, path: &[Segment], value: &T) -> Result<(), Error> {
        let val = value_text(value)?;
        let p = to_ffi_path(path);
        let status =
            unsafe { ffi::fig_editor_prepend_seq(self.ptr(), p.as_ptr(), p.len(), val.as_ptr(), val.len()) };
        Error::from_status(status)
    }

    /// Remove the item at `index` from the sequence at `path`.
    pub fn remove_item(&mut self, path: &[Segment], index: usize) -> Result<(), Error> {
        let p = to_ffi_path(path);
        let status =
            unsafe { ffi::fig_editor_remove_seq_item(self.ptr(), p.as_ptr(), p.len(), index) };
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
