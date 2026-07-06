use serde::{Deserialize, Serialize};

use fig::{Format, Value};

/// Build a `Value::Map` from `(key, value)` pairs (insertion order preserved).
fn map(pairs: Vec<(&str, Value)>) -> Value {
    Value::Map(pairs.into_iter().map(|(k, v)| (k.into(), v)).collect())
}

/// Emission now lives in fig's core printer, not the binding, so byte-for-byte
/// parity with serde_yaml_ng is no longer the contract (core uses `|` block
/// scalars and its own nested-sequence layout). The contract is round-trip
/// fidelity, exercised here against fig's own dynamic `Value`:
/// `from_str(value.serialize()) == value`.
#[test]
fn generic_values_round_trip() {
    let cases = [
        map(vec![
            ("title", "Hello".into()),
            ("count", 42i64.into()),
            ("ratio", 1.5.into()),
            ("flag", true.into()),
            ("empty", Value::Null),
        ]),
        map(vec![(
            "a",
            map(vec![
                ("b", Value::Seq(vec![1i64.into(), 2i64.into()])),
                ("c", "hello".into()),
            ]),
        )]),
        map(vec![(
            "items",
            Value::Seq(vec![
                map(vec![("name", "a".into()), ("v", 1i64.into())]),
                map(vec![("name", "b".into()), ("v", 2i64.into())]),
            ]),
        )]),
        map(vec![
            ("seq", Value::Seq(vec![])),
            ("map", Value::Map(vec![])),
        ]),
        map(vec![
            ("a", "yes".into()),
            ("b", "123".into()),
            ("c", "a: b".into()),
            ("d", "#hash".into()),
            ("e", "".into()),
            ("h", "null".into()),
        ]),
        Value::Seq(vec![1i64.into(), 2i64.into(), 3i64.into()]),
        "just a string".into(),
        map(vec![("a", map(vec![("b", Value::Seq(vec![]))]))]),
        map(vec![(
            "m",
            Value::Seq(vec![
                Value::Seq(vec![1i64.into(), 2i64.into()]),
                Value::Seq(vec![3i64.into(), 4i64.into()]),
            ]),
        )]),
        map(vec![
            ("created", "2024-01-01".into()),
            ("tags", Value::Seq(vec!["a".into(), "b".into()])),
            ("n", Value::Null),
        ]),
        map(vec![
            ("quote", "it's".into()),
            ("colon_end", "key:".into()),
            ("spaced", "  pad  ".into()),
        ]),
    ];
    for case in cases {
        let yaml = case.serialize(Format::Yaml).unwrap();
        let back: Value = fig::from_str(&yaml).unwrap();
        assert_eq!(back, case, "round-trip mismatch (yaml:\n{yaml})");
    }
}

/// A representative snapshot, so accidental format churn stays visible. fig
/// prints short sequences inline (flow style) when they fit the width
/// budget, and single-quotes only what must be quoted.
#[test]
fn snapshot_of_a_diaryx_shape() {
    let value = map(vec![
        ("title", "My Entry: A Tale".into()),
        ("tags", Value::Seq(vec!["a".into(), "b".into()])),
        ("draft", false.into()),
    ]);
    assert_eq!(
        value.serialize(Format::Yaml).unwrap(),
        "title: 'My Entry: A Tale'\ntags: [a, b]\ndraft: false\n",
    );
}

#[test]
fn typed_config_round_trips() {
    #[derive(Serialize, Deserialize, PartialEq, Debug)]
    #[serde(rename_all = "snake_case")]
    enum AccessState {
        #[allow(dead_code)]
        Public,
        AccessControl,
    }
    #[derive(Serialize, Deserialize, PartialEq, Debug)]
    struct Config {
        namespace_id: String,
        state: AccessState,
        audiences: Vec<String>,
        subdomain: Option<String>,
    }

    let cfg = Config {
        namespace_id: "ns-1".to_string(),
        state: AccessState::AccessControl,
        audiences: vec!["friends".to_string(), "family".to_string()],
        subdomain: None,
    };
    let yaml = fig::to_string(&cfg).unwrap();
    let back: Config = fig::from_str(&yaml).unwrap();
    assert_eq!(cfg, back);
}

/// The whole point: `from_str(to_string(x)) == x`. Exercises both halves of the
/// bookmatter::yaml seam together.
#[test]
fn round_trips_through_fig() {
    #[derive(Serialize, Deserialize, PartialEq, Debug)]
    struct Frontmatter {
        title: String,
        count: i64,
        ratio: f64,
        published: bool,
        tags: Vec<String>,
        note: Option<String>,
        meta: Meta,
    }
    #[derive(Serialize, Deserialize, PartialEq, Debug)]
    struct Meta {
        author: String,
        revisions: Vec<i64>,
    }

    let fm = Frontmatter {
        title: "My Entry: A Tale".to_string(), // forces quoting (colon-space)
        count: 7,
        ratio: 3.5,
        published: true,
        tags: vec!["a".to_string(), "b".to_string()],
        note: None,
        meta: Meta {
            author: "me".to_string(),
            revisions: vec![1, 2, 3],
        },
    };

    let yaml = fig::to_string(&fm).unwrap();
    let back: Frontmatter = fig::from_str(&yaml).unwrap();
    assert_eq!(fm, back);
}

