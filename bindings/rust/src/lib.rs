mod de;
mod editor;
mod error;
mod ffi;
mod frontmatter;
mod ser;

use std::ptr::NonNull;

pub use de::from_str;
pub use editor::{Editor, Segment};
pub use error::Error;
pub use frontmatter::Frontmatter;
pub use ser::to_string;

use ffi::{FigNodeId, FigNodeKind, FIG_NODE_NONE};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Format {
    Json,
    Jsonc,
    Yaml,
}

impl From<Format> for ffi::FigFormat {
    fn from(format: Format) -> Self {
        match format {
            Format::Json => ffi::FigFormat::Json,
            Format::Jsonc => ffi::FigFormat::Jsonc,
            Format::Yaml => ffi::FigFormat::Yaml,
        }
    }
}

#[derive(Debug)]
pub struct Document {
    raw: NonNull<ffi::FigDocument>,
}

impl Document {
    pub fn parse(input: &[u8], format: Format) -> Result<Self, Error> {
        let mut raw = std::ptr::null_mut();
        let ffi_format: ffi::FigFormat = format.into();

        let status =
            unsafe { ffi::fig_parse(input.as_ptr(), input.len(), ffi_format as i32, &mut raw) };

        Error::from_status(status)?;

        let raw = NonNull::new(raw).ok_or(Error::Internal)?;
        Ok(Self { raw })
    }

    fn ptr(&self) -> *const ffi::FigDocument {
        self.raw.as_ptr()
    }

    /// The root node, or `None` for an empty document.
    pub(crate) fn root(&self) -> Option<FigNodeId> {
        normalize(unsafe { ffi::fig_document_root(self.ptr()) })
    }

    pub(crate) fn kind(&self, node: FigNodeId) -> FigNodeKind {
        unsafe { ffi::fig_node_kind(self.ptr(), node) }
    }

    pub(crate) fn first_child(&self, node: FigNodeId) -> Option<FigNodeId> {
        normalize(unsafe { ffi::fig_node_first_child(self.ptr(), node) })
    }

    pub(crate) fn next_sibling(&self, node: FigNodeId) -> Option<FigNodeId> {
        normalize(unsafe { ffi::fig_node_next_sibling(self.ptr(), node) })
    }

    pub(crate) fn child_count(&self, node: FigNodeId) -> usize {
        unsafe { ffi::fig_node_child_count(self.ptr(), node) }
    }

    pub(crate) fn kv_key(&self, node: FigNodeId) -> Option<FigNodeId> {
        normalize(unsafe { ffi::fig_keyvalue_key(self.ptr(), node) })
    }

    pub(crate) fn kv_value(&self, node: FigNodeId) -> Option<FigNodeId> {
        normalize(unsafe { ffi::fig_keyvalue_value(self.ptr(), node) })
    }

    pub(crate) fn get_bool(&self, node: FigNodeId) -> Option<bool> {
        let mut out = false;
        unsafe { ffi::fig_node_bool(self.ptr(), node, &mut out) }.then_some(out)
    }

    /// The raw source text of a numeric scalar. Borrows document memory.
    pub(crate) fn number_raw(&self, node: FigNodeId) -> Option<Result<&str, Error>> {
        self.scalar_bytes(node, ffi::fig_node_number)
            .map(|bytes| std::str::from_utf8(bytes).map_err(|_| Error::Utf8))
    }

    /// The bytes of a string scalar, as UTF-8. Borrows document memory.
    pub(crate) fn get_str(&self, node: FigNodeId) -> Option<Result<&str, Error>> {
        self.scalar_bytes(node, ffi::fig_node_string)
            .map(|bytes| std::str::from_utf8(bytes).map_err(|_| Error::Utf8))
    }

    /// Shared helper for the byte-returning scalar accessors. The returned
    /// slice borrows memory owned by the document (valid until drop), which we
    /// tie to `&self`.
    fn scalar_bytes(
        &self,
        node: FigNodeId,
        accessor: unsafe extern "C" fn(
            *const ffi::FigDocument,
            FigNodeId,
            *mut *const u8,
            *mut usize,
        ) -> bool,
    ) -> Option<&[u8]> {
        let mut ptr: *const u8 = std::ptr::null();
        let mut len: usize = 0;
        let ok = unsafe { accessor(self.ptr(), node, &mut ptr, &mut len) };
        if !ok {
            return None;
        }
        if len == 0 {
            return Some(&[]);
        }
        // Safety: on success the ABI guarantees `ptr` points to `len` bytes
        // owned by the document, valid until `fig_document_destroy` (i.e. our
        // `Drop`). The returned borrow is bounded by `&self`.
        Some(unsafe { std::slice::from_raw_parts(ptr, len) })
    }
}

impl Drop for Document {
    fn drop(&mut self) {
        unsafe {
            ffi::fig_document_destroy(self.raw.as_ptr());
        }
    }
}

fn normalize(id: FigNodeId) -> Option<FigNodeId> {
    if id == FIG_NODE_NONE {
        None
    } else {
        Some(id)
    }
}

#[cfg(test)]
mod tests {
    use super::{Document, Error, Format};

    #[test]
    fn parses_json_document() {
        let doc = Document::parse(br#"{"name":"fig","ok":true}"#, Format::Json);
        assert!(doc.is_ok());
    }

    #[test]
    fn parse_error_is_reported() {
        let err = Document::parse(br#"{"name":"fig""#, Format::Json).unwrap_err();
        assert!(matches!(err, Error::Parse));
    }
}
