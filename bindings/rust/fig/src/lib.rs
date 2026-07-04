// Lets the `derive`-generated code refer to this crate as `fig::…` even from
// within the crate's own tests and examples.
extern crate self as fig;

mod diagnostics;
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

pub use diagnostics::{Warning, WarningCause, WarningCode};
pub use editor::{Editor, Segment};
pub use embed::{Embed, EmbedType, Extracted, Region, Span, split};
pub use error::{Error, ParseError};
pub use value::{ExtKind, Value};

#[cfg(feature = "derive")]
pub use convert::{FromValue, ToValue};
// Shared helpers the derive macros call instead of inlining a lookup, convert,
// and error per field.
#[cfg(feature = "derive")]
#[doc(hidden)]
pub use convert::{field, field_or_default, map_get};
// The derive macros share the trait names (trait vs. macro namespace), mirroring
// `serde::Serialize`. Glob users get both with one import.
#[cfg(feature = "derive")]
pub use fig_macros::{FromValue, ToValue};

#[cfg(feature = "serde")]
pub use de::{from_slice, from_str};
#[cfg(feature = "serde")]
pub use ser::{to_string, to_value};

use ffi::{FIG_NODE_NONE, FigNodeId, FigNodeKind};

/// A config format. Parsing and editing support `Json`/`Jsonc`/`Json5`/`Yaml`/
/// `Fig`; [`Value::serialize`] additionally supports `Toml`/`Zon`.
///
/// Every variant is always present, but the non-JSON formats are gated by the
/// crate features of the same name (`yaml`, `toml`, `zon`, `fig`; all on by
/// default). Disabling a feature compiles that format out of the bundled
/// native library, so selecting it then fails with [`Error::UnsupportedFormat`]
/// at runtime. (`Json`/`Jsonc`/`Json5` are always compiled in — they share the
/// JSON core.)
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Format {
    Json,
    Jsonc,
    Json5,
    Yaml,
    Toml,
    Zon,
    /// The native `fig` authoring dialect (see `src/languages/fig/DESIGN.md`
    /// in the core repo) — a memorable, typeable surface over the same AST.
    Fig,
}

impl From<Format> for ffi::FigFormat {
    fn from(format: Format) -> Self {
        match format {
            Format::Json => ffi::FigFormat::Json,
            Format::Jsonc => ffi::FigFormat::Jsonc,
            Format::Json5 => ffi::FigFormat::Json5,
            Format::Yaml => ffi::FigFormat::Yaml,
            Format::Toml => ffi::FigFormat::Toml,
            Format::Zon => ffi::FigFormat::Zon,
            Format::Fig => ffi::FigFormat::Fig,
        }
    }
}

/// Controls how [`Value::serialize_with`] renders output. The [`Default`] is
/// fig's historical style (pretty-printed, two-space indent), so
/// [`Value::serialize`] is exactly `serialize_with(format, SerializeOptions::default())`.
///
/// `pretty` is honored by [`Format::Json`] (multi-line vs. minified),
/// [`Format::Zon`] (`zig fmt` multi-line vs. inline `.{ a, b }`), and
/// [`Format::Toml`] (gates array wrapping); `indent` by [`Format::Json`] and
/// [`Format::Toml`]'s wrapped arrays; `width` by [`Format::Toml`]'s
/// inline-vs-section layout. [`Format::Yaml`] renders with its own fixed layout.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SerializeOptions {
    /// `true`: multi-line, indented output. `false`: compact single-line output
    /// with no insignificant whitespace. For TOML, `false` keeps every array on
    /// one line; `true` lets a wide array wrap (see `width`).
    pub pretty: bool,
    /// Spaces per indentation level when `pretty` is set (JSON, and TOML's wrapped
    /// arrays).
    pub indent: u8,
    /// Drop comments carried on the value instead of emitting them. Default
    /// `false` (preserve them where the target format allows).
    pub strip_comments: bool,
    /// [`Document::serialize`] only: preserve values the target format cannot
    /// represent natively (a null in TOML, a TOML datetime in JSON, …) through a
    /// `$fig` envelope, and decode any such envelope found in the source. Default
    /// `false` (lossy — an unrepresentable value is an [`Error::UnsupportedFormat`]).
    /// Ignored by [`Value::serialize_with`] (a built value has no source envelopes).
    pub lossless: bool,
    /// [`Format::Toml`] only: the column budget for its inline-vs-expanded layout.
    /// A mapping/array that renders within `width` columns stays inline
    /// (`k = { … }` / `[a, b]`); a wider one expands to a `[section]` / a wrapped
    /// array. Default `80`. Ignored by the other formats.
    pub width: u16,
}

