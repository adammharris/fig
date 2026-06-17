//! The non-serde value representation and its serializer.
//!
//! [`Value`] is an owned, format-independent tree mirroring fig's AST node
//! kinds. [`Value::serialize`] builds it through the C value API
//! (`fig_value_*`) and renders it with fig's core serializer — so the binding
//! carries no emitter of its own. With the `serde` feature, [`crate::to_string`]
//! and the editor's typed methods build a `Value` from any `Serialize` type
//! (see [`crate::ser`]); without it, callers construct `Value` directly.

use std::ptr::{self, NonNull};

use crate::error::Error;
use crate::ffi;
use crate::Format;

/// An owned, format-independent value tree.
#[derive(Clone, Debug, PartialEq)]
pub enum Value {
    Null,
    Bool(bool),
    Int(i64),
    Uint(u64),
    Float(f64),
    Str(String),
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

impl Value {
    /// Render to `format` via fig's core serializer. The value is built through
    /// the C value API and emitted by fig, so no JSON/YAML/TOML/ZON formatting
    /// happens in Rust.
    pub fn serialize(&self, format: Format) -> Result<String, Error> {
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
            ffi::fig_value_serialize(guard.0, root, ffi_format as i32, &mut ptr_out, &mut len)
        })?;

        // Safety: on success the ABI guarantees `len` bytes at `ptr_out`, owned
        // by the handle and valid until the next call / destroy. We copy out now.
        let bytes = if len == 0 {
            &[][..]
        } else {
            unsafe { std::slice::from_raw_parts(ptr_out, len) }
        };
        Ok(std::str::from_utf8(bytes).map_err(|_| Error::Utf8)?.to_owned())
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
    let mut s = value.serialize(format)?;
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
        use serde::de::{MapAccess, SeqAccess, Visitor};
        use serde::Deserialize; // for the recursive `Value::deserialize` in visit_some

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
                Ok(i64::try_from(v).map(Value::Int).unwrap_or(Value::Float(v as f64)))
            }
            fn visit_u128<E>(self, v: u128) -> Result<Value, E> {
                Ok(u64::try_from(v).map(Value::Uint).unwrap_or(Value::Float(v as f64)))
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
        assert_eq!(v.serialize(Format::Yaml).unwrap(), "name: fig\nnums:\n- 1\n- 2\n");
        assert_eq!(
            v.serialize(Format::Json).unwrap(),
            "{\n  \"name\": \"fig\",\n  \"nums\": [\n    1,\n    2\n  ]\n}\n",
        );
    }

    #[test]
    fn quotes_and_round_trip_safe_strings() {
        // A colon-space scalar must be single-quoted to stay a string.
        assert_eq!(Value::Str("a: b".into()).serialize(Format::Yaml).unwrap(), "'a: b'\n");
        // A multi-line string *value* becomes a `|` block scalar (a bare root
        // scalar is double-quoted instead, having no containing line to indent).
        let v = Value::Map(vec![(Value::Str("s".into()), Value::Str("multi\nline".into()))]);
        assert_eq!(v.serialize(Format::Yaml).unwrap(), "s: |-\n  multi\n  line\n");
    }

    #[test]
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
        let doc = Document::parse(b"title: Hi\nnums:\n- 1\n- 2\nratio: 1.5\n", Format::Yaml).unwrap();
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
        assert_eq!(v.serialize(Format::Yaml).unwrap(), "title: Hi\nnums:\n- 1\n- 2\nratio: 1.5\n");
    }
}
