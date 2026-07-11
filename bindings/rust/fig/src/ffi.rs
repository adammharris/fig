use std::os::raw::c_int;

/// A fig C ABI status code, as a transparent wrapper over the raw `c_int` the
/// ABI returns — deliberately *not* a Rust `enum`.
///
/// A fieldless `#[repr(C)]` enum returned by value from an `extern "C"` function
/// is undefined behavior the instant the callee returns a discriminant the enum
/// does not list, and fig's status set is allowed to grow after 1.0. The newtype
/// preserves any code unchanged; compare against the associated constants and
/// route unrecognized values through a fallback (see [`crate::error::Error::from_status`]).
#[repr(transparent)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct FigStatus(pub c_int);

#[allow(dead_code)]
impl FigStatus {
    pub const OK: c_int = 0;
    pub const INVALID_ARGUMENT: c_int = 1;
    pub const PARSE_ERROR: c_int = 2;
    pub const OUT_OF_MEMORY: c_int = 3;
    pub const UNSUPPORTED_FORMAT: c_int = 4;
    pub const NOT_FOUND: c_int = 5;
    pub const INTERNAL_ERROR: c_int = 255;
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FigFormat {
    Json = 1,
    Jsonc = 2,
    Yaml = 3,
    Toml = 4,
    Zon = 5,
    // `Xml = 6` in the C ABI is reader-only and has no writable `Format`
    // variant, so it is intentionally omitted here; the discriminant gap is
    // deliberate to keep JSON5 at its stable ABI value.
    Json5 = 7,
    // The native `fig` authoring dialect. Appended, same reasoning as JSON5.
    Fig = 8,
}

pub enum FigDocument {}

pub type FigNodeId = u32;

/// Sentinel for "no such node", matching `FIG_NODE_NONE` in `fig.h`.
pub const FIG_NODE_NONE: FigNodeId = 0xFFFF_FFFF;

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[allow(dead_code)]
pub enum FigNodeKind {
    Invalid = -1,
    Null = 0,
    Bool = 1,
    Int = 2,
    Float = 3,
    String = 4,
    Sequence = 5,
    Mapping = 6,
    Keyvalue = 7,
    Alias = 8,
}

impl FigNodeKind {
    /// Map the raw `c_int` returned by `fig_node_kind` onto a `FigNodeKind`.
    /// Unknown / future kinds collapse to [`FigNodeKind::Invalid`] rather than
    /// being reinterpreted as an out-of-range enum value — which, for a value
    /// returned by an `extern "C"` function into a Rust enum, is undefined
    /// behavior. This is the only place a raw kind crosses into the enum.
    pub(crate) fn from_c(raw: c_int) -> Self {
        match raw {
            0 => FigNodeKind::Null,
            1 => FigNodeKind::Bool,
            2 => FigNodeKind::Int,
            3 => FigNodeKind::Float,
            4 => FigNodeKind::String,
            5 => FigNodeKind::Sequence,
            6 => FigNodeKind::Mapping,
            7 => FigNodeKind::Keyvalue,
            8 => FigNodeKind::Alias,
            _ => FigNodeKind::Invalid,
        }
    }
}

/// A caller-allocated parse diagnostic. Mirrors `FigError` in `fig.h`. Lead with
/// `size = size_of::<FigError>()`: the library writes only the fields `size`
/// covers, so it can gain fields in a later release without breaking this layout.
/// `byte_offset`/`line`/`column` are 0 when unknown (always 0 in this release —
/// offset plumbing is a planned core follow-up). `message` is NUL-terminated and
/// truncated to fit; `message_len` excludes the NUL.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct FigError {
    pub size: u32,
    pub code: c_int,
    pub byte_offset: usize,
    pub line: u32,
    pub column: u32,
    pub message_len: usize,
    pub message: [u8; 256],
}

impl FigError {
    /// A zeroed struct with `size` set, ready to pass to `fig_parse_ex`.
    pub fn new() -> Self {
        FigError {
            size: std::mem::size_of::<FigError>() as u32,
            code: 0,
            byte_offset: 0,
            line: 0,
            column: 0,
            message_len: 0,
            message: [0; 256],
        }
    }
}

