mod ffi;

use std::ptr::NonNull;

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

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Error {
    InvalidArgument,
    Parse,
    OutOfMemory,
    UnsupportedFormat,
    Internal,
}

impl Error {
    fn from_status(status: ffi::FigStatus) -> Result<(), Self> {
        match status {
            ffi::FigStatus::Ok => Ok(()),
            ffi::FigStatus::InvalidArgument => Err(Self::InvalidArgument),
            ffi::FigStatus::ParseError => Err(Self::Parse),
            ffi::FigStatus::OutOfMemory => Err(Self::OutOfMemory),
            ffi::FigStatus::UnsupportedFormat => Err(Self::UnsupportedFormat),
            ffi::FigStatus::InternalError => Err(Self::Internal),
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

impl Drop for Document {
    fn drop(&mut self) {
        unsafe {
            ffi::fig_document_destroy(self.raw.as_ptr());
        }
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
        assert_eq!(err, Error::Parse);
    }
}
