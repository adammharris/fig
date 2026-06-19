//! Typed conversions to and from the [`Value`] tree, used by the `derive`
//! feature.
//!
//! Unlike the serde path ([`crate::ser`]/[`crate::de`]), these traits target the
//! concrete [`Value`] enum directly. The `#[derive(ToValue, FromValue)]` macros
//! (re-exported from `fig-macros`) generate straight-line field extraction with
//! no format-generic machinery behind it, so the emitted code is small.
//!
//! This module is independent of the `serde` feature: it only touches [`Value`]
//! and [`Error`].

use std::collections::{BTreeMap, HashMap};

use crate::error::Error;
use crate::value::Value;

/// Convert a typed value into a [`Value`] tree. Infallible by construction.
pub trait ToValue {
    fn to_value(&self) -> Value;
}

/// Build a typed value from a [`Value`] tree, reporting structural mismatches
/// (wrong kind, missing field, out-of-range integer) as [`Error::Message`].
pub trait FromValue: Sized {
    fn from_value(value: &Value) -> Result<Self, Error>;
}

/// The format-independent "kind" of a value, for error messages.
fn kind_of(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Bool(_) => "bool",
        Value::Int(_) | Value::Uint(_) => "integer",
        Value::Float(_) => "float",
        Value::Str(_) => "string",
        Value::Extended { .. } => "extended scalar",
        Value::Seq(_) => "sequence",
        Value::Map(_) => "mapping",
    }
}

/// A "wrong kind" error, e.g. expected a string but found a sequence.
fn type_err(expected: &str, found: &Value) -> Error {
    Error::Message(format!("expected {expected}, found {}", kind_of(found)))
}

/// Look up `name` in a mapping's entries, last-wins (so later duplicate keys
/// shadow earlier ones, matching how object literals are usually read).
///
/// Used by `#[derive(FromValue)]`: the generated code calls this shared function
/// instead of emitting its own lookup closure per field/variant, which keeps the
/// derived code small for large structs and many-variant enums.
#[doc(hidden)]
pub fn map_get<'a>(entries: &'a [(Value, Value)], name: &str) -> Option<&'a Value> {
    entries.iter().rev().find_map(|(k, v)| match k {
        Value::Str(s) if s == name => Some(v),
        _ => None,
    })
}

// --- Passthrough --------------------------------------------------------------

impl ToValue for Value {
    fn to_value(&self) -> Value {
        self.clone()
    }
}
impl FromValue for Value {
    fn from_value(value: &Value) -> Result<Self, Error> {
        Ok(value.clone())
    }
}

// --- References ---------------------------------------------------------------

impl<T: ToValue + ?Sized> ToValue for &T {
    fn to_value(&self) -> Value {
        (**self).to_value()
    }
}
impl<T: ToValue + ?Sized> ToValue for Box<T> {
    fn to_value(&self) -> Value {
        (**self).to_value()
    }
}
impl<T: FromValue> FromValue for Box<T> {
    fn from_value(value: &Value) -> Result<Self, Error> {
        T::from_value(value).map(Box::new)
    }
}

// --- Bool ---------------------------------------------------------------------

impl ToValue for bool {
    fn to_value(&self) -> Value {
        Value::Bool(*self)
    }
}
impl FromValue for bool {
    fn from_value(value: &Value) -> Result<Self, Error> {
        match value {
            Value::Bool(b) => Ok(*b),
            other => Err(type_err("bool", other)),
        }
    }
}

// --- Integers -----------------------------------------------------------------

macro_rules! signed_to_value {
    ($($t:ty),*) => {$(
        impl ToValue for $t {
            fn to_value(&self) -> Value { Value::Int(*self as i64) }
        }
    )*};
}
macro_rules! unsigned_to_value {
    ($($t:ty),*) => {$(
        impl ToValue for $t {
            fn to_value(&self) -> Value { Value::Uint(*self as u64) }
        }
    )*};
}
signed_to_value!(i8, i16, i32, i64, isize);
unsigned_to_value!(u8, u16, u32, u64, usize);

/// Widen any integer-bearing value to `i128` so a single `try_from` can
/// range-check every concrete integer type.
fn as_i128(value: &Value) -> Option<i128> {
    match value {
        Value::Int(i) => Some(*i as i128),
        Value::Uint(u) => Some(*u as i128),
        _ => None,
    }
}

macro_rules! int_from_value {
    ($($t:ty),*) => {$(
        impl FromValue for $t {
            fn from_value(value: &Value) -> Result<Self, Error> {
                let n = as_i128(value).ok_or_else(|| type_err("integer", value))?;
                <$t>::try_from(n).map_err(|_| {
                    Error::Message(format!("{n} is out of range for {}", stringify!($t)))
                })
            }
        }
    )*};
}
int_from_value!(i8, i16, i32, i64, isize, u8, u16, u32, u64, usize);

// --- Floats -------------------------------------------------------------------

