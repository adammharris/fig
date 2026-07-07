//! The non-serde value representation and its serializer.
//!
//! [`Value`] is an owned, format-independent tree mirroring fig's AST node
//! kinds. [`Value::serialize`] builds it through the C value API
//! (`fig_value_*`) and renders it with fig's core serializer — so the binding
//! carries no emitter of its own. With the `serde` feature, [`crate::to_string`]
//! and the editor's typed methods build a `Value` from any `Serialize` type
//! (see [`crate::ser`]); without it, callers construct `Value` directly.

use std::os::raw::c_int;
use std::ptr::{self, NonNull};

use crate::{Format, SerializeOptions};
use crate::error::Error;
use crate::ffi;

/// The kind of a format-specific [`Value::Extended`] scalar. Mirrors the core's
/// `ExtKind` and the C ABI's `FigExtKind`; the discriminants match that ABI.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ExtKind {
    /// TOML offset date-time, e.g. `1979-05-27T07:32:00Z`.
    OffsetDateTime,
    /// TOML local date-time, e.g. `1979-05-27T07:32:00`.
    LocalDateTime,
    /// TOML local date, e.g. `1979-05-27`.
    LocalDate,
    /// TOML local time, e.g. `07:32:00`.
    LocalTime,
    /// ZON enum literal, e.g. `.foo` (text is the bare name, without the dot).
    EnumLiteral,
    /// ZON character literal, e.g. `'a'` (text is the decimal codepoint).
    CharLiteral,
    /// A non-finite JSON5 number (`Infinity`/`-Infinity`/`NaN`); text is the
    /// literal as written.
    NumberSpecial,
}

impl ExtKind {
    /// The C ABI enumerator (`FigExtKind`) for this kind.
    fn to_c(self) -> c_int {
        match self {
            ExtKind::OffsetDateTime => 0,
            ExtKind::LocalDateTime => 1,
            ExtKind::LocalDate => 2,
            ExtKind::LocalTime => 3,
            ExtKind::EnumLiteral => 4,
            ExtKind::CharLiteral => 5,
            ExtKind::NumberSpecial => 6,
        }
    }

    /// Map a C ABI `FigExtKind` back to an [`ExtKind`], or `None` if unknown.
    pub(crate) fn from_c(kind: c_int) -> Option<Self> {
        Some(match kind {
            0 => ExtKind::OffsetDateTime,
            1 => ExtKind::LocalDateTime,
            2 => ExtKind::LocalDate,
            3 => ExtKind::LocalTime,
            4 => ExtKind::EnumLiteral,
            5 => ExtKind::CharLiteral,
            6 => ExtKind::NumberSpecial,
            _ => return None,
        })
    }
}

/// An owned, format-independent value tree.
#[derive(Clone, Debug, PartialEq)]
pub enum Value {
    Null,
    Bool(bool),
    Int(i64),
    Uint(u64),
    Float(f64),
    Str(String),
    /// A format-specific scalar (TOML datetime, ZON enum/char literal) carried
    /// verbatim. Produced by [`crate::Document::to_value`] when reading TOML/ZON,
    /// and rendered back by [`Value::serialize`]. The serde path instead reads
    /// these as plain strings/integers.
    Extended {
        kind: ExtKind,
        text: String,
    },
    Seq(Vec<Value>),
    /// Mapping entries, in order. Keys are conventionally strings; a non-string
    /// key serializes only to formats whose printer accepts one.
    Map(Vec<(Value, Value)>),
}

impl From<bool> for Value {
    fn from(v: bool) -> Self {
        Value::Bool(v)
    }
}
impl From<i64> for Value {
    fn from(v: i64) -> Self {
        Value::Int(v)
    }
}
impl From<i32> for Value {
    fn from(v: i32) -> Self {
        Value::Int(v as i64)
    }
}
impl From<u64> for Value {
    fn from(v: u64) -> Self {
        Value::Uint(v)
    }
}
impl From<f64> for Value {
    fn from(v: f64) -> Self {
        Value::Float(v)
    }
}
impl From<&str> for Value {
    fn from(v: &str) -> Self {
        Value::Str(v.to_owned())
    }
}
impl From<String> for Value {
    fn from(v: String) -> Self {
        Value::Str(v)
    }
}
impl From<Vec<Value>> for Value {
    fn from(v: Vec<Value>) -> Self {
        Value::Seq(v)
    }
}
/// Clone a borrowed value into an owned one. This is what lets a `&Value` still
/// satisfy the `impl Into<Value>` value parameters on the editor/embed methods
/// (pass an owned `Value` instead to move rather than clone).
impl From<&Value> for Value {
    fn from(v: &Value) -> Self {
        v.clone()
    }
}

