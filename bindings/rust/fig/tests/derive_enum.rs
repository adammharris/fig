//! Exercises tagged-enum support in the `derive` feature across all four
//! taggings and variant shapes. Run with `cargo test -p fig --features derive`.
#![cfg(feature = "derive")]

use fig::{FromValue, ToValue, Value};

fn s(x: &str) -> Value {
    Value::Str(x.into())
}

// --- External (default) -------------------------------------------------------

#[derive(Debug, PartialEq, ToValue, FromValue)]
enum External {
    Unit,
    Newtype(u32),
    Tuple(u8, bool),
    Struct { a: String, b: i64 },
}

#[test]
fn external_tagging_round_trips() {
    let cases = [
        (External::Unit, s("Unit")),
        (
            External::Newtype(7),
            Value::Map(vec![(s("Newtype"), Value::Uint(7))]),
        ),
        (
            External::Tuple(1, true),
            Value::Map(vec![(
                s("Tuple"),
                Value::Seq(vec![Value::Uint(1), Value::Bool(true)]),
            )]),
        ),
        (
            External::Struct {
                a: "x".into(),
                b: -2,
            },
            Value::Map(vec![(
                s("Struct"),
                Value::Map(vec![(s("a"), s("x")), (s("b"), Value::Int(-2))]),
            )]),
        ),
    ];
    for (variant, wire) in cases {
        assert_eq!(variant.to_value(), wire, "to_value for {variant:?}");
        assert_eq!(External::from_value(&wire).unwrap(), variant);
    }
}

#[test]
fn external_unknown_variant_errors() {
    let err = External::from_value(&s("Nope")).unwrap_err();
    assert!(format!("{err}").contains("unknown variant `Nope`"));
}

// --- Adjacent (the Command/Response shape) ------------------------------------

#[derive(Debug, PartialEq, ToValue, FromValue)]
#[fig(tag = "type", content = "data")]
enum Adjacent {
    Ping,
    Echo(String),
    Move { x: i32, y: i32 },
}

#[test]
fn adjacent_tagging_round_trips() {
    let cases = [
        (Adjacent::Ping, Value::Map(vec![(s("type"), s("Ping"))])),
        (
            Adjacent::Echo("hi".into()),
            Value::Map(vec![(s("type"), s("Echo")), (s("data"), s("hi"))]),
        ),
        (
            Adjacent::Move { x: 1, y: 2 },
            Value::Map(vec![
                (s("type"), s("Move")),
                (
                    s("data"),
                    Value::Map(vec![(s("x"), Value::Int(1)), (s("y"), Value::Int(2))]),
                ),
            ]),
        ),
    ];
    for (variant, wire) in cases {
        assert_eq!(variant.to_value(), wire, "to_value for {variant:?}");
        assert_eq!(Adjacent::from_value(&wire).unwrap(), variant);
    }
}

#[test]
fn adjacent_missing_content_errors() {
    let wire = Value::Map(vec![(s("type"), s("Echo"))]);
    let err = Adjacent::from_value(&wire).unwrap_err();
    assert!(format!("{err}").contains("missing content `data`"));
}

// --- Internal -----------------------------------------------------------------

#[derive(Debug, PartialEq, ToValue, FromValue)]
#[fig(tag = "kind")]
enum Internal {
    Empty,
    Point { x: i32, y: i32 },
    Wrapped(Inner),
}

#[derive(Debug, PartialEq, ToValue, FromValue)]
struct Inner {
    label: String,
}

#[test]
fn internal_tagging_round_trips() {
    let cases = [
        (Internal::Empty, Value::Map(vec![(s("kind"), s("Empty"))])),
        (
            Internal::Point { x: 3, y: 4 },
            Value::Map(vec![
                (s("kind"), s("Point")),
                (s("x"), Value::Int(3)),
                (s("y"), Value::Int(4)),
            ]),
        ),
        (
            Internal::Wrapped(Inner { label: "z".into() }),
            Value::Map(vec![(s("kind"), s("Wrapped")), (s("label"), s("z"))]),
        ),
    ];
    for (variant, wire) in cases {
        assert_eq!(variant.to_value(), wire, "to_value for {variant:?}");
        assert_eq!(Internal::from_value(&wire).unwrap(), variant);
    }
}

// --- Untagged + variant rename ------------------------------------------------

#[derive(Debug, PartialEq, ToValue, FromValue)]
#[fig(untagged)]
enum Untagged {
    Num(i64),
    Text(String),
    Pair { first: bool, second: bool },
}

#[test]
fn untagged_first_match_wins() {
    assert_eq!(Untagged::Num(5).to_value(), Value::Int(5));
    assert_eq!(
        Untagged::from_value(&Value::Int(5)).unwrap(),
        Untagged::Num(5)
    );
    assert_eq!(
        Untagged::from_value(&s("hello")).unwrap(),
        Untagged::Text("hello".into())
    );
    let pair = Value::Map(vec![
        (s("first"), Value::Bool(true)),
        (s("second"), Value::Bool(false)),
    ]);
    assert_eq!(
        Untagged::from_value(&pair).unwrap(),
        Untagged::Pair {
            first: true,
            second: false
        }
    );
    // Nothing matches a sequence here.
    assert!(Untagged::from_value(&Value::Seq(vec![])).is_err());
}

#[derive(Debug, PartialEq, ToValue, FromValue)]
enum Renamed {
    #[fig(rename = "ok")]
    Success,
    #[fig(rename = "err")]
    Failure(String),
}

#[test]
fn variant_rename_applies() {
    assert_eq!(Renamed::Success.to_value(), s("ok"));
    assert_eq!(Renamed::from_value(&s("ok")).unwrap(), Renamed::Success);
    assert_eq!(
        Renamed::Failure("boom".into()).to_value(),
        Value::Map(vec![(s("err"), s("boom"))])
    );
}