unsafe extern "C" {
    pub fn fig_version() -> u32;
    pub fn fig_version_string() -> *const std::os::raw::c_char;
    pub fn fig_format_capabilities(format: c_int) -> u32;

    // Declared for ABI-mirror completeness; the binding parses via `fig_parse_ex`
    // (richer errors), so this plain entry point is not called from Rust.
    #[allow(dead_code)]
    pub fn fig_parse(
        input: *const u8,
        input_len: usize,
        format: c_int,
        out_doc: *mut *mut FigDocument,
    ) -> FigStatus;

    pub fn fig_parse_ex(
        input: *const u8,
        input_len: usize,
        format: c_int,
        out_doc: *mut *mut FigDocument,
        out_err: *mut FigError,
    ) -> FigStatus;

    pub fn fig_document_destroy(doc: *mut FigDocument);

    pub fn fig_document_serialize(
        doc: *mut FigDocument,
        format: c_int,
        options: *const FigSerializeOptions,
        out_ptr: *mut *const u8,
        out_len: *mut usize,
    ) -> FigStatus;
}

// Read traversal — consumed by `Document::to_value` and the serde deserializer.
unsafe extern "C" {
    pub fn fig_document_root(doc: *const FigDocument) -> FigNodeId;
    // Returns the raw kind as `c_int`, not `FigNodeKind`: decoding it directly
    // into the enum would be UB if the core returned an unlisted value. Callers
    // go through `FigNodeKind::from_c`.
    pub fn fig_node_kind(doc: *const FigDocument, node: FigNodeId) -> c_int;
    pub fn fig_node_first_child(doc: *const FigDocument, node: FigNodeId) -> FigNodeId;
    pub fn fig_node_next_sibling(doc: *const FigDocument, node: FigNodeId) -> FigNodeId;
    pub fn fig_node_child_count(doc: *const FigDocument, node: FigNodeId) -> usize;
    pub fn fig_keyvalue_key(doc: *const FigDocument, node: FigNodeId) -> FigNodeId;
    pub fn fig_keyvalue_value(doc: *const FigDocument, node: FigNodeId) -> FigNodeId;

    pub fn fig_node_bool(doc: *const FigDocument, node: FigNodeId, out: *mut bool) -> bool;
    pub fn fig_node_number(
        doc: *const FigDocument,
        node: FigNodeId,
        out_ptr: *mut *const u8,
        out_len: *mut usize,
    ) -> bool;
    pub fn fig_node_string(
        doc: *const FigDocument,
        node: FigNodeId,
        out_ptr: *mut *const u8,
        out_len: *mut usize,
    ) -> bool;
    pub fn fig_node_extended(
        doc: *const FigDocument,
        node: FigNodeId,
        out_kind: *mut c_int,
        out_ptr: *mut *const u8,
        out_len: *mut usize,
    ) -> bool;
}

// ---- value construction + serialization ----

pub enum FigValue {}

/// A `key: value` entry for `fig_value_map`. Mirrors `FigKeyValue` in `fig.h`.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct FigKeyValue {
    pub key: FigNodeId,
    pub value: FigNodeId,
}

/// Output style for `fig_value_serialize_opts`/`fig_document_serialize`. Mirrors
/// `FigSerializeOptions` in `fig.h`. ALL trailing fields are declared explicitly
/// (not left to struct padding): with `size = size_of` the core reads every byte
/// up to `size`, so an undeclared `strip_comments`/`lossless` would otherwise be
/// read out of uninitialized padding.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct FigSerializeOptions {
    /// Set to `size_of::<FigSerializeOptions>()`. Version tag for the struct:
    /// the core reads a field only when `size` covers it, so fields can be
    /// appended without breaking this layout. See `FigSerializeOptions` in `fig.h`.
    pub size: u32,
    pub pretty: u8,
    pub indent: u8,
    pub strip_comments: u8,
    pub lossless: u8,
    pub width: u16,
    /// fig-format fragments only: nonzero renders a container root as inline
    /// flow (`[a, b]` / `{ k = v }`). Set by the editors' splice path (see
    /// `value_text`); not exposed on the public `SerializeOptions` — inline is
    /// a property of *where* the text goes, not a caller style preference.
    pub flow: u8,
}

