//! A serde [`Serializer`] producing block-style YAML.
//!
//! Serialization happens in two steps: serde drives the construction of an
//! intermediate [`Node`] tree, then [`emit`] renders that tree as YAML. Keeping
//! the formatter separate from the serde plumbing makes the (fiddly) emission
//! rules easy to test in isolation.
//!
//! The output style mirrors `serde_yaml_ng` for the shapes Diaryx uses:
//! block collections, **indentless** sequences (dashes at the parent key's
//! column), inline `[]`/`{}` for empty collections, and single-quoted scalars
//! where quoting is needed. Two deliberate divergences: multi-line strings are
//! emitted double-quoted rather than as `|-` block scalars, and very large
//! floats use Rust's decimal formatting rather than scientific notation.

use serde::{ser, Serialize, Serializer};

use crate::error::Error;

/// Serialize a value to a YAML string.
pub fn to_string<T: Serialize + ?Sized>(value: &T) -> Result<String, Error> {
    let node = value.serialize(NodeSerializer)?;
    let mut out = String::new();
    emit(&node, &mut out)?;
    Ok(out)
}

/// An intermediate, fully-owned representation of a serialized value.
#[derive(Debug)]
enum Node {
    Null,
    Bool(bool),
    I64(i64),
    U64(u64),
    F64(f64),
    Str(String),
    Seq(Vec<Node>),
    Map(Vec<(Node, Node)>),
}

// ========
// Emission
// ========

fn emit(node: &Node, out: &mut String) -> Result<(), Error> {
    match node {
        Node::Seq(items) if !items.is_empty() => emit_seq(items, 0, out)?,
        Node::Map(pairs) if !pairs.is_empty() => emit_map(pairs, 0, out)?,
        scalar => {
            out.push_str(&scalar_to_string(scalar)?);
            out.push('\n');
        }
    }
    Ok(())
}

fn emit_map(pairs: &[(Node, Node)], indent: usize, out: &mut String) -> Result<(), Error> {
    for pair in pairs {
        emit_pair(pair, indent, out, true)?;
    }
    Ok(())
}

/// Emit one `key: value` pair. `pad_key` is false when the cursor is already at
/// the key's column (the first pair of a mapping that is a sequence element).
fn emit_pair(
    pair: &(Node, Node),
    indent: usize,
    out: &mut String,
    pad_key: bool,
) -> Result<(), Error> {
    if pad_key {
        pad(out, indent);
    }
    out.push_str(&key_to_string(&pair.0)?);
    out.push(':');
    emit_value_after_key(&pair.1, indent, out)
}

/// Emit a mapping value following the `:` on the key's line (the cursor is just
/// after the colon). Inline scalars and empty collections stay on the line; a
/// non-empty sequence is written indentless at the key's column, and a
/// non-empty mapping on the following lines indented by two.
fn emit_value_after_key(value: &Node, indent: usize, out: &mut String) -> Result<(), Error> {
    match value {
        Node::Seq(items) if !items.is_empty() => {
            out.push('\n');
            emit_seq(items, indent, out)
        }
        Node::Map(pairs) if !pairs.is_empty() => {
            out.push('\n');
            emit_map(pairs, indent + 2, out)
        }
        scalar => {
            out.push(' ');
            out.push_str(&scalar_to_string(scalar)?);
            out.push('\n');
            Ok(())
        }
    }
}

fn emit_seq(items: &[Node], indent: usize, out: &mut String) -> Result<(), Error> {
    for item in items {
        emit_dash_item(item, indent, out, true)?;
    }
    Ok(())
}

/// Emit one `- value` element. `pad_dash` is false when the cursor is already at
/// the dash's column (the first element of a sequence that is itself a sequence
/// element, e.g. `- - 1`).
fn emit_dash_item(
    item: &Node,
    indent: usize,
    out: &mut String,
    pad_dash: bool,
) -> Result<(), Error> {
    if pad_dash {
        pad(out, indent);
    }
    out.push('-');
    emit_value_after_dash(item, indent, out)
}

