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

unsafe extern "C" {
    pub fn fig_parse(
        input: *const u8,
        input_len: usize,
        format: c_int,
        out_doc: *mut *mut FigDocument,
    ) -> FigStatus;

    pub fn fig_document_destroy(doc: *mut FigDocument);
}