impl Default for SerializeOptions {
    fn default() -> Self {
        Self { pretty: true, indent: 2, strip_comments: false, lossless: false, width: 80 }
    }
}

impl SerializeOptions {
    /// Compact single-line output with no insignificant whitespace.
    pub fn compact() -> Self {
        Self { pretty: false, ..Self::default() }
    }

    /// Pretty-printed output with the given number of spaces per indent level.
    pub fn pretty(indent: u8) -> Self {
        Self { pretty: true, indent, ..Self::default() }
    }

    /// This style with `lossless` enabled (see the field). Builder-style so
    /// `SerializeOptions::default().lossless()` reads naturally.
    pub fn lossless(self) -> Self {
        Self { lossless: true, ..self }
    }

    /// This style with comments stripped (see `strip_comments`).
    pub fn strip_comments(self) -> Self {
        Self { strip_comments: true, ..self }
    }

    /// This style with the given TOML inline-vs-section column budget (see
    /// `width`). Builder-style, e.g. `SerializeOptions::default().width(120)`.
    pub fn width(self, width: u16) -> Self {
        Self { width, ..self }
    }
}

impl From<SerializeOptions> for ffi::FigSerializeOptions {
    fn from(o: SerializeOptions) -> Self {
        ffi::FigSerializeOptions {
            size: std::mem::size_of::<ffi::FigSerializeOptions>() as u32,
            pretty: u8::from(o.pretty),
            indent: o.indent,
            strip_comments: u8::from(o.strip_comments),
            lossless: u8::from(o.lossless),
            width: o.width,
        }
    }
}

/// The linked fig library's version, from [`version`].
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Version {
    pub major: u8,
    pub minor: u8,
    pub patch: u8,
}

/// The version of the linked fig core, decoded from the packed
/// `(major << 16) | (minor << 8) | patch` that `fig_version` returns.
pub fn version() -> Version {
    let packed = unsafe { ffi::fig_version() };
    Version {
        major: (packed >> 16) as u8,
        minor: (packed >> 8) as u8,
        patch: packed as u8,
    }
}

/// The linked fig core's version as a `"major.minor.patch"` string.
pub fn version_string() -> &'static str {
    // Safety: `fig_version_string` returns a static NUL-terminated ASCII string
    // owned by the library, valid for the whole program.
    let ptr = unsafe { ffi::fig_version_string() };
    unsafe { std::ffi::CStr::from_ptr(ptr) }
        .to_str()
        .unwrap_or("")
}

/// What this build of the fig core can do with a format. Reflects both inherent
/// support (XML is reader-only; TOML/ZON parse and serialize but are not
/// editable) and build-time gating (a format compiled out reports all-false).
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Capabilities {
    /// [`Document::parse`] accepts this format.
    pub read: bool,
    /// The editor/embed APIs accept this format.
    pub edit: bool,
    /// The serializers can write this format.
    pub serialize: bool,
}