impl Value {
    /// Render to `format` via fig's core serializer, using default output style.
    /// The value is built through the C value API and emitted by fig, so no
    /// JSON/YAML/TOML/ZON formatting happens in Rust.
    pub fn serialize(&self, format: Format) -> Result<String, Error> {
        self.serialize_with(format, SerializeOptions::default())
    }

    /// Render to `format`, with `options` controlling output style such as
    /// compact vs. pretty-printed JSON.
    pub fn serialize_with(&self, format: Format, options: SerializeOptions) -> Result<String, Error> {
        self.serialize_ffi(format, options.into())
    }

    /// The raw-options serialize path. Exists so crate-internal callers (the
    /// editors' `value_text`) can set ABI-level options that the public
    /// [`SerializeOptions`] deliberately does not expose (`flow` — inline is a
    /// property of where the text is spliced, not a caller style preference).
    pub(crate) fn serialize_ffi(
        &self,
        format: Format,
        ffi_options: ffi::FigSerializeOptions,
    ) -> Result<String, Error> {
        let mut raw = ptr::null_mut();
        // Safety: `raw` is a valid out-pointer; create sets it or returns non-ok.
        Error::from_status(unsafe { ffi::fig_value_create(&mut raw) })?;
        NonNull::new(raw).ok_or(Error::Internal)?;
        let guard = ValueGuard(raw);

        let root = build(guard.0, self)?;

        let mut ptr_out: *const u8 = ptr::null();
        let mut len: usize = 0;
        let ffi_format: ffi::FigFormat = format.into();
        Error::from_status(unsafe {
            ffi::fig_value_serialize_opts(
                guard.0,
                root,
                ffi_format as i32,
                &ffi_options,
                &mut ptr_out,
                &mut len,
            )
        })?;

        // Safety: on success the ABI guarantees `len` bytes at `ptr_out`, owned
        // by the handle and valid until the next call / destroy. We copy out now.
        let bytes = if len == 0 {
            &[][..]
        } else {
            unsafe { std::slice::from_raw_parts(ptr_out, len) }
        };
        Ok(std::str::from_utf8(bytes)
            .map_err(|_| Error::Utf8)?
            .to_owned())
    }

    /// Report what serializing this value to `format` would silently lose
    /// (values/comments dropped or degraded). The built value has no source
    /// envelopes, so `options.lossless` is ignored. Returns one [`crate::Warning`]
    /// per lossy event (empty if nothing is lost).
    pub fn diagnose(&self, format: Format, options: SerializeOptions) -> Result<Vec<crate::Warning>, Error> {
        let mut raw = ptr::null_mut();
        Error::from_status(unsafe { ffi::fig_value_create(&mut raw) })?;
        NonNull::new(raw).ok_or(Error::Internal)?;
        let guard = ValueGuard(raw);

        let root = build(guard.0, self)?;
        let ffi_format: ffi::FigFormat = format.into();
        let ffi_options: ffi::FigSerializeOptions = options.into();
        let mut count: usize = 0;
        Error::from_status(unsafe {
            ffi::fig_value_diagnose(guard.0, root, ffi_format as c_int, &ffi_options, &mut count)
        })?;
        let mut out = Vec::with_capacity(count);
        for i in 0..count {
            let mut w = ffi::FigWarning::new();
            Error::from_status(unsafe { ffi::fig_value_warning(guard.0, i, &mut w) })?;
            // Safety: on `OK`, `w` is filled with borrowed path/note bytes valid
            // until the next diagnose on this handle (which we don't call before
            // copying them out here) or its destroy.
            out.push(unsafe { crate::Warning::from_ffi(&w) });
        }
        Ok(out)
    }
}

/// Destroys the value handle on drop, so an early `?` return can't leak it.
struct ValueGuard(*mut ffi::FigValue);

impl Drop for ValueGuard {
    fn drop(&mut self) {
        unsafe { ffi::fig_value_destroy(self.0) };
    }
}

