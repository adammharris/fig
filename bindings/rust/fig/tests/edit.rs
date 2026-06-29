//! Comment-preserving write-path tests: edits must change only the targeted
//! node's bytes and leave comments, key order, fences, and the markdown body
//! intact.

use fig::{Editor, Embed, Format, Segment};

#[test]
fn editor_insert_appends_after_last_entry() {
    let mut ed = Editor::open(b"a: 1\nb: 2\n", Format::Yaml).unwrap();
    ed.insert(&[], "c", &3).unwrap();
    assert_eq!(ed.source().unwrap(), "a: 1\nb: 2\nc: 3\n");
}

#[test]
fn editor_replace_quotes_when_needed() {
    let mut ed = Editor::open(b"title: Hello\n", Format::Yaml).unwrap();
    ed.replace(&[Segment::Key("title")], &"has: colon").unwrap();
    // Reads back as the same logical value.
    let value: std::collections::BTreeMap<String, String> =
        fig::from_str(ed.source().unwrap()).unwrap();
    assert_eq!(value["title"], "has: colon");
}

#[test]
fn editor_delete_keeps_owned_comment_with_key() {
    let mut ed = Editor::open(b"a: 1\n# note for b\nb: 2\nc: 3\n", Format::Yaml).unwrap();
    ed.delete(&[Segment::Key("b")]).unwrap();
    assert_eq!(ed.source().unwrap(), "a: 1\nc: 3\n");
}

#[test]
fn editor_reads_comments_distinguishing_absent_from_empty() {
    // `a` has both a leading block and a trailing comment; `b` has a bare `#`
    // trailing (present but empty); `c` has neither (absent).
    let ed = Editor::open(b"# why\na: 1 # two\nb: 2 #\nc: 3\n", Format::Yaml).unwrap();

    assert_eq!(ed.leading_comment(&[Segment::Key("a")]).unwrap().as_deref(), Some("why"));
    assert_eq!(ed.trailing_comment(&[Segment::Key("a")]).unwrap().as_deref(), Some("two"));

    // Present-but-empty bare marker → Some(""), not None.
    assert_eq!(ed.trailing_comment(&[Segment::Key("b")]).unwrap().as_deref(), Some(""));

    // No comment at all → None.
    assert_eq!(ed.leading_comment(&[Segment::Key("c")]).unwrap(), None);
    assert_eq!(ed.trailing_comment(&[Segment::Key("c")]).unwrap(), None);
}

#[test]
fn editor_reads_trailing_comment_on_a_block_collection_key() {
    // The comment rides the `contents:` line above the block sequence.
    let ed = Editor::open(b"contents: # the list\n- one\n- two\n", Format::Yaml).unwrap();
    assert_eq!(
        ed.trailing_comment(&[Segment::Key("contents")]).unwrap().as_deref(),
        Some("the list"),
    );
}

#[test]
fn editor_sequence_ops() {
    let mut ed = Editor::open(b"items:\n- a\n- b\n", Format::Yaml).unwrap();
    ed.append(&[Segment::Key("items")], &"c").unwrap();
    ed.prepend(&[Segment::Key("items")], &"z").unwrap();
    ed.remove_item(&[Segment::Key("items")], 2).unwrap();
    // z, a, c  (original b at index 2 after prepend was removed)
    assert_eq!(ed.source().unwrap(), "items:\n- z\n- a\n- c\n");
}

#[test]
fn editor_set_sequence_reconciles_preserving_comments() {
    use fig::Value;
    let mut ed = Editor::open(
        b"tags:\n- a # first\n- b # second\n- c # third\n",
        Format::Yaml,
    )
    .unwrap();
    // -> [c, a, d]: drop b, add d, reorder. Survivors keep their comments.
    let target = [
        Value::Str("c".into()),
        Value::Str("a".into()),
        Value::Str("d".into()),
    ];
    ed.set_sequence(&[Segment::Key("tags")], &target).unwrap();
    assert_eq!(
        ed.source().unwrap(),
        "tags:\n- c # third\n- a # first\n- d\n",
    );
}

#[test]
fn editor_set_sequence_declines_empty_target() {
    let mut ed = Editor::open(b"tags:\n- a\n- b\n", Format::Yaml).unwrap();
    let err = ed.set_sequence(&[Segment::Key("tags")], &[]).unwrap_err();
    assert!(matches!(err, fig::Error::InvalidArgument));
    // Document untouched on a declined reconcile.
    assert_eq!(ed.source().unwrap(), "tags:\n- a\n- b\n");
}

