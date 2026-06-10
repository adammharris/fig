use serde::Deserialize;

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
    let value: serde_json::Value = fig::from_str(src).unwrap();
    assert_eq!(
        value,
        serde_json::json!({ "a": { "b": [1, 2], "c": "hello" } })
    );
}

/// Known fig YAML *parser* bug (not a bindings bug): a block sequence whose
/// entries sit at the same column as the parent mapping key swallows the
/// following sibling key. The deeper-indented form (see above) parses
/// correctly. Tracked for a fix in fig's Zig parser.
#[test]
#[ignore = "fig parser bug: same-indent block sequence under a mapping key"]
fn same_indent_block_sequence() {
    let src = "a:\n  b:\n  - 1\n  - 2\n  c: hello\n";
    let value: serde_json::Value = fig::from_str(src).unwrap();
    assert_eq!(
        value,
        serde_json::json!({ "a": { "b": [1, 2], "c": "hello" } })
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

/// Differential check: deserializing into a generic value should match
/// serde_yaml_ng for the kinds of frontmatter Diaryx actually uses.
#[test]
fn matches_serde_yaml_ng() {
    let cases = [
        "title: Hello\ncount: 42\ntags:\n- a\n- b\n",
        "a:\n  b:\n    - 1\n    - 2\n  c: hello\n",
        "nested:\n  deep:\n    value: 3.14\n",
        "list:\n- one: 1\n- two: 2\n",
        "flag: true\nname: example\nempty: ~\n",
    ];

    for src in cases {
        let theirs: serde_json::Value = serde_yaml_ng::from_str(src).unwrap();
        let ours: serde_json::Value = fig::from_str(src).unwrap();
        assert_eq!(ours, theirs, "mismatch for source:\n{src}");
    }
}