/// Build `value` into the handle bottom-up (children before their container),
/// returning the new root node's id.
fn build(handle: *mut ffi::FigValue, value: &Value) -> Result<ffi::FigNodeId, Error> {
    let mut id: ffi::FigNodeId = 0;
    // Safety: `handle` is a live value handle; the out-id is valid; child ids
    // passed to seq/map were returned by earlier builds on this same handle.
    let status = unsafe {
        match value {
            Value::Null => ffi::fig_value_null(handle, &mut id),
            Value::Bool(b) => ffi::fig_value_bool(handle, *b, &mut id),
            Value::Int(n) => ffi::fig_value_int(handle, *n, &mut id),
            Value::Uint(n) => ffi::fig_value_uint(handle, *n, &mut id),
            Value::Float(f) => {
                let text = format_float(*f);
                ffi::fig_value_number(handle, text.as_ptr(), text.len(), true, &mut id)
            }
            Value::Str(s) => ffi::fig_value_string(handle, s.as_ptr(), s.len(), &mut id),
            Value::Extended { kind, text } => {
                ffi::fig_value_extended(handle, kind.to_c(), text.as_ptr(), text.len(), &mut id)
            }
            Value::Seq(items) => {
                let ids = items
                    .iter()
                    .map(|it| build(handle, it))
                    .collect::<Result<Vec<_>, _>>()?;
                ffi::fig_value_seq(handle, ids.as_ptr(), ids.len(), &mut id)
            }
            Value::Map(entries) => {
                let kvs = entries
                    .iter()
                    .map(|(k, v)| {
                        Ok(ffi::FigKeyValue {
                            key: build(handle, k)?,
                            value: build(handle, v)?,
                        })
                    })
                    .collect::<Result<Vec<_>, Error>>()?;
                ffi::fig_value_map(handle, kvs.as_ptr(), kvs.len(), &mut id)
            }
        }
    };
    Error::from_status(status)?;
    Ok(id)
}

/// The splice text for an editor value: the value rendered in `format`, minus
/// the trailing newline the serializer appends (the editor owns newline
/// framing).
pub(crate) fn value_text(value: &Value, format: Format) -> Result<String, Error> {
    // The text is spliced inline (`key = <text>`), so for the fig dialect a
    // container must render as flow — its block spelling (`* ` element lines,
    // section headers) only parses as standalone lines and would re-read as a
    // bare string after the splice. Other formats keep their defaults: their
    // block spellings splice correctly (YAML) or don't arise.
    let mut ffi_options: crate::ffi::FigSerializeOptions = SerializeOptions::default().into();
    if format == Format::Fig {
        ffi_options.flow = 1;
    }
    let mut s = value.serialize_ffi(format, ffi_options)?;
    if s.ends_with('\n') {
        s.pop();
    }
    Ok(s)
}

/// Render `value` as splice text honoring `options` — the "width knob" path
/// behind the `*_with` editor/embed methods.
///
/// Unlike [`value_text`], the fig dialect's inline-flow override is NOT forced:
/// a container renders in its natural, width-driven layout, so a block map or
/// sequence spells as a section body (`a = 1` / `* x` lines) instead of freezing
/// inline as flow (`{ a = 1 }`). The core editor re-frames such a block value
/// under the target key (adding the marker run), which the plain inline splice
/// cannot express. `options.width` then tunes how eagerly nested containers
/// break to block. Non-fig formats are unaffected by the flow bit and simply
/// honor `options` as usual.
pub(crate) fn value_text_with(
    value: &Value,
    format: Format,
    options: SerializeOptions,
) -> Result<String, Error> {
    let ffi_options: crate::ffi::FigSerializeOptions = options.into(); // flow = 0
    let mut s = value.serialize_ffi(format, ffi_options)?;
    if s.ends_with('\n') {
        s.pop();
    }
    Ok(s)
}

/// Parse a numeric scalar's raw text into a `Value`, classifying by `is_float`
/// (the node's kind). Integers try `i64` then `u64`, falling back to float when
/// out of range, matching how the serde deserializer widens.
pub(crate) fn number_from_raw(raw: &str, is_float: bool) -> Result<Value, Error> {
    if !is_float {
        if let Ok(i) = raw.parse::<i64>() {
            return Ok(Value::Int(i));
        }
        if let Ok(u) = raw.parse::<u64>() {
            return Ok(Value::Uint(u));
        }
    }
    parse_yaml_float(raw)
        .map(Value::Float)
        .ok_or_else(|| Error::Number(raw.to_owned()))
}

/// Parse a float, including the YAML special values (`​.inf`/`.nan`) that Rust's
/// `f64::from_str` rejects.
pub(crate) fn parse_yaml_float(raw: &str) -> Option<f64> {
    match raw {
        ".inf" | ".Inf" | ".INF" | "+.inf" | "+.Inf" | "+.INF" => Some(f64::INFINITY),
        "-.inf" | "-.Inf" | "-.INF" => Some(f64::NEG_INFINITY),
        ".nan" | ".NaN" | ".NAN" => Some(f64::NAN),
        _ => raw.parse::<f64>().ok(),
    }
}

