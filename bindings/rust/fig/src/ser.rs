//! A serde [`Serializer`] that builds a [`Value`] tree.
//!
//! Serialization is two thin steps: serde drives construction of a [`Value`],
//! then [`Value::serialize`](crate::Value::serialize) hands it to fig's core
//! serializer for emission.

use serde::{Serialize, Serializer, ser};

use crate::Format;
use crate::error::Error;
use crate::value::Value;

/// Build a [`Value`] from any `Serialize` type.
pub fn to_value<T: Serialize + ?Sized>(value: &T) -> Result<Value, Error> {
    value.serialize(ValueSerializer)
}

/// Serialize a value to a YAML string (the default format the bindings emit;
/// other formats go through [`crate::Value::serialize`]).
pub fn to_string<T: Serialize + ?Sized>(value: &T) -> Result<String, Error> {
    to_value(value)?.serialize(Format::Yaml)
}

struct ValueSerializer;

impl Serializer for ValueSerializer {
    type Ok = Value;
    type Error = Error;

    type SerializeSeq = SerializeSeq;
    type SerializeTuple = SerializeSeq;
    type SerializeTupleStruct = SerializeSeq;
    type SerializeTupleVariant = SerializeTupleVariant;
    type SerializeMap = SerializeMap;
    type SerializeStruct = SerializeMap;
    type SerializeStructVariant = SerializeStructVariant;

    fn serialize_bool(self, v: bool) -> Result<Value, Error> {
        Ok(Value::Bool(v))
    }
    fn serialize_i8(self, v: i8) -> Result<Value, Error> {
        Ok(Value::Int(v as i64))
    }
    fn serialize_i16(self, v: i16) -> Result<Value, Error> {
        Ok(Value::Int(v as i64))
    }
    fn serialize_i32(self, v: i32) -> Result<Value, Error> {
        Ok(Value::Int(v as i64))
    }
    fn serialize_i64(self, v: i64) -> Result<Value, Error> {
        Ok(Value::Int(v))
    }
    fn serialize_i128(self, v: i128) -> Result<Value, Error> {
        // No native i128; fall back to a string if it overflows i64/u64.
        if let Ok(i) = i64::try_from(v) {
            Ok(Value::Int(i))
        } else if let Ok(u) = u64::try_from(v) {
            Ok(Value::Uint(u))
        } else {
            Ok(Value::Str(v.to_string()))
        }
    }
    fn serialize_u8(self, v: u8) -> Result<Value, Error> {
        Ok(Value::Uint(v as u64))
    }
    fn serialize_u16(self, v: u16) -> Result<Value, Error> {
        Ok(Value::Uint(v as u64))
    }
    fn serialize_u32(self, v: u32) -> Result<Value, Error> {
        Ok(Value::Uint(v as u64))
    }
    fn serialize_u64(self, v: u64) -> Result<Value, Error> {
        Ok(Value::Uint(v))
    }
    fn serialize_u128(self, v: u128) -> Result<Value, Error> {
        if let Ok(u) = u64::try_from(v) {
            Ok(Value::Uint(u))
        } else {
            Ok(Value::Str(v.to_string()))
        }
    }
    fn serialize_f32(self, v: f32) -> Result<Value, Error> {
        Ok(Value::Float(v as f64))
    }
    fn serialize_f64(self, v: f64) -> Result<Value, Error> {
        Ok(Value::Float(v))
    }
    fn serialize_char(self, v: char) -> Result<Value, Error> {
        Ok(Value::Str(v.to_string()))
    }
    fn serialize_str(self, v: &str) -> Result<Value, Error> {
        Ok(Value::Str(v.to_string()))
    }
    fn serialize_bytes(self, v: &[u8]) -> Result<Value, Error> {
        Ok(Value::Seq(
            v.iter().map(|b| Value::Uint(*b as u64)).collect(),
        ))
    }
    fn serialize_none(self) -> Result<Value, Error> {
        Ok(Value::Null)
    }
    fn serialize_some<T: ?Sized + Serialize>(self, value: &T) -> Result<Value, Error> {
        value.serialize(self)
    }
    fn serialize_unit(self) -> Result<Value, Error> {
        Ok(Value::Null)
    }
    fn serialize_unit_struct(self, _name: &'static str) -> Result<Value, Error> {
        Ok(Value::Null)
    }
    fn serialize_unit_variant(
        self,
        _name: &'static str,
        _index: u32,
        variant: &'static str,
    ) -> Result<Value, Error> {
        Ok(Value::Str(variant.to_string()))
    }
    fn serialize_newtype_struct<T: ?Sized + Serialize>(
        self,
        _name: &'static str,
        value: &T,
    ) -> Result<Value, Error> {
        value.serialize(self)
    }
    fn serialize_newtype_variant<T: ?Sized + Serialize>(
        self,
        _name: &'static str,
        _index: u32,
        variant: &'static str,
        value: &T,
    ) -> Result<Value, Error> {
        Ok(Value::Map(vec![(
            Value::Str(variant.to_string()),
            value.serialize(ValueSerializer)?,
        )]))
    }

