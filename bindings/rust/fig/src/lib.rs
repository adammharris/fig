// Lets the `derive`-generated code refer to this crate as `fig::…` even from
// within the crate's own tests and examples.
extern crate self as fig;

mod editor;
mod embed;
mod error;
mod ffi;
mod value;

#[cfg(feature = "derive")]
mod convert;
#[cfg(feature = "serde")]
mod de;
#[cfg(feature = "serde")]
mod ser;

use std::os::raw::c_int;
use std::ptr::NonNull;

pub use editor::{Editor, Segment};
pub use embed::{Embed, EmbedType};
pub use error::Error;
pub use value::{ExtKind, Value};

#[cfg(feature = "derive")]
pub use convert::{FromValue, ToValue};
// The derive macros share the trait names (trait vs. macro namespace), mirroring
// `serde::Serialize`. Glob users get both with one import.
#[cfg(feature = "derive")]
pub use fig_macros::{FromValue, ToValue};

#[cfg(feature = "serde")]
pub use de::{from_slice, from_str};
#[cfg(feature = "serde")]
pub use ser::{to_string, to_value};

use ffi::{FIG_NODE_NONE, FigNodeId, FigNodeKind};

/// A config format. Parsing and editing support `Json`/`Jsonc`/`Yaml`;
/// [`Value::serialize`] additionally supports `Toml`/`Zon`.
///
/// Every variant is always present, but the non-JSON formats are gated by the
/// crate features of the same name (`yaml`, `toml`, `zon`; all on by default).
/// Disabling a feature compiles that format out of the bundled native library,
/// so selecting it then fails with [`Error::UnsupportedFormat`] at runtime.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Format {
    Json,
    Jsonc,
    Yaml,
    Toml,
    Zon,
}

impl From<Format> for ffi::FigFormat {
    fn from(format: Format) -> Self {
        match format {
            Format::Json => ffi::FigFormat::Json,
            Format::Jsonc => ffi::FigFormat::Jsonc,
            Format::Yaml => ffi::FigFormat::Yaml,
            Format::Toml => ffi::FigFormat::Toml,
            Format::Zon => ffi::FigFormat::Zon,
        }
    }
}

/// Controls how [`Value::serialize_with`] renders output. The [`Default`] is
/// fig's historical style (pretty-printed, two-space indent), so
/// [`Value::serialize`] is exactly `serialize_with(format, SerializeOptions::default())`.
///
/// Honored by [`Format::Json`] today; other formats currently ignore these and
/// render with their built-in style.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SerializeOptions {
    /// `true`: multi-line, indented output. `false`: compact single-line output
    /// with no insignificant whitespace.
    pub pretty: bool,
    /// Spaces per indentation level when `pretty` is set.
    pub indent: u8,
}

impl Default for SerializeOptions {
    fn default() -> Self {
        Self { pretty: true, indent: 2 }
    }
}

impl SerializeOptions {
    /// Compact single-line output with no insignificant whitespace.
    pub fn compact() -> Self {
        Self { pretty: false, indent: 0 }
    }

    /// Pretty-printed output with the given number of spaces per indent level.
    pub fn pretty(indent: u8) -> Self {
        Self { pretty: true, indent }
    }
}