/// Format a float as the text fig stores in `number.raw`: YAML's `.inf`/`.nan`
/// for the specials, and a trailing `.0` so an integral value still reads back
/// as a float. (fig's value API takes float text rather than a `double`, so the
/// canonical formatting lives here until a typed float entry point is added.)
fn format_float(f: f64) -> String {
    if f.is_nan() {
        return ".nan".to_string();
    }
    if f.is_infinite() {
        return if f < 0.0 { "-.inf" } else { ".inf" }.to_string();
    }
    let s = f.to_string();
    // Ensure the value reads back as a float, not an integer.
    if s.bytes().all(|b| b.is_ascii_digit() || b == b'-') {
        format!("{s}.0")
    } else {
        s
    }
}

/// Deserialize into a dynamic `Value` — the read-side mirror of the inherent
/// `Value::serialize`. Lets `from_str::<Value>` build a value tree without a
/// concrete target type (the way `serde_json::Value` is used generically).
#[cfg(feature = "serde")]
impl<'de> serde::Deserialize<'de> for Value {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        use serde::Deserialize;
        use serde::de::{MapAccess, SeqAccess, Visitor}; // for the recursive `Value::deserialize` in visit_some

        struct ValueVisitor;

        impl<'de> Visitor<'de> for ValueVisitor {
            type Value = Value;

            fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
                f.write_str("any fig value")
            }

