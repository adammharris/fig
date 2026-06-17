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
fn editor_sequence_ops() {
    let mut ed = Editor::open(b"items:\n- a\n- b\n", Format::Yaml).unwrap();
    ed.append(&[Segment::Key("items")], &"c").unwrap();
    ed.prepend(&[Segment::Key("items")], &"z").unwrap();
    ed.remove_item(&[Segment::Key("items")], 2).unwrap();
    // z, a, c  (original b at index 2 after prepend was removed)
    assert_eq!(ed.source().unwrap(), "items:\n- z\n- a\n- c\n");
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
    fm.replace(&[Segment::Key("title")], &"Hello world").unwrap();
    let rendered = fm.render().unwrap();
    // Everything except the title line is byte-identical to the original.
    let expected = NOTE.replace("title: Hello\n", "title: Hello world\n");
    assert_eq!(rendered, expected);
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