/// Emit a sequence element following the `-` (cursor just after the dash). A
/// mapping or sequence element places its first entry on the dash line and the
/// rest indented by two.
fn emit_value_after_dash(item: &Node, indent: usize, out: &mut String) -> Result<(), Error> {
    match item {
        Node::Map(pairs) if !pairs.is_empty() => {
            out.push(' ');
            emit_pair(&pairs[0], indent + 2, out, false)?;
            for pair in &pairs[1..] {
                emit_pair(pair, indent + 2, out, true)?;
            }
            Ok(())
        }
        Node::Seq(items) if !items.is_empty() => {
            out.push(' ');
            emit_dash_item(&items[0], indent + 2, out, false)?;
            for item in &items[1..] {
                emit_dash_item(item, indent + 2, out, true)?;
            }
            Ok(())
        }
        scalar => {
            out.push(' ');
            out.push_str(&scalar_to_string(scalar)?);
            out.push('\n');
            Ok(())
        }
    }
}

fn pad(out: &mut String, indent: usize) {
    for _ in 0..indent {
        out.push(' ');
    }
}

/// Render a scalar (or an empty collection) as a single line.
fn scalar_to_string(node: &Node) -> Result<String, Error> {
    Ok(match node {
        Node::Null => "null".to_string(),
        Node::Bool(true) => "true".to_string(),
        Node::Bool(false) => "false".to_string(),
        Node::I64(i) => i.to_string(),
        Node::U64(u) => u.to_string(),
        Node::F64(f) => format_float(*f),
        Node::Str(s) => format_string(s),
        Node::Seq(_) => "[]".to_string(),
        Node::Map(_) => "{}".to_string(),
    })
}

/// Render a mapping key. Only scalar keys are supported (Diaryx frontmatter
/// keys are always strings); a collection key is an error.
fn key_to_string(node: &Node) -> Result<String, Error> {
    if matches!(node, Node::Seq(s) if !s.is_empty()) || matches!(node, Node::Map(m) if !m.is_empty())
    {
        return Err(Error::Message("non-scalar mapping keys are unsupported".into()));
    }
    scalar_to_string(node)
}

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

fn format_string(s: &str) -> String {
    if s.contains('\n') || s.contains('\t') || has_nonprintable(s) {
        return double_quote(s);
    }
    if needs_quoting(s) {
        return single_quote(s);
    }
    s.to_string()
}

fn has_nonprintable(s: &str) -> bool {
    s.chars()
        .any(|c| c.is_control() && c != '\n' && c != '\t')
}

/// Whether a plain (unquoted) scalar would be misread — as another type, or as
/// YAML structure — and therefore needs quoting.
fn needs_quoting(s: &str) -> bool {
    if s.is_empty() {
        return true;
    }
    if resolves_to_nonstring(s) {
        return true;
    }
    let bytes = s.as_bytes();
    // Leading/trailing whitespace is not preserved by a plain scalar.
    if bytes[0] == b' ' || bytes[bytes.len() - 1] == b' ' {
        return true;
    }
    // A plain scalar may not begin with an indicator character.
    let first = bytes[0];
    if matches!(
        first,
        b'!' | b'&'
            | b'*'
            | b'?'
            | b'|'
            | b'>'
            | b'%'
            | b'@'
            | b'`'
            | b'"'
            | b'\''
            | b'#'
            | b','
            | b'['
            | b']'
            | b'{'
            | b'}'
    ) {
        return true;
    }
    // `-`, `:`, `?` are only unsafe as the first char when followed by a space
    // (or when they are the whole scalar).
    if matches!(first, b'-' | b':') && (s.len() == 1 || bytes[1] == b' ') {
        return true;
    }
    // Interior `: ` (mapping indicator) or ` #` (comment indicator) force quoting.
    if s.contains(": ") || s.ends_with(':') || s.contains(" #") {
        return true;
    }
    false
}

/// True for the plain scalars that YAML 1.2's core schema resolves to a
/// non-string type (null, bool, int, float, or the special floats).
fn resolves_to_nonstring(s: &str) -> bool {
    matches!(
        s,
        "null"
            | "Null"
            | "NULL"
            | "~"
            | "true"
            | "True"
            | "TRUE"
            | "false"
            | "False"
            | "FALSE"
            | ".inf"
            | ".Inf"
            | ".INF"
            | "-.inf"
            | "-.Inf"
            | "-.INF"
            | "+.inf"
            | ".nan"
            | ".NaN"
            | ".NAN"
    ) || looks_numeric(s)
}

/// Whether `s` would parse as a YAML number. Rust's float parser also accepts
/// `inf`/`nan`, which YAML does not, so those are excluded.
fn looks_numeric(s: &str) -> bool {
    let lower = s.to_ascii_lowercase();
    if lower.contains("inf") || lower.contains("nan") {
        return false;
    }
    s.parse::<i64>().is_ok() || s.parse::<u64>().is_ok() || s.parse::<f64>().is_ok()
}