impl ToValue for f64 {
    fn to_value(&self) -> Value {
        Value::Float(*self)
    }
}
impl ToValue for f32 {
    fn to_value(&self) -> Value {
        Value::Float(*self as f64)
    }
}
impl FromValue for f64 {
    fn from_value(value: &Value) -> Result<Self, Error> {
        match value {
            Value::Float(f) => Ok(*f),
            Value::Int(i) => Ok(*i as f64),
            Value::Uint(u) => Ok(*u as f64),
            other => Err(type_err("float", other)),
        }
    }
}
impl FromValue for f32 {
    fn from_value(value: &Value) -> Result<Self, Error> {
        f64::from_value(value).map(|f| f as f32)
    }
}

// --- Strings ------------------------------------------------------------------

impl ToValue for str {
    fn to_value(&self) -> Value {
        Value::Str(self.to_owned())
    }
}
impl ToValue for String {
    fn to_value(&self) -> Value {
        Value::Str(self.clone())
    }
}
impl FromValue for String {
    fn from_value(value: &Value) -> Result<Self, Error> {
        match value {
            Value::Str(s) => Ok(s.clone()),
            other => Err(type_err("string", other)),
        }
    }
}

// --- Char ---------------------------------------------------------------------
// Chars travel as single-character strings (matching serde).

impl ToValue for char {
    fn to_value(&self) -> Value {
        Value::Str(self.to_string())
    }
}
impl FromValue for char {
    fn from_value(value: &Value) -> Result<Self, Error> {
        match value {
            Value::Str(s) => {
                let mut chars = s.chars();
                match (chars.next(), chars.next()) {
                    (Some(c), None) => Ok(c),
                    _ => Err(Error::Message(format!(
                        "expected a single-character string, found {s:?}"
                    ))),
                }
            }
            other => Err(type_err("char (single-character string)", other)),
        }
    }
}

// --- Paths --------------------------------------------------------------------
// Paths travel as strings (matching serde). `ToValue` is lossy for non-UTF-8
// paths; `FromValue` accepts any string.

impl ToValue for std::path::Path {
    fn to_value(&self) -> Value {
        Value::Str(self.to_string_lossy().into_owned())
    }
}
impl ToValue for std::path::PathBuf {
    fn to_value(&self) -> Value {
        self.as_path().to_value()
    }
}
impl FromValue for std::path::PathBuf {
    fn from_value(value: &Value) -> Result<Self, Error> {
        match value {
            Value::Str(s) => Ok(std::path::PathBuf::from(s)),
            other => Err(type_err("string (path)", other)),
        }
    }
}

// --- Option -------------------------------------------------------------------

impl<T: ToValue> ToValue for Option<T> {
    fn to_value(&self) -> Value {
        match self {
            Some(t) => t.to_value(),
            None => Value::Null,
        }
    }
}
impl<T: FromValue> FromValue for Option<T> {
    fn from_value(value: &Value) -> Result<Self, Error> {
        match value {
            Value::Null => Ok(None),
            other => Ok(Some(T::from_value(other)?)),
        }
    }
}

// --- Sequences ----------------------------------------------------------------

impl<T: ToValue> ToValue for [T] {
    fn to_value(&self) -> Value {
        Value::Seq(self.iter().map(ToValue::to_value).collect())
    }
}
impl<T: ToValue> ToValue for Vec<T> {
    fn to_value(&self) -> Value {
        Value::Seq(self.iter().map(ToValue::to_value).collect())
    }
}
impl<T: FromValue> FromValue for Vec<T> {
    fn from_value(value: &Value) -> Result<Self, Error> {
        match value {
            Value::Seq(items) => items.iter().map(T::from_value).collect(),
            other => Err(type_err("sequence", other)),
        }
    }
}

// --- Maps ---------------------------------------------------------------------

macro_rules! string_map_impls {
    ($($map:ident),*) => {$(
        impl<T: ToValue> ToValue for $map<String, T> {
            fn to_value(&self) -> Value {
                Value::Map(
                    self.iter()
                        .map(|(k, v)| (Value::Str(k.clone()), v.to_value()))
                        .collect(),
                )
            }
        }
        impl<T: FromValue> FromValue for $map<String, T> {
            fn from_value(value: &Value) -> Result<Self, Error> {
                match value {
                    Value::Map(entries) => {
                        let mut out = $map::new();
                        for (k, v) in entries {
                            let key = match k {
                                Value::Str(s) => s.clone(),
                                other => {
                                    return Err(Error::Message(format!(
                                        "map key must be a string, found {}",
                                        kind_of(other)
                                    )));
                                }
                            };
                            out.insert(key, T::from_value(v)?);
                        }
                        Ok(out)
                    }
                    other => Err(type_err("mapping", other)),
                }
            }
        }
    )*};
}
string_map_impls!(BTreeMap, HashMap);

// `IndexMap` keeps insertion order — important for round-tripping frontmatter.
// Gated behind the `indexmap` feature so the dependency is opt-in.
#[cfg(feature = "indexmap")]
use indexmap::IndexMap;
#[cfg(feature = "indexmap")]
string_map_impls!(IndexMap);
