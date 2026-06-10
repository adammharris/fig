use serde::{Deserialize, Serialize};

/// fig's emitter should match serde_yaml_ng byte-for-byte for the shapes Diaryx
/// uses. (Multi-line strings and extreme floats are deliberate divergences,
/// covered separately below — not here.)
#[test]
fn matches_serde_yaml_ng() {
    use serde_json::json;
    let cases = [
        json!({ "title": "Hello", "count": 42, "ratio": 1.5, "flag": true, "empty": null }),
        json!({ "a": { "b": [1, 2], "c": "hello" } }),
        json!({ "items": [{ "name": "a", "v": 1 }, { "name": "b", "v": 2 }] }),
        json!({ "seq": [], "map": {} }),
        json!({ "a": "yes", "b": "123", "c": "a: b", "d": "#hash", "e": "", "h": "null" }),
        json!([1, 2, 3]),
        json!("just a string"),
        json!({ "a": { "b": [] } }),
        json!({ "m": [[1, 2], [3, 4]] }),
        json!([[1, 2], [3, 4]]),
        json!({ "a": [["x"], { "k": "v" }] }),
        json!({ "created": "2024-01-01", "tags": ["a", "b"], "n": null }),
        json!({ "quote": "it's", "colon_end": "key:", "spaced": "  pad  " }),
    ];
    for case in cases {
        let ours = fig::to_string(&case).unwrap();
        let theirs = serde_yaml_ng::to_string(&case).unwrap();
        assert_eq!(ours, theirs, "mismatch for {case}");
    }
}

#[test]
fn serializes_typed_config() {
    #[derive(Serialize)]
    #[serde(rename_all = "snake_case")]
    #[allow(dead_code)]
    enum AccessState {
        Public,
        AccessControl,
    }
    #[derive(Serialize)]
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
    let ours = fig::to_string(&cfg).unwrap();
    let theirs = serde_yaml_ng::to_string(&cfg).unwrap();
    assert_eq!(ours, theirs);
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