/// Query what this build can do with `format` (read/edit/serialize). Lets a host
/// pick a working format up front instead of probing via `UnsupportedFormat`.
pub fn capabilities(format: Format) -> Capabilities {
    let ffi_format: ffi::FigFormat = format.into();
    let bits = unsafe { ffi::fig_format_capabilities(ffi_format as c_int) };
    Capabilities {
        read: bits & (1 << 0) != 0,
        edit: bits & (1 << 1) != 0,
        serialize: bits & (1 << 2) != 0,
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

        // `fig_parse_ex` fills `err` on failure; on a parse error we project its
        // message/location into `Error::Parse`. Other statuses fold through
        // `from_status` as usual (the struct is meaningful only on failure).
        let mut err = ffi::FigError::new();
        let status = unsafe {
            ffi::fig_parse_ex(input.as_ptr(), input.len(), ffi_format as i32, &mut raw, &mut err)
        };
        if status != ffi::FigStatus(ffi::FigStatus::OK) {
            if status == ffi::FigStatus(ffi::FigStatus::PARSE_ERROR) {
                return Err(Error::Parse(crate::error::ParseError::from_ffi(&err)));
            }
            Error::from_status(status)?;
        }

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
        // `from_c` is the sole gate that turns the raw ABI int into the enum,
        // mapping any unknown/future kind to `Invalid` instead of risking UB.
        FigNodeKind::from_c(unsafe { ffi::fig_node_kind(self.ptr(), node) })
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

/// Cross-format conversion + serialization diagnostics over the parsed document.
impl Document {
    /// Render the whole document to `format` with the default output style — the
    /// cross-format conversion primitive (e.g. parse YAML, emit JSON). Unlike
    /// `to_value().serialize()`, this preserves comments carried on the source
    /// where the target allows, and collapses YAML's reference layer when leaving
    /// YAML. A value the target cannot represent is an [`Error::UnsupportedFormat`]
    /// unless `lossless` is set (see [`Document::serialize_with`]).
    pub fn serialize(&self, format: Format) -> Result<String, Error> {
        self.serialize_with(format, SerializeOptions::default())
    }

    /// As [`Document::serialize`], with `options` controlling output style,
    /// comment stripping, and lossless `$fig`-envelope round-tripping.
    pub fn serialize_with(&self, format: Format, options: SerializeOptions) -> Result<String, Error> {
        let ffi_format: ffi::FigFormat = format.into();
        let ffi_options: ffi::FigSerializeOptions = options.into();
        let mut ptr_out: *const u8 = std::ptr::null();
        let mut len: usize = 0;
        Error::from_status(unsafe {
            ffi::fig_document_serialize(
                self.raw.as_ptr(),
                ffi_format as c_int,
                &ffi_options,
                &mut ptr_out,
                &mut len,
            )
        })?;
        // Safety: on success the ABI guarantees `len` bytes at `ptr_out`, owned by
        // the handle and valid until the next serialize/destroy. Copy out now.
        let bytes = if len == 0 {
            &[][..]
        } else {
            unsafe { std::slice::from_raw_parts(ptr_out, len) }
        };
        Ok(std::str::from_utf8(bytes).map_err(|_| Error::Utf8)?.to_owned())
    }

    /// Report what serializing the whole document to `format` would silently lose
    /// (comments dropped/degraded, values dropped/degraded), using the same
    /// pipeline [`Document::serialize_with`] prints from. Returns one [`Warning`]
    /// per lossy event (empty if nothing is lost).
    pub fn diagnose(&self, format: Format, options: SerializeOptions) -> Result<Vec<Warning>, Error> {
        let ffi_format: ffi::FigFormat = format.into();
        let ffi_options: ffi::FigSerializeOptions = options.into();
        let mut count: usize = 0;
        Error::from_status(unsafe {
            ffi::fig_document_diagnose(self.raw.as_ptr(), ffi_format as c_int, &ffi_options, &mut count)
        })?;
        let mut out = Vec::with_capacity(count);
        for i in 0..count {
            let mut w = ffi::FigWarning::new();
            Error::from_status(unsafe { ffi::fig_document_warning(self.raw.as_ptr(), i, &mut w) })?;
            // Safety: on `OK`, `w` is filled with a warning whose path/note point
            // into the handle's arena, valid until the next diagnose/destroy.
            out.push(unsafe { Warning::from_ffi(&w) });
        }
        Ok(out)
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
    use super::{Document, Embed, EmbedType, Error, Format, Segment};

    #[test]
    fn parses_json_document() {
        let doc = Document::parse(br#"{"name":"fig","ok":true}"#, Format::Json);
        assert!(doc.is_ok());
    }

    #[test]
    fn parse_error_is_reported() {
        let err = Document::parse(br#"{"name":"fig""#, Format::Json).unwrap_err();
        let Error::Parse(detail) = &err else {
            panic!("expected Error::Parse, got {err:?}");
        };
        // The core surfaces a non-empty message (its error name). Offsets are not
        // yet plumbed, so the location fields are None for now.
        assert!(!detail.message.is_empty());
        assert_eq!(detail.byte_offset, None);
    }

    #[test]
    fn version_and_capabilities() {
        use super::{capabilities, version, version_string, Format};
        let v = version();
        // The packed version round-trips through the string form.
        assert_eq!(version_string(), format!("{}.{}.{}", v.major, v.minor, v.patch));
        // JSON is always fully supported in any build.
        let json = capabilities(Format::Json);
        assert!(json.read && json.edit && json.serialize);
    }

    #[test]
    fn document_serialize_converts_cross_format() {
        // YAML in, JSON out — the conversion primitive, not a value rebuild.
        let doc = Document::parse(b"name: fig\nnums:\n- 1\n- 2\n", Format::Yaml).unwrap();
        assert_eq!(
            doc.serialize(Format::Json).unwrap(),
            "{\n  \"name\": \"fig\",\n  \"nums\": [\n    1,\n    2\n  ]\n}\n",
        );
    }

    #[test]
    #[cfg(feature = "toml")]
    fn document_diagnose_reports_dropped_null() {
        use super::{SerializeOptions, WarningCause, WarningCode};
        let doc = Document::parse(b"a: null\nb: 1\n", Format::Yaml).unwrap();
        // A null can't survive in TOML → one value-dropped warning at path "a".
        let warns = doc.diagnose(Format::Toml, SerializeOptions::default()).unwrap();
        assert_eq!(warns.len(), 1);
        assert_eq!(warns[0].code, WarningCode::ValueDropped);
        assert_eq!(warns[0].cause, WarningCause::FormatLimitation);
        assert_eq!(warns[0].path, "a");
        // Lossless preserves the null → nothing lost.
        let none = doc
            .diagnose(Format::Toml, SerializeOptions::default().lossless())
            .unwrap();
        assert!(none.is_empty());
    }

    #[test]
    fn parse_error_message_is_surfaced_in_display() {
        let err = Document::parse(br#"{"name":"fig""#, Format::Json).unwrap_err();
        // Display includes the core's message after the generic prefix.
        assert!(err.to_string().starts_with("failed to parse input: "));
    }

    #[test]
    fn editor_comment_ops_add_set_and_delete() {
        use super::{Editor, Segment};
        let mut ed = Editor::open(b"a: 1\nb: 2\n", Format::Yaml).unwrap();
        ed.add_leading_comment(&[Segment::Key("b")], "why").unwrap();
        ed.set_trailing_comment(&[Segment::Key("b")], "two").unwrap();
        assert_eq!(ed.source().unwrap(), "a: 1\n# why\nb: 2 # two\n");
        ed.delete_trailing_comment(&[Segment::Key("b")]).unwrap();
        ed.delete_leading_comments(&[Segment::Key("b")]).unwrap();
        assert_eq!(ed.source().unwrap(), "a: 1\nb: 2\n");
    }

    #[test]
    fn editor_comments_unsupported_in_strict_json() {
        use super::{Editor, Error, Segment};
        let mut ed = Editor::open(br#"{"a":1}"#, Format::Json).unwrap();
        assert!(matches!(
            ed.add_leading_comment(&[Segment::Key("a")], "x"),
            Err(Error::UnsupportedFormat)
        ));
    }

    #[test]
    fn frontmatter_reorder_keys_preserves_comments_and_body() {
        let md = "---\ntitle: Hi\n# a comment\ntags:\n- x\nauthor: me\n---\n# Body\n";
        let mut fm = Embed::open(md.as_bytes(), EmbedType::FrontmatterYaml).unwrap();
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
        let mut fm = Embed::open(md.as_bytes(), EmbedType::FrontmatterYaml).unwrap();
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
        let mut fm = Embed::open(md.as_bytes(), EmbedType::FrontmatterYaml).unwrap();
        fm.reorder_items(&[Segment::Key("tags")], &[2, 0]).unwrap();
        assert_eq!(
            fm.render().unwrap(),
            "---\ntags:\n- z\n- x\n- y\n---\nbody\n",
        );
    }

    #[test]
    fn frontmatter_move_item_in_flow_sequence_keeps_separators() {
        let md = "---\ntags: [x, y, z]\n---\nbody\n";
        let mut fm = Embed::open(md.as_bytes(), EmbedType::FrontmatterYaml).unwrap();
        fm.move_item(&[Segment::Key("tags")], 2, 0).unwrap();
        assert_eq!(fm.render().unwrap(), "---\ntags: [z, x, y]\n---\nbody\n");
    }
}