impl From<SerializeOptions> for ffi::FigSerializeOptions {
    fn from(o: SerializeOptions) -> Self {
        ffi::FigSerializeOptions {
            pretty: u8::from(o.pretty),
            indent: o.indent,
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
}

/// Read-path traversal over the parsed node graph: the public `to_value`, plus
/// the lower-level accessors the serde deserializer walks.
impl Document {
    /// Read the whole document into an owned [`Value`] tree — the non-serde
    /// structural read, the mirror of [`Value::serialize`]. An empty document is
    /// [`Value::Null`].
    pub fn to_value(&self) -> Result<Value, Error> {
        match self.root() {
            None => Ok(Value::Null),
            Some(id) => self.node_to_value(id),
        }
    }

    fn node_to_value(&self, id: FigNodeId) -> Result<Value, Error> {
        // A format-specific scalar masquerades as a string/int at the `kind`
        // ABI; recover it faithfully here (the serde path keeps the string/int).
        if let Some((kind, text)) = self.extended(id) {
            return Ok(Value::Extended { kind, text });
        }
        let kind = self.kind(id);
        match kind {
            FigNodeKind::Null => Ok(Value::Null),
            FigNodeKind::Bool => Ok(Value::Bool(self.get_bool(id).ok_or(Error::Internal)?)),
            FigNodeKind::Int | FigNodeKind::Float => {
                let raw = self.number_raw(id).ok_or(Error::Internal)??;
                value::number_from_raw(raw, kind == FigNodeKind::Float)
            }
            FigNodeKind::String => Ok(Value::Str(
                self.get_str(id).ok_or(Error::Internal)??.to_owned(),
            )),
            FigNodeKind::Sequence => {
                let mut items = Vec::with_capacity(self.child_count(id));
                let mut next = self.first_child(id);
                while let Some(child) = next {
                    items.push(self.node_to_value(child)?);
                    next = self.next_sibling(child);
                }
                Ok(Value::Seq(items))
            }
            FigNodeKind::Mapping => {
                let mut entries = Vec::with_capacity(self.child_count(id));
                let mut next = self.first_child(id);
                while let Some(kv) = next {
                    let key = self.kv_key(kv).ok_or(Error::Internal)?;
                    let value = match self.kv_value(kv) {
                        Some(vid) => self.node_to_value(vid)?,
                        None => Value::Null,
                    };
                    entries.push((self.node_to_value(key)?, value));
                    next = self.next_sibling(kv);
                }
                Ok(Value::Map(entries))
            }
            // A bare keyvalue, an invalid id, or an unresolved alias can't stand
            // alone as a value.
            FigNodeKind::Keyvalue | FigNodeKind::Invalid | FigNodeKind::Alias => {
                Err(Error::Internal)
            }
        }
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

    /// If `node` is a format-specific extended scalar (TOML datetime, ZON
    /// enum/char literal), recover its [`ExtKind`] and text; `None` otherwise.
    /// Used only by the structural [`Document::to_value`] read — the serde path
    /// reads these as plain strings/ints.
    pub(crate) fn extended(&self, node: FigNodeId) -> Option<(ExtKind, String)> {
        let mut kind: c_int = 0;
        let mut ptr: *const u8 = std::ptr::null();
        let mut len: usize = 0;
        let ok = unsafe { ffi::fig_node_extended(self.ptr(), node, &mut kind, &mut ptr, &mut len) };
        if !ok {
            return None;
        }
        let ext = ExtKind::from_c(kind)?;
        let text = if len == 0 {
            String::new()
        } else {
            // Safety: on success the ABI guarantees `ptr` points to `len` bytes
            // owned by the document, valid until our `Drop`.
            let bytes = unsafe { std::slice::from_raw_parts(ptr, len) };
            std::str::from_utf8(bytes).ok()?.to_owned()
        };
        Some((ext, text))
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
    if id == FIG_NODE_NONE { None } else { Some(id) }
}

#[cfg(test)]
mod tests {
    use super::{Document, Embed, Error, Format, Segment};

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

    #[test]
    fn frontmatter_reorder_keys_preserves_comments_and_body() {
        let md = "---\ntitle: Hi\n# a comment\ntags:\n- x\nauthor: me\n---\n# Body\n";
        let mut fm = Embed::frontmatter(md.as_bytes()).unwrap();
        // String keys (the diaryx call site passes `Vec<String>`).
        let order = vec![String::from("author"), String::from("title")];
        fm.reorder_keys(&[], &order).unwrap();
        assert_eq!(
            fm.render().unwrap(),
            "---\nauthor: me\ntitle: Hi\n# a comment\ntags:\n- x\n---\n# Body\n",
        );
    }

    #[test]
    fn frontmatter_move_key_preserves_comments_and_body() {
        let md = "---\na: 1\n# note for c\nc: 3\nb: 2\n---\nbody\n";
        let mut fm = Embed::frontmatter(md.as_bytes()).unwrap();
        fm.move_key(&[Segment::Key("c")], &[Segment::Key("a")])
            .unwrap();
        assert_eq!(
            fm.render().unwrap(),
            "---\n# note for c\nc: 3\na: 1\nb: 2\n---\nbody\n",
        );
    }

    #[test]
    fn frontmatter_reorder_items_in_block_sequence() {
        let md = "---\ntags:\n- x\n- y\n- z\n---\nbody\n";
        let mut fm = Embed::frontmatter(md.as_bytes()).unwrap();
        fm.reorder_items(&[Segment::Key("tags")], &[2, 0]).unwrap();
        assert_eq!(
            fm.render().unwrap(),
            "---\ntags:\n- z\n- x\n- y\n---\nbody\n",
        );
    }

    #[test]
    fn frontmatter_move_item_in_flow_sequence_keeps_separators() {
        let md = "---\ntags: [x, y, z]\n---\nbody\n";
        let mut fm = Embed::frontmatter(md.as_bytes()).unwrap();
        fm.move_item(&[Segment::Key("tags")], 2, 0).unwrap();
        assert_eq!(fm.render().unwrap(), "---\ntags: [z, x, y]\n---\nbody\n");
    }
}
