use std::os::raw::c_int;

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[allow(dead_code)]
pub enum FigStatus {
    Ok = 0,
    InvalidArgument = 1,
    ParseError = 2,
    OutOfMemory = 3,
    UnsupportedFormat = 4,
    NotFound = 5,
    InternalError = 255,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FigFormat {
    Json = 1,
    Jsonc = 2,
    Yaml = 3,
    Toml = 4,
    Zon = 5,
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

unsafe extern "C" {
    pub fn fig_parse(
        input: *const u8,
        input_len: usize,
        format: c_int,
        out_doc: *mut *mut FigDocument,
    ) -> FigStatus;

    pub fn fig_document_destroy(doc: *mut FigDocument);
}

// Read traversal — consumed by `Document::to_value` and the serde deserializer.
unsafe extern "C" {
    pub fn fig_document_root(doc: *const FigDocument) -> FigNodeId;
    pub fn fig_node_kind(doc: *const FigDocument, node: FigNodeId) -> FigNodeKind;
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
    #[allow(dead_code)]
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
    pub fn fig_value_serialize(
        value: *mut FigValue,
        root: FigNodeId,
        format: c_int,
        out_ptr: *mut *const u8,
        out_len: *mut usize,
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
    pub open_fence: FigSpan,
    pub content: FigSpan,
    pub close_fence: FigSpan,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[allow(dead_code)]
pub enum FigEmbedType {
    FrontmatterYaml = 0,
    FrontmatterJson = 1,
    EndmatterYaml = 2,
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
    pub fn fig_editor_source(
        editor: *const FigEditor,
        out_ptr: *mut *const u8,
        out_len: *mut usize,
    ) -> FigStatus;

    #[allow(dead_code)]
    pub fn fig_embed_extract(
        input: *const u8,
        input_len: usize,
        embed_type: c_int,
        out_region: *mut FigRegion,
    ) -> FigStatus;

    pub fn fig_embed_open(
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
    pub fn fig_embed_render(
        fm: *mut FigEmbed,
        out_ptr: *mut *const u8,
        out_len: *mut usize,
    ) -> FigStatus;
}
