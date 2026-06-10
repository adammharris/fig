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
    InternalError = 255,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FigFormat {
    Json = 1,
    Jsonc = 2,
    Yaml = 3,
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
}

unsafe extern "C" {
    pub fn fig_parse(
        input: *const u8,
        input_len: usize,
        format: c_int,
        out_doc: *mut *mut FigDocument,
    ) -> FigStatus;

    pub fn fig_document_destroy(doc: *mut FigDocument);

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