    fn serialize_seq(self, len: Option<usize>) -> Result<SerializeSeq, Error> {
        Ok(SerializeSeq {
            items: Vec::with_capacity(len.unwrap_or(0)),
        })
    }
    fn serialize_tuple(self, len: usize) -> Result<SerializeSeq, Error> {
        self.serialize_seq(Some(len))
    }
    fn serialize_tuple_struct(
        self,
        _name: &'static str,
        len: usize,
    ) -> Result<SerializeSeq, Error> {
        self.serialize_seq(Some(len))
    }
    fn serialize_tuple_variant(
        self,
        _name: &'static str,
        _index: u32,
        variant: &'static str,
        len: usize,
    ) -> Result<SerializeTupleVariant, Error> {
        Ok(SerializeTupleVariant {
            variant,
            items: Vec::with_capacity(len),
        })
    }
    fn serialize_map(self, len: Option<usize>) -> Result<SerializeMap, Error> {
        Ok(SerializeMap {
            entries: Vec::with_capacity(len.unwrap_or(0)),
            next_key: None,
        })
    }
    fn serialize_struct(self, _name: &'static str, len: usize) -> Result<SerializeMap, Error> {
        self.serialize_map(Some(len))
    }
    fn serialize_struct_variant(
        self,
        _name: &'static str,
        _index: u32,
        variant: &'static str,
        len: usize,
    ) -> Result<SerializeStructVariant, Error> {
        Ok(SerializeStructVariant {
            variant,
            entries: Vec::with_capacity(len),
        })
    }
}

pub struct SerializeSeq {
    items: Vec<Value>,
}

impl ser::SerializeSeq for SerializeSeq {
    type Ok = Value;
    type Error = Error;
    fn serialize_element<T: ?Sized + Serialize>(&mut self, value: &T) -> Result<(), Error> {
        self.items.push(value.serialize(ValueSerializer)?);
        Ok(())
    }
    fn end(self) -> Result<Value, Error> {
        Ok(Value::Seq(self.items))
    }
}

impl ser::SerializeTuple for SerializeSeq {
    type Ok = Value;
    type Error = Error;
    fn serialize_element<T: ?Sized + Serialize>(&mut self, value: &T) -> Result<(), Error> {
        ser::SerializeSeq::serialize_element(self, value)
    }
    fn end(self) -> Result<Value, Error> {
        ser::SerializeSeq::end(self)
    }
}

impl ser::SerializeTupleStruct for SerializeSeq {
    type Ok = Value;
    type Error = Error;
    fn serialize_field<T: ?Sized + Serialize>(&mut self, value: &T) -> Result<(), Error> {
        ser::SerializeSeq::serialize_element(self, value)
    }
    fn end(self) -> Result<Value, Error> {
        ser::SerializeSeq::end(self)
    }
}

pub struct SerializeTupleVariant {
    variant: &'static str,
    items: Vec<Value>,
}

impl ser::SerializeTupleVariant for SerializeTupleVariant {
    type Ok = Value;
    type Error = Error;
    fn serialize_field<T: ?Sized + Serialize>(&mut self, value: &T) -> Result<(), Error> {
        self.items.push(value.serialize(ValueSerializer)?);
        Ok(())
    }
    fn end(self) -> Result<Value, Error> {
        Ok(Value::Map(vec![(
            Value::Str(self.variant.to_string()),
            Value::Seq(self.items),
        )]))
    }
}

pub struct SerializeMap {
    entries: Vec<(Value, Value)>,
    next_key: Option<Value>,
}

impl ser::SerializeMap for SerializeMap {
    type Ok = Value;
    type Error = Error;
    fn serialize_key<T: ?Sized + Serialize>(&mut self, key: &T) -> Result<(), Error> {
        self.next_key = Some(key.serialize(ValueSerializer)?);
        Ok(())
    }
    fn serialize_value<T: ?Sized + Serialize>(&mut self, value: &T) -> Result<(), Error> {
        let key = self
            .next_key
            .take()
            .ok_or_else(|| Error::Message("serialize_value called before serialize_key".into()))?;
        self.entries.push((key, value.serialize(ValueSerializer)?));
        Ok(())
    }
    fn end(self) -> Result<Value, Error> {
        Ok(Value::Map(self.entries))
    }
}

impl ser::SerializeStruct for SerializeMap {
    type Ok = Value;
    type Error = Error;
    fn serialize_field<T: ?Sized + Serialize>(
        &mut self,
        key: &'static str,
        value: &T,
    ) -> Result<(), Error> {
        self.entries.push((
            Value::Str(key.to_string()),
            value.serialize(ValueSerializer)?,
        ));
        Ok(())
    }
    fn end(self) -> Result<Value, Error> {
        Ok(Value::Map(self.entries))
    }
}

pub struct SerializeStructVariant {
    variant: &'static str,
    entries: Vec<(Value, Value)>,
}

impl ser::SerializeStructVariant for SerializeStructVariant {
    type Ok = Value;
    type Error = Error;
    fn serialize_field<T: ?Sized + Serialize>(
        &mut self,
        key: &'static str,
        value: &T,
    ) -> Result<(), Error> {
        self.entries.push((
            Value::Str(key.to_string()),
            value.serialize(ValueSerializer)?,
        ));
        Ok(())
    }
    fn end(self) -> Result<Value, Error> {
        Ok(Value::Map(vec![(
            Value::Str(self.variant.to_string()),
            Value::Map(self.entries),
        )]))
    }
}