/// One lossy event from `fig_*_diagnose`, pulled by index via `fig_*_warning`.
/// Caller-allocated; lead with `size = size_of::<FigWarning>()` (same policy as
/// `FigSerializeOptions`/`FigError`). `path`/`note` are NOT NUL-terminated and
/// borrow the producing handle's diagnostics arena (valid until the next
/// diagnose on it or its destroy) — copy them out before then. Mirrors
/// `FigWarning` in `fig.h`.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct FigWarning {
    pub size: u32,
    pub code: c_int,
    pub cause: c_int,
    pub path: *const u8,
    pub path_len: usize,
    pub note: *const u8,
    pub note_len: usize,
}

impl FigWarning {
    /// A zeroed struct with `size` set, ready to pass to a `fig_*_warning` call.
    pub fn new() -> Self {
        FigWarning {
            size: std::mem::size_of::<FigWarning>() as u32,
            code: 0,
            cause: 0,
            path: std::ptr::null(),
            path_len: 0,
            note: std::ptr::null(),
            note_len: 0,
        }
    }
}

unsafe extern "C" {
    pub fn fig_value_create(out_value: *mut *mut FigValue) -> FigStatus;
    pub fn fig_value_destroy(value: *mut FigValue);

    pub fn fig_value_null(value: *mut FigValue, out_id: *mut FigNodeId) -> FigStatus;
    pub fn fig_value_bool(value: *mut FigValue, b: bool, out_id: *mut FigNodeId) -> FigStatus;
    pub fn fig_value_int(value: *mut FigValue, n: i64, out_id: *mut FigNodeId) -> FigStatus;
    pub fn fig_value_uint(value: *mut FigValue, n: u64, out_id: *mut FigNodeId) -> FigStatus;
    pub fn fig_value_number(
        value: *mut FigValue,
        raw: *const u8,
        raw_len: usize,
        is_float: bool,
        out_id: *mut FigNodeId,
    ) -> FigStatus;
    pub fn fig_value_string(
        value: *mut FigValue,
        ptr: *const u8,
        len: usize,
        out_id: *mut FigNodeId,
    ) -> FigStatus;
    pub fn fig_value_extended(
        value: *mut FigValue,
        kind: c_int,
        text: *const u8,
        text_len: usize,
        out_id: *mut FigNodeId,
    ) -> FigStatus;
    pub fn fig_value_seq(
        value: *mut FigValue,
        items: *const FigNodeId,
        items_len: usize,
        out_id: *mut FigNodeId,
    ) -> FigStatus;
    pub fn fig_value_map(
        value: *mut FigValue,
        entries: *const FigKeyValue,
        entries_len: usize,
        out_id: *mut FigNodeId,
    ) -> FigStatus;
    // ABI-mirror decl; the binding always serializes through the `_opts` form.
    #[allow(dead_code)]
    pub fn fig_value_serialize(
        value: *mut FigValue,
        root: FigNodeId,
        format: c_int,
        out_ptr: *mut *const u8,
        out_len: *mut usize,
    ) -> FigStatus;
    pub fn fig_value_serialize_opts(
        value: *mut FigValue,
        root: FigNodeId,
        format: c_int,
        options: *const FigSerializeOptions,
        out_ptr: *mut *const u8,
        out_len: *mut usize,
    ) -> FigStatus;
}

// ---- serialization diagnostics ----

unsafe extern "C" {
    pub fn fig_document_diagnose(
        doc: *mut FigDocument,
        format: c_int,
        options: *const FigSerializeOptions,
        out_count: *mut usize,
    ) -> FigStatus;
    pub fn fig_document_warning(
        doc: *mut FigDocument,
        index: usize,
        out: *mut FigWarning,
    ) -> FigStatus;
    pub fn fig_value_diagnose(
        value: *mut FigValue,
        root: FigNodeId,
        format: c_int,
        options: *const FigSerializeOptions,
        out_count: *mut usize,
    ) -> FigStatus;
    pub fn fig_value_warning(
        value: *mut FigValue,
        index: usize,
        out: *mut FigWarning,
    ) -> FigStatus;
}

