use fig::Value;
use serde::Deserialize;

/// Build a `Value::Map` from `(key, value)` pairs (insertion order preserved).
fn map(pairs: Vec<(&str, Value)>) -> Value {
    Value::Map(pairs.into_iter().map(|(k, v)| (k.into(), v)).collect())
}

#[test]
fn from_slice_deserializes_every_format() {
    use fig::Format;

    #[derive(Deserialize, PartialEq, Debug)]
    struct S {
        name: String,
        n: u32,
        tags: Vec<String>,
    }
    let want = S {
        name: "x".into(),
        n: 5,
        tags: vec!["a".into(), "b".into()],
    };

    // Only the formats whose features are enabled are linked into the native
    // library; gate the cases so the suite passes under any feature selection.
    let mut cases: Vec<(&[u8], Format)> = vec![
        (br#"{"name":"x","n":5,"tags":["a","b"]}"#, Format::Json),
    ];
    #[cfg(feature = "yaml")]
    cases.push((b"name: x\nn: 5\ntags:\n- a\n- b\n", Format::Yaml));
    #[cfg(feature = "toml")]
    cases.push((b"name = \"x\"\nn = 5\ntags = [\"a\", \"b\"]\n", Format::Toml));
    #[cfg(feature = "zon")]
    cases.push((b".{ .name = \"x\", .n = 5, .tags = .{ \"a\", \"b\" } }", Format::Zon));
    for (src, format) in cases {
        let got: S = fig::from_slice(src, format).unwrap();
        assert_eq!(got, want, "mismatch for {format:?}");
    }
}

#[test]
fn frontmatter_into_struct() {
    #[derive(Deserialize, PartialEq, Debug)]
    struct Frontmatter {
        title: String,
        count: i64,
        tags: Vec<String>,
    }

    let src = "title: Hello\ncount: 42\ntags:\n- a\n- b\n";
    let fm: Frontmatter = fig::from_str(src).unwrap();
    assert_eq!(
        fm,
        Frontmatter {
            title: "Hello".to_string(),
            count: 42,
            tags: vec!["a".to_string(), "b".to_string()],
        }
    );
}

#[test]
fn typed_config_with_enum() {
    // Mirrors the shape of Diaryx's PublishPluginConfig + AudienceAccessState.
    #[derive(Deserialize, PartialEq, Debug)]
    #[serde(rename_all = "snake_case")]
    enum AudienceAccessState {
        Unpublished,
        Public,
        AccessControl,
    }

    #[derive(Deserialize, PartialEq, Debug)]
    struct Config {
        namespace_id: String,
        state: AudienceAccessState,
        subdomain: Option<String>,
    }

    let src = "namespace_id: ns-1\nstate: access_control\n";
    let cfg: Config = fig::from_str(src).unwrap();
    assert_eq!(
        cfg,
        Config {
            namespace_id: "ns-1".to_string(),
            state: AudienceAccessState::AccessControl,
            subdomain: None,
        }
    );
}

#[test]
fn nested_maps_and_sequences() {
    let src = "\
a:
  b:
    - 1
    - 2
  c: hello
";
    let value: Value = fig::from_str(src).unwrap();
    assert_eq!(
        value,
        map(vec![(
            "a",
            map(vec![
                ("b", Value::Seq(vec![1i64.into(), 2i64.into()])),
                ("c", "hello".into()),
            ]),
        )]),
    );
}

/// An indentless block sequence — entries at the same column as the parent
/// mapping key — is the key's value, and a following sibling key ends it.
#[test]
fn indentless_block_sequence() {
    let nested: Value = fig::from_str("a:\n  b:\n  - 1\n  - 2\n  c: hello\n").unwrap();
    assert_eq!(
        nested,
        map(vec![(
            "a",
            map(vec![
                ("b", Value::Seq(vec![1i64.into(), 2i64.into()])),
                ("c", "hello".into()),
            ]),
        )]),
    );

    let root: Value = fig::from_str("one:\n- 2\nfour: 5\n").unwrap();
    assert_eq!(
        root,
        map(vec![("one", Value::Seq(vec![2i64.into()])), ("four", 5i64.into())]),
    );
}

#[test]
fn null_becomes_option_none() {
    #[derive(Deserialize, PartialEq, Debug)]
    struct S {
        a: Option<String>,
        b: Option<String>,
    }

    let src = "a: ~\nb: present\n";
    let s: S = fig::from_str(src).unwrap();
    assert_eq!(s.a, None);
    assert_eq!(s.b, Some("present".to_string()));
}

#[test]
fn empty_document_is_null() {
    let v: Option<String> = fig::from_str("").unwrap();
    assert_eq!(v, None);
}

#[test]
fn int_vs_float_classification() {
    #[derive(Deserialize, Debug)]
    struct Nums {
        i: i64,
        f: f64,
    }

    let nums: Nums = fig::from_str("i: 7\nf: 1.5\n").unwrap();
    assert_eq!(nums.i, 7);
    assert_eq!(nums.f, 1.5);
}

#[test]
fn yaml_special_floats() {
    let inf: f64 = fig::from_str(".inf").unwrap();
    assert!(inf.is_infinite() && inf.is_sign_positive());

    let ninf: f64 = fig::from_str("-.inf").unwrap();
    assert!(ninf.is_infinite() && ninf.is_sign_negative());

    let nan: f64 = fig::from_str(".nan").unwrap();
    assert!(nan.is_nan());
}

#[test]
fn bool_scalars() {
    let v: Vec<bool> = fig::from_str("[true, false]").unwrap();
    assert_eq!(v, vec![true, false]);
}

/// Parses the kinds of frontmatter Diaryx actually uses into the expected
/// generic value. (fig is the YAML implementation now, so the expectations are
/// stated directly rather than diffed against another parser.)
#[test]
fn parses_frontmatter_shapes() {
    let cases = [
        (
            "title: Hello\ncount: 42\ntags:\n- a\n- b\n",
            map(vec![
                ("title", "Hello".into()),
                ("count", 42i64.into()),
                ("tags", Value::Seq(vec!["a".into(), "b".into()])),
            ]),
        ),
        (
            "a:\n  b:\n    - 1\n    - 2\n  c: hello\n",
            map(vec![(
                "a",
                map(vec![
                    ("b", Value::Seq(vec![1i64.into(), 2i64.into()])),
                    ("c", "hello".into()),
                ]),
            )]),
        ),
        (
            "nested:\n  deep:\n    value: 3.14\n",
            map(vec![(
                "nested",
                map(vec![("deep", map(vec![("value", 3.14.into())]))]),
            )]),
        ),
        (
            "list:\n- one: 1\n- two: 2\n",
            map(vec![(
                "list",
                Value::Seq(vec![
                    map(vec![("one", 1i64.into())]),
                    map(vec![("two", 2i64.into())]),
                ]),
            )]),
        ),
        (
            "flag: true\nname: example\nempty: ~\n",
            map(vec![
                ("flag", true.into()),
                ("name", "example".into()),
                ("empty", Value::Null),
            ]),
        ),
    ];

    for (src, want) in cases {
        let ours: Value = fig::from_str(src).unwrap();
        assert_eq!(ours, want, "mismatch for source:\n{src}");
    }
}