#[test]
fn frontmatter_set_sequence_preserves_item_comments_and_body() {
    use fig::Value;
    const DOC: &str = "\
---
title: Hello
tags:
- a # alpha
- b # beta
- c # gamma
---
# Body

prose goes here
";
    let mut fm = Embed::frontmatter(DOC.as_bytes()).unwrap();
    let target = [
        Value::Str("c".into()),
        Value::Str("a".into()),
        Value::Str("d".into()),
    ];
    fm.set_sequence(&[Segment::Key("tags")], &target).unwrap();
    let expected = "\
---
title: Hello
tags:
- c # gamma
- a # alpha
- d
---
# Body

prose goes here
";
    assert_eq!(fm.render().unwrap(), expected);
}

const NOTE: &str = "\
---
title: Hello
# keep this comment
tags:
- a
- b
---
# Body

prose goes here
";

#[test]
fn frontmatter_preserves_comments_fences_and_body() {
    let mut fm = Embed::frontmatter(NOTE.as_bytes()).unwrap();
    fm.replace(&[Segment::Key("title")], &"Hi there").unwrap();
    fm.append(&[Segment::Key("tags")], &"c").unwrap();
    fm.insert(&[], "author", &"me").unwrap();

    let expected = "\
---
title: Hi there
# keep this comment
tags:
- a
- b
- c
author: me
---
# Body

prose goes here
";
    assert_eq!(fm.render().unwrap(), expected);
}

#[test]
fn frontmatter_edit_touches_only_target_bytes() {
    let mut fm = Embed::frontmatter(NOTE.as_bytes()).unwrap();
    fm.replace(&[Segment::Key("title")], &"Hello world")
        .unwrap();
    let rendered = fm.render().unwrap();
    // Everything except the title line is byte-identical to the original.
    let expected = NOTE.replace("title: Hello\n", "title: Hello world\n");
    assert_eq!(rendered, expected);
}

#[test]
fn split_frontmatter_borrows_frontmatter_and_body() {
    let (fm, body) = fig::split_frontmatter(NOTE).unwrap();
    assert_eq!(fm, "title: Hello\n# keep this comment\ntags:\n- a\n- b\n");
    assert_eq!(body, "# Body\n\nprose goes here\n");
    // CRLF fences are handled (Diaryx's hand-rolled split special-cased these).
    let crlf = "---\r\nk: v\r\n---\r\nbody\r\n";
    let (fm, body) = fig::split_frontmatter(crlf).unwrap();
    assert_eq!(fm, "k: v\r\n");
    assert_eq!(body, "body\r\n");
    // No frontmatter -> None.
    assert_eq!(fig::split_frontmatter("# just markdown\n"), None);
    // Unterminated fence -> None (not a panic / partial split).
    assert_eq!(fig::split_frontmatter("---\nk: v\nno close\n"), None);
}

#[test]
fn extract_exposes_region_spans_and_slices() {
    use fig::EmbedType;
    let e = fig::Embed::extract(NOTE, EmbedType::FrontmatterYaml).unwrap();
    assert_eq!(e.frontmatter(), "title: Hello\n# keep this comment\ntags:\n- a\n- b\n");
    assert_eq!(e.body(), "# Body\n\nprose goes here\n");
    let r = e.region();
    // The body span starts at the close fence's end.
    assert_eq!(r.body.start, r.close_fence.end);
}

#[test]
fn frontmatter_replace_body_keeps_frontmatter_byte_identical() {
    let mut fm = Embed::frontmatter(NOTE.as_bytes()).unwrap();
    fm.replace_body("# New Body\n").unwrap();
    let rendered = fm.render().unwrap();
    // Frontmatter block (fences + content + comments) is verbatim; only body swapped.
    let (orig_fm, _) = fig::split_frontmatter(NOTE).unwrap();
    let (new_fm, new_body) = fig::split_frontmatter(rendered).unwrap();
    assert_eq!(new_fm, orig_fm);
    assert_eq!(new_body, "# New Body\n");
}

#[test]
fn frontmatter_replace_body_composes_with_edits() {
    let mut fm = Embed::frontmatter(NOTE.as_bytes()).unwrap();
    fm.replace(&[Segment::Key("title")], &"Hi there").unwrap();
    fm.replace_body("# New Body\n").unwrap();
    let rendered = fm.render().unwrap();
    let (new_fm, new_body) = fig::split_frontmatter(rendered).unwrap();
    assert!(new_fm.starts_with("title: Hi there\n"));
    assert!(new_fm.contains("# keep this comment")); // comment preserved
    assert_eq!(new_body, "# New Body\n");
}

