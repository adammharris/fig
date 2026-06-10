//! A serde [`Deserializer`] over a parsed fig document.
//!
//! Walks the node graph exposed by the traversal C ABI directly, with no
//! intermediate value type. `id == None` means "no node", which we treat as
//! YAML null (e.g. an empty document, or a missing mapping value).

use serde::de::{
    self, DeserializeOwned, DeserializeSeed, EnumAccess, VariantAccess, Visitor,
};
use serde::forward_to_deserialize_any;
use serde::Deserializer;

use crate::error::Error;
use crate::ffi::{FigNodeId, FigNodeKind};
use crate::{Document, Format};

/// Deserialize a YAML string into a typed value.
pub fn from_str<T: DeserializeOwned>(s: &str) -> Result<T, Error> {
    let doc = Document::parse(s.as_bytes(), Format::Yaml)?;
    let de = NodeDeserializer {
        doc: &doc,
        id: doc.root(),
    };
    T::deserialize(de)
}

struct NodeDeserializer<'a> {
    doc: &'a Document,
    /// `None` means "no node" → null.
    id: Option<FigNodeId>,
}

impl<'a> NodeDeserializer<'a> {
    fn number_raw(&self, id: FigNodeId) -> Result<&'a str, Error> {
        self.doc.number_raw(id).ok_or(Error::Internal)?
    }

    fn str_value(&self, id: FigNodeId) -> Result<&'a str, Error> {
        self.doc.get_str(id).ok_or(Error::Internal)?
    }
}

impl<'de, 'a> Deserializer<'de> for NodeDeserializer<'a> {
    type Error = Error;

    fn deserialize_any<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value, Error> {
        let id = match self.id {
            None => return visitor.visit_unit(),
            Some(id) => id,
        };
        match self.doc.kind(id) {
            FigNodeKind::Null => visitor.visit_unit(),
            FigNodeKind::Bool => visitor.visit_bool(self.doc.get_bool(id).ok_or(Error::Internal)?),
            FigNodeKind::Int => visit_int(self.number_raw(id)?, visitor),
            FigNodeKind::Float => {
                let raw = self.number_raw(id)?;
                let f = parse_float(raw).ok_or_else(|| Error::Number(raw.to_string()))?;
                visitor.visit_f64(f)
            }
            FigNodeKind::String => visitor.visit_str(self.str_value(id)?),
            FigNodeKind::Sequence => visitor.visit_seq(SeqAccess::new(self.doc, id)),
            FigNodeKind::Mapping => visitor.visit_map(MapAccess::new(self.doc, id)),
            FigNodeKind::Keyvalue | FigNodeKind::Invalid => {
                Err(Error::Message("malformed document".into()))
            }
        }
    }

    fn deserialize_option<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value, Error> {
        match self.id {
            None => visitor.visit_none(),
            Some(id) if self.doc.kind(id) == FigNodeKind::Null => visitor.visit_none(),
            _ => visitor.visit_some(self),
        }
    }

    fn deserialize_newtype_struct<V: Visitor<'de>>(
        self,
        _name: &'static str,
        visitor: V,
    ) -> Result<V::Value, Error> {
        visitor.visit_newtype_struct(self)
    }

    fn deserialize_enum<V: Visitor<'de>>(
        self,
        _name: &'static str,
        _variants: &'static [&'static str],
        visitor: V,
    ) -> Result<V::Value, Error> {
        let id = self
            .id
            .ok_or_else(|| Error::Message("expected an enum, found null".into()))?;
        match self.doc.kind(id) {
            // Unit variant: a bare string.
            FigNodeKind::String => {
                let variant = self.str_value(id)?;
                visitor.visit_enum(EnumRef {
                    doc: self.doc,
                    variant,
                    value: None,
                })
            }
            // Data variant: a single-entry mapping `{ variant: value }`.
            FigNodeKind::Mapping => {
                let kv = self
                    .doc
                    .first_child(id)
                    .ok_or_else(|| Error::Message("expected a single-key mapping".into()))?;
                if self.doc.next_sibling(kv).is_some() {
                    return Err(Error::Message(
                        "expected a single-key mapping for enum".into(),
                    ));
                }
                let key = self
                    .doc
                    .kv_key(kv)
                    .ok_or_else(|| Error::Message("enum mapping has no key".into()))?;
                let variant = self.str_value(key)?;
                visitor.visit_enum(EnumRef {
                    doc: self.doc,
                    variant,
                    value: self.doc.kv_value(kv),
                })
            }
            _ => Err(Error::Message("expected a string or mapping for enum".into())),
        }
    }

    forward_to_deserialize_any! {
        bool i8 i16 i32 i64 i128 u8 u16 u32 u64 u128 f32 f64 char str string
        bytes byte_buf unit unit_struct seq tuple tuple_struct map struct
        identifier ignored_any
    }
}

fn visit_int<'de, V: Visitor<'de>>(raw: &str, visitor: V) -> Result<V::Value, Error> {
    if let Ok(i) = raw.parse::<i64>() {
        visitor.visit_i64(i)
    } else if let Ok(u) = raw.parse::<u64>() {
        visitor.visit_u64(u)
    } else if let Ok(i) = raw.parse::<i128>() {
        visitor.visit_i128(i)
    } else if let Ok(u) = raw.parse::<u128>() {
        visitor.visit_u128(u)
    } else if let Some(f) = parse_float(raw) {
        // Out of integer range — fall back to float, matching YAML behavior.
        visitor.visit_f64(f)
    } else {
        Err(Error::Number(raw.to_string()))
    }
}