            fn visit_bool<E>(self, v: bool) -> Result<Value, E> {
                Ok(Value::Bool(v))
            }
            fn visit_i64<E>(self, v: i64) -> Result<Value, E> {
                Ok(Value::Int(v))
            }
            fn visit_u64<E>(self, v: u64) -> Result<Value, E> {
                Ok(Value::Uint(v))
            }
            fn visit_i128<E>(self, v: i128) -> Result<Value, E> {
                Ok(i64::try_from(v)
                    .map(Value::Int)
                    .unwrap_or(Value::Float(v as f64)))
            }
            fn visit_u128<E>(self, v: u128) -> Result<Value, E> {
                Ok(u64::try_from(v)
                    .map(Value::Uint)
                    .unwrap_or(Value::Float(v as f64)))
            }
            fn visit_f64<E>(self, v: f64) -> Result<Value, E> {
                Ok(Value::Float(v))
            }
            fn visit_str<E>(self, v: &str) -> Result<Value, E> {
                Ok(Value::Str(v.to_owned()))
            }
            fn visit_string<E>(self, v: String) -> Result<Value, E> {
                Ok(Value::Str(v))
            }
            fn visit_unit<E>(self) -> Result<Value, E> {
                Ok(Value::Null)
            }
            fn visit_none<E>(self) -> Result<Value, E> {
                Ok(Value::Null)
            }
            fn visit_some<D: serde::Deserializer<'de>>(self, d: D) -> Result<Value, D::Error> {
                Value::deserialize(d)
            }
            fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Value, A::Error> {
                let mut items = Vec::new();
                while let Some(e) = seq.next_element::<Value>()? {
                    items.push(e);
                }
                Ok(Value::Seq(items))
            }
            fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Value, A::Error> {
                let mut entries = Vec::new();
                while let Some((k, v)) = map.next_entry::<Value, Value>()? {
                    entries.push((k, v));
                }
                Ok(Value::Map(entries))
            }
        }

        deserializer.deserialize_any(ValueVisitor)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Exercises the whole build+serialize path with no serde involvement, so it
    // runs under `--no-default-features` too.
    #[test]
    fn builds_and_serializes_to_multiple_formats() {
        let v = Value::Map(vec![
            (Value::Str("name".into()), Value::Str("fig".into())),
            (
                Value::Str("nums".into()),
                Value::Seq(vec![Value::Int(1), Value::Int(2)]),
            ),
        ]);
        assert_eq!(
            v.serialize(Format::Yaml).unwrap(),
            "name: fig\nnums: [1, 2]\n"
        );
        assert_eq!(
            v.serialize(Format::Json).unwrap(),
            "{\n  \"name\": \"fig\",\n  \"nums\": [\n    1,\n    2\n  ]\n}\n",
        );
    }

    #[test]
    fn quotes_and_round_trip_safe_strings() {
        // A colon-space scalar must be single-quoted to stay a string.
        assert_eq!(
            Value::Str("a: b".into()).serialize(Format::Yaml).unwrap(),
            "'a: b'\n"
        );
        // A multi-line string *value* becomes a `|` block scalar (a bare root
        // scalar is double-quoted instead, having no containing line to indent).
        let v = Value::Map(vec![(
            Value::Str("s".into()),
            Value::Str("multi\nline".into()),
        )]);
        assert_eq!(
            v.serialize(Format::Yaml).unwrap(),
            "s: |-\n  multi\n  line\n"
        );
    }

    #[test]
    #[cfg(feature = "toml")]
    fn null_value_is_unsupported_in_toml() {
        let v = Value::Map(vec![(Value::Str("k".into()), Value::Null)]);
        assert!(matches!(
            v.serialize(Format::Toml),
            Err(Error::UnsupportedFormat)
        ));
    }

    // The non-serde read path: parse → to_value → serialize round-trips.
    #[test]
    fn document_reads_into_value() {
        use crate::{Document, Format};
        let doc =
            Document::parse(b"title: Hi\nnums:\n- 1\n- 2\nratio: 1.5\n", Format::Yaml).unwrap();
        let v = doc.to_value().unwrap();
        assert_eq!(
            v,
            Value::Map(vec![
                ("title".into(), "Hi".into()),
                ("nums".into(), Value::Seq(vec![1i64.into(), 2i64.into()])),
                ("ratio".into(), 1.5.into()),
            ]),
        );
        // round-trips back out through serialize
        assert_eq!(
            v.serialize(Format::Yaml).unwrap(),
            "title: Hi\nnums: [1, 2]\nratio: 1.5\n"
        );
    }

    // TOML datetimes read into `Value::Extended` and serialize back verbatim,
    // instead of degrading to strings.
    #[test]
    #[cfg(feature = "toml")]
    fn toml_datetimes_round_trip_as_extended() {
        use crate::{Document, ExtKind, Format};
        let src = "d = 2026-06-18\nt = 07:32:00\n";
        let v = Document::parse(src.as_bytes(), Format::Toml)
            .unwrap()
            .to_value()
            .unwrap();
        assert_eq!(
            v,
            Value::Map(vec![
                (
                    "d".into(),
                    Value::Extended {
                        kind: ExtKind::LocalDate,
                        text: "2026-06-18".into()
                    }
                ),
                (
                    "t".into(),
                    Value::Extended {
                        kind: ExtKind::LocalTime,
                        text: "07:32:00".into()
                    }
                ),
            ])
        );
        assert_eq!(v.serialize(Format::Toml).unwrap(), src);
    }

    // ZON enum and char literals read into `Value::Extended` (the char literal
    // surfaces as an `int` kind at the ABI, but is recovered faithfully).
    #[test]
    #[cfg(feature = "zon")]
    fn zon_literals_round_trip_as_extended() {
        use crate::{Document, ExtKind, Format};
        let v = Document::parse(b".{ .mode = .fast, .c = 'a' }", Format::Zon)
            .unwrap()
            .to_value()
            .unwrap();
        assert_eq!(
            v,
            Value::Map(vec![
                (
                    "mode".into(),
                    Value::Extended {
                        kind: ExtKind::EnumLiteral,
                        text: "fast".into()
                    }
                ),
                (
                    "c".into(),
                    Value::Extended {
                        kind: ExtKind::CharLiteral,
                        text: "97".into()
                    }
                ),
            ])
        );
    }

    // A built datetime degrades to a string in JSON → one type-degraded warning.
    #[test]
    fn value_diagnose_reports_degraded_datetime() {
        use crate::{Format, SerializeOptions, WarningCode};
        let v = Value::Map(vec![(
            "when".into(),
            Value::Extended {
                kind: ExtKind::OffsetDateTime,
                text: "1979-05-27T07:32:00Z".into(),
            },
        )]);
        let warns = v.diagnose(Format::Json, SerializeOptions::default()).unwrap();
        assert_eq!(warns.len(), 1);
        assert_eq!(warns[0].code, WarningCode::TypeDegraded);
        assert_eq!(warns[0].path, "when");
        assert_eq!(warns[0].note, "string");
    }

    // A directly-constructed extended value serializes via the existing write ABI.
    #[test]
    #[cfg(feature = "toml")]
    fn constructed_extended_serializes() {
        let v = Value::Map(vec![(
            "when".into(),
            Value::Extended {
                kind: ExtKind::OffsetDateTime,
                text: "1979-05-27T07:32:00Z".into(),
            },
        )]);
        assert_eq!(
            v.serialize(Format::Toml).unwrap(),
            "when = 1979-05-27T07:32:00Z\n"
        );
    }
}