#[test]
fn frontmatter_open_without_frontmatter_is_not_found() {
    let err = Embed::frontmatter(b"# just markdown\n").unwrap_err();
    assert!(matches!(err, fig::Error::NotFound));
}

#[test]
fn frontmatter_delete_then_read_back() {
    let mut fm = Embed::frontmatter(NOTE.as_bytes()).unwrap();
    fm.delete(&[Segment::Key("title")]).unwrap();
    let rendered = fm.render().unwrap().to_string();
    assert!(!rendered.contains("title:"));
    assert!(rendered.contains("# keep this comment"));
    assert!(rendered.contains("prose goes here"));
}

#[test]
fn frontmatter_reads_a_leading_comment() {
    let fm = Embed::frontmatter(NOTE.as_bytes()).unwrap();
    // `# keep this comment` sits above `tags` in the frontmatter.
    assert_eq!(
        fm.leading_comment(&[Segment::Key("tags")]).unwrap().as_deref(),
        Some("keep this comment"),
    );
    // `title` has no comment of its own.
    assert_eq!(fm.leading_comment(&[Segment::Key("title")]).unwrap(), None);
    assert_eq!(fm.trailing_comment(&[Segment::Key("title")]).unwrap(), None);
}

#[test]
fn json5_editor_replaces_value_preserving_comments_and_unquoted_keys() {
    // JSON5 routes through the JSON editor in the JSON5 dialect. The edit splices
    // only the `8080` value node; unquoted keys, single quotes, the `//` comments,
    // and the trailing comma all stay byte-identical.
    let src = "{\n  // server config\n  host: 'localhost',\n  port: 8080, // default\n}\n";
    let mut ed = Editor::open(src.as_bytes(), Format::Json5).unwrap();
    ed.replace(&[Segment::Key("port")], &9090).unwrap();
    assert_eq!(
        ed.source().unwrap(),
        "{\n  // server config\n  host: 'localhost',\n  port: 9090, // default\n}\n",
    );
}

#[test]
fn json5_editor_delete_keeps_owned_line_comment_with_key() {
    let src = "{\n  host: 'localhost',\n  // the listening port\n  port: 8080,\n}\n";
    let mut ed = Editor::open(src.as_bytes(), Format::Json5).unwrap();
    ed.delete(&[Segment::Key("port")]).unwrap();
    assert_eq!(ed.source().unwrap(), "{\n  host: 'localhost',\n}\n");
}

#[test]
fn toml_editor_renders_value_splice_as_toml_not_yaml() {
    // Splice text is rendered in the editor's own format. A replacement string
    // value must come out quoted (`"b"`) for TOML; the previous hardcoded-YAML
    // path emitted a bare `b`, which is not a valid TOML value and failed the
    // reparse. Integers are format-invariant, so `port` exercises the plain path.
    let mut ed = Editor::open(b"[server]\nhost = \"a\"\nport = 1\n", Format::Toml).unwrap();
    ed.replace(&[Segment::Key("server"), Segment::Key("host")], "b")
        .unwrap();
    ed.replace(&[Segment::Key("server"), Segment::Key("port")], &9090)
        .unwrap();
    assert_eq!(
        ed.source().unwrap(),
        "[server]\nhost = \"b\"\nport = 9090\n",
    );
}

#[test]
fn json_editor_rejects_json5_only_syntax() {
    // Sanity: the strict JSON dialect still refuses JSON5 input, so `Format::Json5`
    // is a real, distinct selection and not just an alias.
    assert!(Editor::open(b"{ host: 'localhost' }", Format::Json).is_err());
    assert!(Editor::open(b"{ host: 'localhost' }", Format::Json5).is_ok());
}

#[test]
fn json_frontmatter_edits_in_json() {
    // The same selector opens `;;;` JSON frontmatter; values serialize as JSON.
    let md = ";;;\n{\"title\": \"Hi\", \"draft\": true}\n;;;\n# Body\n";
    let mut em = fig::Embed::open(md.as_bytes(), fig::EmbedType::FrontmatterJson).unwrap();
    em.replace(&[Segment::Key("title")], &"Hello").unwrap();
    assert_eq!(
        em.render().unwrap(),
        ";;;\n{\"title\": \"Hello\", \"draft\": true}\n;;;\n# Body\n",
    );
}