/// Parse a float, including the YAML special values that Rust's `f64::from_str`
/// rejects.
fn parse_float(raw: &str) -> Option<f64> {
    match raw {
        ".inf" | ".Inf" | ".INF" | "+.inf" | "+.Inf" | "+.INF" => Some(f64::INFINITY),
        "-.inf" | "-.Inf" | "-.INF" => Some(f64::NEG_INFINITY),
        ".nan" | ".NaN" | ".NAN" => Some(f64::NAN),
        _ => raw.parse::<f64>().ok(),
    }
}

struct SeqAccess<'a> {
    doc: &'a Document,
    next: Option<FigNodeId>,
    remaining: usize,
}

impl<'a> SeqAccess<'a> {
    fn new(doc: &'a Document, seq: FigNodeId) -> Self {
        Self {
            doc,
            next: doc.first_child(seq),
            remaining: doc.child_count(seq),
        }
    }
}

impl<'de, 'a> de::SeqAccess<'de> for SeqAccess<'a> {
    type Error = Error;

    fn next_element_seed<T: DeserializeSeed<'de>>(
        &mut self,
        seed: T,
    ) -> Result<Option<T::Value>, Error> {
        let Some(id) = self.next else {
            return Ok(None);
        };
        self.next = self.doc.next_sibling(id);
        self.remaining = self.remaining.saturating_sub(1);
        seed.deserialize(NodeDeserializer {
            doc: self.doc,
            id: Some(id),
        })
        .map(Some)
    }

    fn size_hint(&self) -> Option<usize> {
        Some(self.remaining)
    }
}

struct MapAccess<'a> {
    doc: &'a Document,
    /// Next keyvalue node.
    next: Option<FigNodeId>,
    /// Value node stashed by `next_key_seed`.
    value: Option<FigNodeId>,
    remaining: usize,
}

impl<'a> MapAccess<'a> {
    fn new(doc: &'a Document, mapping: FigNodeId) -> Self {
        Self {
            doc,
            next: doc.first_child(mapping),
            value: None,
            remaining: doc.child_count(mapping),
        }
    }
}

impl<'de, 'a> de::MapAccess<'de> for MapAccess<'a> {
    type Error = Error;

    fn next_key_seed<K: DeserializeSeed<'de>>(
        &mut self,
        seed: K,
    ) -> Result<Option<K::Value>, Error> {
        let Some(kv) = self.next else {
            return Ok(None);
        };
        let key = self.doc.kv_key(kv);
        self.value = self.doc.kv_value(kv);
        self.next = self.doc.next_sibling(kv);
        self.remaining = self.remaining.saturating_sub(1);
        seed.deserialize(NodeDeserializer {
            doc: self.doc,
            id: key,
        })
        .map(Some)
    }

    fn next_value_seed<V: DeserializeSeed<'de>>(&mut self, seed: V) -> Result<V::Value, Error> {
        seed.deserialize(NodeDeserializer {
            doc: self.doc,
            id: self.value.take(),
        })
    }

    fn size_hint(&self) -> Option<usize> {
        Some(self.remaining)
    }
}

struct EnumRef<'a> {
    doc: &'a Document,
    variant: &'a str,
    value: Option<FigNodeId>,
}

impl<'de, 'a> EnumAccess<'de> for EnumRef<'a> {
    type Error = Error;
    type Variant = VariantRef<'a>;

    fn variant_seed<V: DeserializeSeed<'de>>(
        self,
        seed: V,
    ) -> Result<(V::Value, Self::Variant), Error> {
        let de = serde::de::value::StrDeserializer::<'_, Error>::new(self.variant);
        let variant = seed.deserialize(de)?;
        Ok((
            variant,
            VariantRef {
                doc: self.doc,
                value: self.value,
            },
        ))
    }
}

struct VariantRef<'a> {
    doc: &'a Document,
    value: Option<FigNodeId>,
}

impl<'de, 'a> VariantAccess<'de> for VariantRef<'a> {
    type Error = Error;

    fn unit_variant(self) -> Result<(), Error> {
        match self.value {
            None => Ok(()),
            Some(id) if self.doc.kind(id) == FigNodeKind::Null => Ok(()),
            Some(_) => Err(Error::Message("expected a unit variant".into())),
        }
    }

    fn newtype_variant_seed<T: DeserializeSeed<'de>>(self, seed: T) -> Result<T::Value, Error> {
        seed.deserialize(NodeDeserializer {
            doc: self.doc,
            id: self.value,
        })
    }

    fn tuple_variant<V: Visitor<'de>>(self, _len: usize, visitor: V) -> Result<V::Value, Error> {
        match self.value {
            Some(id) if self.doc.kind(id) == FigNodeKind::Sequence => {
                visitor.visit_seq(SeqAccess::new(self.doc, id))
            }
            _ => Err(Error::Message("expected a tuple variant".into())),
        }
    }

    fn struct_variant<V: Visitor<'de>>(
        self,
        _fields: &'static [&'static str],
        visitor: V,
    ) -> Result<V::Value, Error> {
        match self.value {
            Some(id) if self.doc.kind(id) == FigNodeKind::Mapping => {
                visitor.visit_map(MapAccess::new(self.doc, id))
            }
            _ => Err(Error::Message("expected a struct variant".into())),
        }
    }
}