fn single_quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('\'');
    for c in s.chars() {
        if c == '\'' {
            out.push('\'');
        }
        out.push(c);
    }
    out.push('\'');
    out
}

fn double_quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            '\r' => out.push_str("\\r"),
            c if c.is_control() => out.push_str(&format!("\\x{:02x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

// =====================================
// serde Serializer — builds a Node tree
// =====================================

struct NodeSerializer;

impl Serializer for NodeSerializer {
    type Ok = Node;
    type Error = Error;

    type SerializeSeq = SerializeSeq;
    type SerializeTuple = SerializeSeq;
    type SerializeTupleStruct = SerializeSeq;
    type SerializeTupleVariant = SerializeTupleVariant;
    type SerializeMap = SerializeMap;
    type SerializeStruct = SerializeMap;
    type SerializeStructVariant = SerializeStructVariant;

    fn serialize_bool(self, v: bool) -> Result<Node, Error> {
        Ok(Node::Bool(v))
    }
    fn serialize_i8(self, v: i8) -> Result<Node, Error> {
        Ok(Node::I64(v as i64))
    }
    fn serialize_i16(self, v: i16) -> Result<Node, Error> {
        Ok(Node::I64(v as i64))
    }
    fn serialize_i32(self, v: i32) -> Result<Node, Error> {
        Ok(Node::I64(v as i64))
    }
    fn serialize_i64(self, v: i64) -> Result<Node, Error> {
        Ok(Node::I64(v))
    }
    fn serialize_i128(self, v: i128) -> Result<Node, Error> {
        // No native i128 node; fall back to a string if it overflows i64/u64.
        if let Ok(i) = i64::try_from(v) {
            Ok(Node::I64(i))
        } else if let Ok(u) = u64::try_from(v) {
            Ok(Node::U64(u))
        } else {
            Ok(Node::Str(v.to_string()))
        }
    }
    fn serialize_u8(self, v: u8) -> Result<Node, Error> {
        Ok(Node::U64(v as u64))
    }
    fn serialize_u16(self, v: u16) -> Result<Node, Error> {
        Ok(Node::U64(v as u64))
    }
    fn serialize_u32(self, v: u32) -> Result<Node, Error> {
        Ok(Node::U64(v as u64))
    }
    fn serialize_u64(self, v: u64) -> Result<Node, Error> {
        Ok(Node::U64(v))
    }
    fn serialize_u128(self, v: u128) -> Result<Node, Error> {
        if let Ok(u) = u64::try_from(v) {
            Ok(Node::U64(u))
        } else {
            Ok(Node::Str(v.to_string()))
        }
    }
    fn serialize_f32(self, v: f32) -> Result<Node, Error> {
        Ok(Node::F64(v as f64))
    }
    fn serialize_f64(self, v: f64) -> Result<Node, Error> {
        Ok(Node::F64(v))
    }
    fn serialize_char(self, v: char) -> Result<Node, Error> {
        Ok(Node::Str(v.to_string()))
    }
    fn serialize_str(self, v: &str) -> Result<Node, Error> {
        Ok(Node::Str(v.to_string()))
    }
    fn serialize_bytes(self, v: &[u8]) -> Result<Node, Error> {
        Ok(Node::Seq(v.iter().map(|b| Node::U64(*b as u64)).collect()))
    }
    fn serialize_none(self) -> Result<Node, Error> {
        Ok(Node::Null)
    }
    fn serialize_some<T: ?Sized + Serialize>(self, value: &T) -> Result<Node, Error> {
        value.serialize(self)
    }
    fn serialize_unit(self) -> Result<Node, Error> {
        Ok(Node::Null)
    }
    fn serialize_unit_struct(self, _name: &'static str) -> Result<Node, Error> {
        Ok(Node::Null)
    }
    fn serialize_unit_variant(
        self,
        _name: &'static str,
        _index: u32,
        variant: &'static str,
    ) -> Result<Node, Error> {
        Ok(Node::Str(variant.to_string()))
    }
    fn serialize_newtype_struct<T: ?Sized + Serialize>(
        self,
        _name: &'static str,
        value: &T,
    ) -> Result<Node, Error> {
        value.serialize(self)
    }
    fn serialize_newtype_variant<T: ?Sized + Serialize>(
        self,
        _name: &'static str,
        _index: u32,
        variant: &'static str,
        value: &T,
    ) -> Result<Node, Error> {
        Ok(Node::Map(vec![(
            Node::Str(variant.to_string()),
            value.serialize(NodeSerializer)?,
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
            pairs: Vec::with_capacity(len.unwrap_or(0)),
            next_key: None,
        })
    }
    fn serialize_struct(
        self,
        _name: &'static str,
        len: usize,
    ) -> Result<SerializeMap, Error> {
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
            pairs: Vec::with_capacity(len),
        })
    }
}

struct SerializeSeq {
    items: Vec<Node>,
}

impl ser::SerializeSeq for SerializeSeq {
    type Ok = Node;
    type Error = Error;
    fn serialize_element<T: ?Sized + Serialize>(&mut self, value: &T) -> Result<(), Error> {
        self.items.push(value.serialize(NodeSerializer)?);
        Ok(())
    }
    fn end(self) -> Result<Node, Error> {
        Ok(Node::Seq(self.items))
    }
}

impl ser::SerializeTuple for SerializeSeq {
    type Ok = Node;
    type Error = Error;
    fn serialize_element<T: ?Sized + Serialize>(&mut self, value: &T) -> Result<(), Error> {
        ser::SerializeSeq::serialize_element(self, value)
    }
    fn end(self) -> Result<Node, Error> {
        ser::SerializeSeq::end(self)
    }
}

impl ser::SerializeTupleStruct for SerializeSeq {
    type Ok = Node;
    type Error = Error;
    fn serialize_field<T: ?Sized + Serialize>(&mut self, value: &T) -> Result<(), Error> {
        ser::SerializeSeq::serialize_element(self, value)
    }
    fn end(self) -> Result<Node, Error> {
        ser::SerializeSeq::end(self)
    }
}

struct SerializeTupleVariant {
    variant: &'static str,
    items: Vec<Node>,
}

impl ser::SerializeTupleVariant for SerializeTupleVariant {
    type Ok = Node;
    type Error = Error;
    fn serialize_field<T: ?Sized + Serialize>(&mut self, value: &T) -> Result<(), Error> {
        self.items.push(value.serialize(NodeSerializer)?);
        Ok(())
    }
    fn end(self) -> Result<Node, Error> {
        Ok(Node::Map(vec![(
            Node::Str(self.variant.to_string()),
            Node::Seq(self.items),
        )]))
    }
}

struct SerializeMap {
    pairs: Vec<(Node, Node)>,
    next_key: Option<Node>,
}

impl ser::SerializeMap for SerializeMap {
    type Ok = Node;
    type Error = Error;
    fn serialize_key<T: ?Sized + Serialize>(&mut self, key: &T) -> Result<(), Error> {
        self.next_key = Some(key.serialize(NodeSerializer)?);
        Ok(())
    }
    fn serialize_value<T: ?Sized + Serialize>(&mut self, value: &T) -> Result<(), Error> {
        let key = self
            .next_key
            .take()
            .ok_or_else(|| Error::Message("serialize_value called before serialize_key".into()))?;
        self.pairs.push((key, value.serialize(NodeSerializer)?));
        Ok(())
    }
    fn end(self) -> Result<Node, Error> {
        Ok(Node::Map(self.pairs))
    }
}

impl ser::SerializeStruct for SerializeMap {
    type Ok = Node;
    type Error = Error;
    fn serialize_field<T: ?Sized + Serialize>(
        &mut self,
        key: &'static str,
        value: &T,
    ) -> Result<(), Error> {
        self.pairs
            .push((Node::Str(key.to_string()), value.serialize(NodeSerializer)?));
        Ok(())
    }
    fn end(self) -> Result<Node, Error> {
        Ok(Node::Map(self.pairs))
    }
}

struct SerializeStructVariant {
    variant: &'static str,
    pairs: Vec<(Node, Node)>,
}

impl ser::SerializeStructVariant for SerializeStructVariant {
    type Ok = Node;
    type Error = Error;
    fn serialize_field<T: ?Sized + Serialize>(
        &mut self,
        key: &'static str,
        value: &T,
    ) -> Result<(), Error> {
        self.pairs
            .push((Node::Str(key.to_string()), value.serialize(NodeSerializer)?));
        Ok(())
    }
    fn end(self) -> Result<Node, Error> {
        Ok(Node::Map(vec![(
            Node::Str(self.variant.to_string()),
            Node::Map(self.pairs),
        )]))
    }
}