#[test]
fn round_trips_tricky_strings() {
    // Values that must survive quoting/escaping intact.
    let inputs = [
        "plain",
        "123",
        "null",
        "true",
        "a: b",
        "  leading and trailing  ",
        "#hash",
        "",
        "it's a 'quote'",
        "multi\nline\ntext",
        "tab\there",
    ];
    for s in inputs {
        let yaml = fig::to_string(&s).unwrap();
        let back: String = fig::from_str(&yaml).unwrap();
        assert_eq!(back, s, "round-trip failed for {s:?} (yaml: {yaml:?})");
    }
}

#[test]
fn special_floats_round_trip() {
    for f in [f64::INFINITY, f64::NEG_INFINITY, 0.0, -2.5, 1000.0] {
        let yaml = fig::to_string(&f).unwrap();
        let back: f64 = fig::from_str(&yaml).unwrap();
        assert_eq!(back, f, "round-trip failed for {f} (yaml: {yaml:?})");
    }
    // NaN is not equal to itself; check the classification survives.
    let yaml = fig::to_string(&f64::NAN).unwrap();
    let back: f64 = fig::from_str(&yaml).unwrap();
    assert!(back.is_nan());
}

#[test]
fn json_compact_vs_pretty() {
    use fig::SerializeOptions;
    let value = map(vec![
        ("name", "Ada".into()),
        ("tags", Value::Seq(vec!["zig".into(), true.into(), Value::Null])),
    ]);

    // Default serialize == pretty default == 2-space multi-line.
    let pretty = value.serialize(Format::Json).unwrap();
    assert_eq!(
        pretty,
        "{\n  \"name\": \"Ada\",\n  \"tags\": [\n    \"zig\",\n    true,\n    null\n  ]\n}\n"
    );
    assert_eq!(
        value
            .serialize_with(Format::Json, SerializeOptions::default())
            .unwrap(),
        pretty
    );

    // Compact: no insignificant whitespace.
    let compact = value
        .serialize_with(Format::Json, SerializeOptions::compact())
        .unwrap();
    assert_eq!(compact, "{\"name\":\"Ada\",\"tags\":[\"zig\",true,null]}\n");

    // Custom indent width.
    let wide = value
        .serialize_with(Format::Json, SerializeOptions::pretty(4))
        .unwrap();
    assert!(wide.contains("\n    \"name\": \"Ada\""));
}

#[test]
fn toml_width_controls_inline_vs_section() {
    use fig::SerializeOptions;
    let value = map(vec![(
        "point",
        map(vec![("x", 1i64.into()), ("y", 2i64.into())]),
    )]);

    // Default budget (80): the small mapping stays an inline table.
    assert_eq!(
        value.serialize(Format::Toml).unwrap(),
        "point = { x = 1, y = 2 }\n"
    );

    // A tight budget forces it to expand to a [section].
    assert_eq!(
        value
            .serialize_with(Format::Toml, SerializeOptions::default().width(8))
            .unwrap(),
        "[point]\nx = 1\ny = 2\n"
    );
}

#[test]
fn zon_compact_vs_pretty() {
    use fig::SerializeOptions;
    let value = map(vec![
        ("name", "Ada".into()),
        ("xs", Value::Seq(vec![1i64.into(), 2i64.into()])),
    ]);

    let compact = value
        .serialize_with(Format::Zon, SerializeOptions::compact())
        .unwrap();
    assert_eq!(compact, ".{ .name = \"Ada\", .xs = .{ 1, 2 } }\n");

    // Pretty stays the idiomatic four-space `zig fmt` shape.
    let pretty = value.serialize(Format::Zon).unwrap();
    assert_eq!(
        pretty,
        ".{\n    .name = \"Ada\",\n    .xs = .{\n        1,\n        2,\n    },\n}\n"
    );
}

#[test]
fn json5_serializes_and_parses_back() {
    // Proves `Format::Json5` is wired through both the writer and the reader, not
    // just the editor: serialize emits JSON5 (bare identifier keys), and the
    // JSON5 reader round-trips it back to the same logical value.
    let value = map(vec![("host", "localhost".into()), ("port", 8080i64.into())]);

    let text = value.serialize(Format::Json5).unwrap();
    assert!(text.contains("host:"), "JSON5 keys are bare: {text:?}");

    #[derive(Deserialize, PartialEq, Debug)]
    struct Cfg {
        host: String,
        port: i64,
    }
    let back: Cfg = fig::from_slice(text.as_bytes(), Format::Json5).unwrap();
    assert_eq!(
        back,
        Cfg {
            host: "localhost".into(),
            port: 8080,
        },
    );
}

#[test]
#[cfg(feature = "fig")]
fn fig_dialect_serializes_and_parses_back() {
    // Proves `Format::Fig` (the native authoring dialect) is wired through both
    // the writer and the reader: serialize emits `key = value` fig syntax, and
    // the fig reader round-trips it back to the same logical value.
    let value = map(vec![("host", "localhost".into()), ("port", 8080i64.into())]);

    let text = value.serialize(Format::Fig).unwrap();
    assert_eq!(text, "host = localhost\nport = 8080\n");

    #[derive(Deserialize, PartialEq, Debug)]
    struct Cfg {
        host: String,
        port: i64,
    }
    let back: Cfg = fig::from_slice(text.as_bytes(), Format::Fig).unwrap();
    assert_eq!(
        back,
        Cfg {
            host: "localhost".into(),
            port: 8080,
        },
    );
}
