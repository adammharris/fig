//! Exercises the `derive` feature: `#[derive(fig::ToValue, fig::FromValue)]`.
//! Run with `cargo test -p fig --features derive`.
#![cfg(feature = "derive")]

use std::collections::BTreeMap;

use fig::{FromValue, ToValue, Value};

#[derive(Debug, PartialEq, ToValue, FromValue)]
struct Simple {
    name: String,
    count: u32,
    enabled: bool,
}

#[test]
fn round_trips_simple_struct() {
    let original = Simple {
        name: "fig".to_owned(),
        count: 3,
        enabled: true,
    };
    let value = original.to_value();
    assert_eq!(
        value,
        Value::Map(vec![
            (Value::Str("name".into()), Value::Str("fig".into())),
            (Value::Str("count".into()), Value::Uint(3)),
            (Value::Str("enabled".into()), Value::Bool(true)),
        ])
    );
    assert_eq!(Simple::from_value(&value).unwrap(), original);
}

#[derive(Debug, PartialEq, ToValue, FromValue)]
struct WithAttrs {
    #[fig(rename = "title")]
    name: Option<String>,
    #[fig(default)]
    retries: u8,
    #[fig(skip)]
    cached: bool,
    #[fig(flatten)]
    extra: BTreeMap<String, Value>,
}

#[test]
fn rename_default_skip_and_flatten() {
    // `title` absent (Option -> None), `retries` absent (default -> 0),
    // unknown keys land in `extra`.
    let input = Value::Map(vec![
        (Value::Str("author".into()), Value::Str("amh".into())),
        (Value::Str("draft".into()), Value::Bool(true)),
    ]);
    let parsed = WithAttrs::from_value(&input).unwrap();
    assert_eq!(parsed.name, None);
    assert_eq!(parsed.retries, 0);
    assert!(!parsed.cached);
    assert_eq!(parsed.extra.len(), 2);
    assert_eq!(parsed.extra.get("author"), Some(&Value::Str("amh".into())));

    // ToValue: renamed key present, skipped field absent, flatten merged.
    let back = WithAttrs {
        name: Some("Hello".to_owned()),
        retries: 2,
        cached: true,
        extra: BTreeMap::from([("k".to_owned(), Value::Int(1))]),
    }
    .to_value();
    let Value::Map(entries) = back else {
        panic!("expected map");
    };
    let keys: Vec<&str> = entries
        .iter()
        .filter_map(|(k, _)| match k {
            Value::Str(s) => Some(s.as_str()),
            _ => None,
        })
        .collect();
    assert!(keys.contains(&"title"));
    assert!(keys.contains(&"retries"));
    assert!(keys.contains(&"k"));
    assert!(!keys.contains(&"cached"));
    assert!(!keys.contains(&"name"));
}

#[derive(Debug, PartialEq, ToValue, FromValue)]
struct Newtype(Vec<i64>);

#[test]
fn newtype_is_transparent() {
    let v = Newtype(vec![1, 2, 3]).to_value();
    assert_eq!(
        v,
        Value::Seq(vec![Value::Int(1), Value::Int(2), Value::Int(3)])
    );
    assert_eq!(Newtype::from_value(&v).unwrap(), Newtype(vec![1, 2, 3]));
}

#[test]
fn missing_required_field_errors() {
    let err = Simple::from_value(&Value::Map(vec![(
        Value::Str("name".into()),
        Value::Str("x".into()),
    )]))
    .unwrap_err();
    assert!(format!("{err}").contains("missing field `count`"));
}

#[test]
fn integer_out_of_range_errors() {
    let err = Simple::from_value(&Value::Map(vec![
        (Value::Str("name".into()), Value::Str("x".into())),
        (Value::Str("count".into()), Value::Int(-1)),
        (Value::Str("enabled".into()), Value::Bool(false)),
    ]))
    .unwrap_err();
    assert!(format!("{err}").contains("out of range"));
}