// ---- editing (write path) ----

pub enum FigEditor {}
pub enum FigEmbed {}

/// One step of a path: `kind == 0` selects mapping key `key_ptr[0..key_len]`;
/// `kind == 1` selects sequence element `index`. Mirrors `FigPathSegment` in
/// `fig.h`.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct FigPathSegment {
    pub kind: i32,
    pub key_ptr: *const u8,
    pub key_len: usize,
    pub index: usize,
}

/// A borrowed UTF-8 string slice (`ptr[0..len]`) passed across the C ABI.
/// Mirrors `FigStr` in `fig.h`; used for the key list of `*_reorder_keys`.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct FigStr {
    pub ptr: *const u8,
    pub len: usize,
}

// `FigSpan`/`FigRegion`/`fig_embed_extract` mirror the low-level embed C ABI.
// The Rust-facing consumer is `Embed` (which uses `fig_embed_*`); these are
// declared for parity with the header and for any future low-level wrapper.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
#[allow(dead_code)]
pub struct FigSpan {
    pub start: usize,
    pub end: usize,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
#[allow(dead_code)]
pub struct FigRegion {
    /// Size-version tag: set to `size_of::<FigRegion>()` before
    /// `fig_embed_extract` so the library only writes the fields this layout
    /// covers. A zero `size` (e.g. from `Default`) makes the library write
    /// nothing — always set it explicitly.
    pub size: u32,
    pub open_fence: FigSpan,
    pub content: FigSpan,
    pub close_fence: FigSpan,
    pub body: FigSpan,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[allow(dead_code)]
pub enum FigEmbedType {
    FrontmatterYaml = 0,
    FrontmatterJson = 1,
    EndmatterYaml = 2,
    FrontmatterFig = 3,
    PlusToml = 4,
    FencedYaml = 5,
    FencedJson = 6,
    FencedToml = 7,
    MdFrontmatterJson = 8,
    MdFrontmatterToml = 9,
    MdFrontmatterFig = 10,
    HtmlScriptFig = 11,
    HtmlScriptYaml = 12,
    HtmlScriptJson = 13,
    HtmlScriptToml = 14,
}

unsafe extern "C" {
    pub fn fig_editor_create(
        input: *const u8,
        input_len: usize,
        format: c_int,
        out_editor: *mut *mut FigEditor,
    ) -> FigStatus;
    pub fn fig_editor_destroy(editor: *mut FigEditor);

    pub fn fig_editor_replace_val(
        editor: *mut FigEditor,
        path: *const FigPathSegment,
        path_len: usize,
        repl: *const u8,
        repl_len: usize,
    ) -> FigStatus;
    pub fn fig_editor_replace_key(
        editor: *mut FigEditor,
        path: *const FigPathSegment,
        path_len: usize,
        repl: *const u8,
        repl_len: usize,
    ) -> FigStatus;
    pub fn fig_editor_set(
        editor: *mut FigEditor,
        path: *const FigPathSegment,
        path_len: usize,
        val: *const u8,
        val_len: usize,
    ) -> FigStatus;
    pub fn fig_editor_add_leading_comment(
        editor: *mut FigEditor,
        path: *const FigPathSegment,
        path_len: usize,
        text: *const u8,
        text_len: usize,
    ) -> FigStatus;
    pub fn fig_editor_set_trailing_comment(
        editor: *mut FigEditor,
        path: *const FigPathSegment,
        path_len: usize,
        text: *const u8,
        text_len: usize,
    ) -> FigStatus;
    pub fn fig_editor_delete_leading_comments(
        editor: *mut FigEditor,
        path: *const FigPathSegment,
        path_len: usize,
    ) -> FigStatus;
    pub fn fig_editor_delete_trailing_comment(
        editor: *mut FigEditor,
        path: *const FigPathSegment,
        path_len: usize,
    ) -> FigStatus;
    pub fn fig_editor_get_leading_comment(
        editor: *mut FigEditor,
        path: *const FigPathSegment,
        path_len: usize,
        out_ptr: *mut *const u8,
        out_len: *mut usize,
    ) -> FigStatus;
    pub fn fig_editor_get_trailing_comment(
        editor: *mut FigEditor,
        path: *const FigPathSegment,
        path_len: usize,
        out_ptr: *mut *const u8,
        out_len: *mut usize,
    ) -> FigStatus;
    pub fn fig_editor_insert_key(
        editor: *mut FigEditor,
        path: *const FigPathSegment,
        path_len: usize,
        key: *const u8,
        key_len: usize,
        val: *const u8,
        val_len: usize,
    ) -> FigStatus;
    pub fn fig_editor_delete_key(
        editor: *mut FigEditor,
        path: *const FigPathSegment,
        path_len: usize,
    ) -> FigStatus;
    pub fn fig_editor_append_seq(
        editor: *mut FigEditor,
        path: *const FigPathSegment,
        path_len: usize,
        val: *const u8,
        val_len: usize,
    ) -> FigStatus;
    pub fn fig_editor_prepend_seq(
        editor: *mut FigEditor,
        path: *const FigPathSegment,
        path_len: usize,
        val: *const u8,
        val_len: usize,
    ) -> FigStatus;
    pub fn fig_editor_remove_seq_item(
        editor: *mut FigEditor,
        path: *const FigPathSegment,
        path_len: usize,
        index: usize,
    ) -> FigStatus;
    pub fn fig_editor_move_key(
        editor: *mut FigEditor,
        src_path: *const FigPathSegment,
        src_path_len: usize,
        dest_path: *const FigPathSegment,
        dest_path_len: usize,
    ) -> FigStatus;
    pub fn fig_editor_reorder_keys(
        editor: *mut FigEditor,
        path: *const FigPathSegment,
        path_len: usize,
        keys: *const FigStr,
        keys_len: usize,
    ) -> FigStatus;
    pub fn fig_editor_move_item(
        editor: *mut FigEditor,
        path: *const FigPathSegment,
        path_len: usize,
        from: usize,
        to: usize,
    ) -> FigStatus;
    pub fn fig_editor_reorder_items(
        editor: *mut FigEditor,
        path: *const FigPathSegment,
        path_len: usize,
        indices: *const usize,
        indices_len: usize,
    ) -> FigStatus;
    pub fn fig_editor_set_sequence(
        editor: *mut FigEditor,
        path: *const FigPathSegment,
        path_len: usize,
        items: *const FigStr,
        items_len: usize,
    ) -> FigStatus;
    pub fn fig_editor_source(
        editor: *const FigEditor,
        out_ptr: *mut *const u8,
        out_len: *mut usize,
    ) -> FigStatus;

    pub fn fig_embed_extract(
        input: *const u8,
        input_len: usize,
        embed_type: c_int,
        out_region: *mut FigRegion,
    ) -> FigStatus;

    pub fn fig_embed_detect(
        input: *const u8,
        input_len: usize,
        out_embed_type: *mut c_int,
    ) -> FigStatus;

    pub fn fig_embed_open(
        input: *const u8,
        input_len: usize,
        embed_type: c_int,
        out_embed: *mut *mut FigEmbed,
    ) -> FigStatus;
    pub fn fig_embed_open_or_init(
        input: *const u8,
        input_len: usize,
        embed_type: c_int,
        out_embed: *mut *mut FigEmbed,
    ) -> FigStatus;
    pub fn fig_embed_destroy(fm: *mut FigEmbed);

    pub fn fig_embed_replace_val(
        fm: *mut FigEmbed,
        path: *const FigPathSegment,
        path_len: usize,
        repl: *const u8,
        repl_len: usize,
    ) -> FigStatus;
    pub fn fig_embed_replace_key(
        fm: *mut FigEmbed,
        path: *const FigPathSegment,
        path_len: usize,
        repl: *const u8,
        repl_len: usize,
    ) -> FigStatus;
    pub fn fig_embed_set(
        fm: *mut FigEmbed,
        path: *const FigPathSegment,
        path_len: usize,
        val: *const u8,
        val_len: usize,
    ) -> FigStatus;
    pub fn fig_embed_add_leading_comment(
        fm: *mut FigEmbed,
        path: *const FigPathSegment,
        path_len: usize,
        text: *const u8,
        text_len: usize,
    ) -> FigStatus;
    pub fn fig_embed_set_trailing_comment(
        fm: *mut FigEmbed,
        path: *const FigPathSegment,
        path_len: usize,
        text: *const u8,
        text_len: usize,
    ) -> FigStatus;
    pub fn fig_embed_delete_leading_comments(
        fm: *mut FigEmbed,
        path: *const FigPathSegment,
        path_len: usize,
    ) -> FigStatus;
    pub fn fig_embed_delete_trailing_comment(
        fm: *mut FigEmbed,
        path: *const FigPathSegment,
        path_len: usize,
    ) -> FigStatus;
    pub fn fig_embed_get_leading_comment(
        fm: *mut FigEmbed,
        path: *const FigPathSegment,
        path_len: usize,
        out_ptr: *mut *const u8,
        out_len: *mut usize,
    ) -> FigStatus;
    pub fn fig_embed_get_trailing_comment(
        fm: *mut FigEmbed,
        path: *const FigPathSegment,
        path_len: usize,
        out_ptr: *mut *const u8,
        out_len: *mut usize,
    ) -> FigStatus;
    pub fn fig_embed_insert_key(
        fm: *mut FigEmbed,
        path: *const FigPathSegment,
        path_len: usize,
        key: *const u8,
        key_len: usize,
        val: *const u8,
        val_len: usize,
    ) -> FigStatus;
    pub fn fig_embed_delete_key(
        fm: *mut FigEmbed,
        path: *const FigPathSegment,
        path_len: usize,
    ) -> FigStatus;
    pub fn fig_embed_append_seq(
        fm: *mut FigEmbed,
        path: *const FigPathSegment,
        path_len: usize,
        val: *const u8,
        val_len: usize,
    ) -> FigStatus;
    pub fn fig_embed_prepend_seq(
        fm: *mut FigEmbed,
        path: *const FigPathSegment,
        path_len: usize,
        val: *const u8,
        val_len: usize,
    ) -> FigStatus;
    pub fn fig_embed_remove_seq_item(
        fm: *mut FigEmbed,
        path: *const FigPathSegment,
        path_len: usize,
        index: usize,
    ) -> FigStatus;
    pub fn fig_embed_move_key(
        fm: *mut FigEmbed,
        src_path: *const FigPathSegment,
        src_path_len: usize,
        dest_path: *const FigPathSegment,
        dest_path_len: usize,
    ) -> FigStatus;
    pub fn fig_embed_reorder_keys(
        fm: *mut FigEmbed,
        path: *const FigPathSegment,
        path_len: usize,
        keys: *const FigStr,
        keys_len: usize,
    ) -> FigStatus;
    pub fn fig_embed_move_item(
        fm: *mut FigEmbed,
        path: *const FigPathSegment,
        path_len: usize,
        from: usize,
        to: usize,
    ) -> FigStatus;
    pub fn fig_embed_reorder_items(
        fm: *mut FigEmbed,
        path: *const FigPathSegment,
        path_len: usize,
        indices: *const usize,
        indices_len: usize,
    ) -> FigStatus;
    pub fn fig_embed_set_sequence(
        fm: *mut FigEmbed,
        path: *const FigPathSegment,
        path_len: usize,
        items: *const FigStr,
        items_len: usize,
    ) -> FigStatus;
    pub fn fig_embed_replace_body(
        fm: *mut FigEmbed,
        body: *const u8,
        body_len: usize,
    ) -> FigStatus;
    pub fn fig_embed_render(
        fm: *mut FigEmbed,
        out_ptr: *mut *const u8,
        out_len: *mut usize,
    ) -> FigStatus;
}
