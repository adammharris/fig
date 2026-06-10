//! Comment-preserving editing of YAML frontmatter inside a markdown file.
//!
//! [`Frontmatter`] opens a markdown document, locates its `---…---` YAML
//! frontmatter, and edits only that block — the fences and the markdown body
//! are left byte-identical, and within the frontmatter only the changed node's
//! bytes move (comments, key order, and formatting are preserved). This is the
//! Diaryx-facing write path: reads stay on [`crate::from_str`].

use std::ptr::NonNull;

use serde::Serialize;

use crate::editor::{borrow_str, to_ffi_path, value_text, Segment};
use crate::error::Error;
use crate::ffi;

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

    /// Replace the value at `path` with the serialized form of `value`.
    pub fn replace<T: Serialize + ?Sized>(&mut self, path: &[Segment], value: &T) -> Result<(), Error> {
        let repl = value_text(value)?;
        let p = to_ffi_path(path);
        let status = unsafe {
            ffi::fig_fm_replace_val(self.ptr(), p.as_ptr(), p.len(), repl.as_ptr(), repl.len())
        };
        Error::from_status(status)
    }

    /// Replace the key at `path` with the serialized form of `key`.
    pub fn replace_key(&mut self, path: &[Segment], key: &str) -> Result<(), Error> {
        let repl = value_text(key)?;
        let p = to_ffi_path(path);
        let status = unsafe {
            ffi::fig_fm_replace_key(self.ptr(), p.as_ptr(), p.len(), repl.as_ptr(), repl.len())
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

    /// Delete the mapping entry named by `path`.
    pub fn delete(&mut self, path: &[Segment]) -> Result<(), Error> {
        let p = to_ffi_path(path);
        let status = unsafe { ffi::fig_fm_delete_key(self.ptr(), p.as_ptr(), p.len()) };
        Error::from_status(status)
    }

    /// Append `value` to the sequence at `path`.
    pub fn append<T: Serialize + ?Sized>(&mut self, path: &[Segment], value: &T) -> Result<(), Error> {
        let val = value_text(value)?;
        let p = to_ffi_path(path);
        let status =
            unsafe { ffi::fig_fm_append_seq(self.ptr(), p.as_ptr(), p.len(), val.as_ptr(), val.len()) };
        Error::from_status(status)
    }

    /// Prepend `value` to the sequence at `path`.
    pub fn prepend<T: Serialize + ?Sized>(&mut self, path: &[Segment], value: &T) -> Result<(), Error> {
        let val = value_text(value)?;
        let p = to_ffi_path(path);
        let status =
            unsafe { ffi::fig_fm_prepend_seq(self.ptr(), p.as_ptr(), p.len(), val.as_ptr(), val.len()) };
        Error::from_status(status)
    }

    /// Remove the item at `index` from the sequence at `path`.
    pub fn remove_item(&mut self, path: &[Segment], index: usize) -> Result<(), Error> {
        let p = to_ffi_path(path);
        let status = unsafe { ffi::fig_fm_remove_seq_item(self.ptr(), p.as_ptr(), p.len(), index) };
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
