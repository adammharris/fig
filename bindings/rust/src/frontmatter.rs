//! Comment-preserving editing of YAML frontmatter inside a markdown file.
//!
//! [`Frontmatter`] opens a markdown document, locates its `---…---` YAML
//! frontmatter, and edits only that block — the fences and the markdown body
//! are left byte-identical, and within the frontmatter only the changed node's
//! bytes move (comments, key order, and formatting are preserved).
//!
//! Value-taking methods mirror [`crate::Editor`]: `*_value` take a [`Value`]
//! and are always available; the `serde`-gated forms accept any `Serialize`.

use std::ptr::NonNull;

use crate::editor::{borrow_str, to_ffi_keys, to_ffi_path, Segment};
use crate::error::Error;
use crate::ffi;
use crate::value::{value_text, Value};

/// An editor over the YAML frontmatter of a markdown document.
#[derive(Debug)]
pub struct Frontmatter {
    raw: NonNull<ffi::FigFrontmatter>,
}

impl Frontmatter {
    /// Open the frontmatter of `markdown`. Returns [`Error::NotFound`] if there
    /// is no `---…---` frontmatter block.
    pub fn open(markdown: &[u8]) -> Result<Self, Error> {
        let mut raw = std::ptr::null_mut();
        let status = unsafe { ffi::fig_fm_open(markdown.as_ptr(), markdown.len(), &mut raw) };
        Error::from_status(status)?;
        let raw = NonNull::new(raw).ok_or(Error::Internal)?;
        Ok(Self { raw })
    }

    fn ptr(&self) -> *mut ffi::FigFrontmatter {
        self.raw.as_ptr()
    }

    // ── value edits (over `Value`) ──────────────────────────────────────────

    /// Replace the value at `path` with `value`.
    pub fn replace_value(&mut self, path: &[Segment], value: &Value) -> Result<(), Error> {
        let repl = value_text(value)?;
        let p = to_ffi_path(path);
        let status = unsafe {
            ffi::fig_fm_replace_val(self.ptr(), p.as_ptr(), p.len(), repl.as_ptr(), repl.len())
        };
        Error::from_status(status)
    }

    /// Replace the key at `path` with `key`.
    pub fn replace_key(&mut self, path: &[Segment], key: &str) -> Result<(), Error> {
        let repl = value_text(&Value::Str(key.to_string()))?;
        let p = to_ffi_path(path);
        let status = unsafe {
            ffi::fig_fm_replace_key(self.ptr(), p.as_ptr(), p.len(), repl.as_ptr(), repl.len())
        };
        Error::from_status(status)
    }

    /// Insert `key: value` into the mapping at `path` (empty path = root).
    pub fn insert_value(&mut self, path: &[Segment], key: &str, value: &Value) -> Result<(), Error> {
        let key_text = value_text(&Value::Str(key.to_string()))?;
        let val = value_text(value)?;
        let p = to_ffi_path(path);
        let status = unsafe {
            ffi::fig_fm_insert_key(
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
        let val = value_text(value)?;
        let p = to_ffi_path(path);
        let status =
            unsafe { ffi::fig_fm_append_seq(self.ptr(), p.as_ptr(), p.len(), val.as_ptr(), val.len()) };
        Error::from_status(status)
    }

    /// Prepend `value` to the sequence at `path`.
    pub fn prepend_value(&mut self, path: &[Segment], value: &Value) -> Result<(), Error> {
        let val = value_text(value)?;
        let p = to_ffi_path(path);
        let status =
            unsafe { ffi::fig_fm_prepend_seq(self.ptr(), p.as_ptr(), p.len(), val.as_ptr(), val.len()) };
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

    // ── structural edits (no value) ─────────────────────────────────────────

    /// Delete the mapping entry named by `path`.
    pub fn delete(&mut self, path: &[Segment]) -> Result<(), Error> {
        let p = to_ffi_path(path);
        let status = unsafe { ffi::fig_fm_delete_key(self.ptr(), p.as_ptr(), p.len()) };
        Error::from_status(status)
    }

    /// Remove the item at `index` from the sequence at `path`.
    pub fn remove_item(&mut self, path: &[Segment], index: usize) -> Result<(), Error> {
        let p = to_ffi_path(path);
        let status = unsafe { ffi::fig_fm_remove_seq_item(self.ptr(), p.as_ptr(), p.len(), index) };
        Error::from_status(status)
    }

    /// Move the mapping entry at `src_path` to immediately before the entry at
    /// `dest_path`. Both must name keys in the same mapping. The moved entry
    /// keeps its owned comments; bytes between the two entries are preserved.
    pub fn move_key(&mut self, src_path: &[Segment], dest_path: &[Segment]) -> Result<(), Error> {
        let s = to_ffi_path(src_path);
        let d = to_ffi_path(dest_path);
        let status =
            unsafe { ffi::fig_fm_move_key(self.ptr(), s.as_ptr(), s.len(), d.as_ptr(), d.len()) };
        Error::from_status(status)
    }

    /// Reorder the entries of the mapping at `path` (empty path = root) so
    /// `keys` come first in that order; entries whose key is not listed keep
    /// their original relative order and follow. Unknown keys are ignored. Each
    /// entry's comments and interleaved trivia are preserved.
    pub fn reorder_keys<S: AsRef<str>>(&mut self, path: &[Segment], keys: &[S]) -> Result<(), Error> {
        let p = to_ffi_path(path);
        let k = to_ffi_keys(keys);
        let status = unsafe {
            ffi::fig_fm_reorder_keys(self.ptr(), p.as_ptr(), p.len(), k.as_ptr(), k.len())
        };
        Error::from_status(status)
    }

    /// Move the sequence item at index `from` to index `to` (array-move
    /// semantics). A block item keeps its owned comments; a flow sequence keeps
    /// its separators. No-op when `from == to`.
    pub fn move_item(&mut self, path: &[Segment], from: usize, to: usize) -> Result<(), Error> {
        let p = to_ffi_path(path);
        let status = unsafe { ffi::fig_fm_move_item(self.ptr(), p.as_ptr(), p.len(), from, to) };
        Error::from_status(status)
    }

    /// Reorder the items of the sequence at `path` so the items at `indices`
    /// (positions in the current order) come first, in that order; items not
    /// listed keep their original relative order and follow. Out-of-range
    /// indices are ignored.
    pub fn reorder_items(&mut self, path: &[Segment], indices: &[usize]) -> Result<(), Error> {
        let p = to_ffi_path(path);
        let status = unsafe {
            ffi::fig_fm_reorder_items(self.ptr(), p.as_ptr(), p.len(), indices.as_ptr(), indices.len())
        };
        Error::from_status(status)
    }

    /// Render the full markdown document with the edited frontmatter spliced
    /// back between the (untouched) fences. Borrows handle memory; invalidated
    /// by the next call or edit. Takes `&mut self` because the render buffer is
    /// rebuilt in place.
    pub fn render(&mut self) -> Result<&str, Error> {
        let mut ptr: *const u8 = std::ptr::null();
        let mut len: usize = 0;
        let status = unsafe { ffi::fig_fm_render(self.raw.as_ptr(), &mut ptr, &mut len) };
        Error::from_status(status)?;
        borrow_str(ptr, len)
    }
}

impl Drop for Frontmatter {
    fn drop(&mut self) {
        unsafe { ffi::fig_fm_destroy(self.raw.as_ptr()) };
    }
}
