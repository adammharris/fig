import { test } from "node:test";
import assert from "node:assert/strict";

import {
  Document,
  Editor,
  Embed,
  EmbedType,
  ExtKind,
  FigError,
  Format,
  NodeKind,
  Status,
  V,
  fromJS,
  parse,
  serialize,
  toJS,
} from "../src/index.ts";

test("parse to plain JS across formats", () => {
  assert.deepEqual(parse('{"name":"fig","n":42}', Format.Json), { name: "fig", n: 42 });
  assert.deepEqual(parse("name: fig\ntags:\n- a\n- b\n", Format.Yaml), { name: "fig", tags: ["a", "b"] });
  assert.deepEqual(parse("name = \"fig\"\nn = 7\n", Format.Toml), { name: "fig", n: 7 });
  assert.deepEqual(parse(".{ .name = \"fig\", .n = 3 }", Format.Zon), { name: "fig", n: 3 });
});

test("Document low-level traversal", () => {
  using doc = Document.parse("title: Hello\ncount: 42\n", Format.Yaml);
  const root = doc.root();
  assert.notEqual(root, null);
  assert.equal(doc.kind(root!), NodeKind.Mapping);
  assert.equal(doc.childCount(root!), 2);

  const first = doc.firstChild(root!)!;
  assert.equal(doc.kind(first), NodeKind.KeyValue);
  assert.equal(doc.asString(doc.keyOf(first)!), "title");
  assert.equal(doc.asString(doc.valueOf(first)!), "Hello");

  const second = doc.nextSibling(first)!;
  const countVal = doc.valueOf(second)!;
  assert.equal(doc.kind(countVal), NodeKind.Int);
  assert.equal(doc.asNumberRaw(countVal), "42");
});

test("extended scalars (TOML datetime, ZON enum/char) read faithfully", () => {
  // TOML datetimes report as String at the `kind` ABI but recover via asExtended.
  {
    using doc = Document.parse("d = 2026-06-18\nt = 07:32:00\n", Format.Toml);
    const root = doc.root()!;
    const dVal = doc.valueOf(doc.firstChild(root)!)!;
    assert.equal(doc.kind(dVal), NodeKind.String);
    assert.deepEqual(doc.asExtended(dVal), { ext: ExtKind.LocalDate, text: "2026-06-18" });

    assert.deepEqual(doc.toValue(), V.map([
      [V.string("d"), V.extended(ExtKind.LocalDate, "2026-06-18")],
      [V.string("t"), V.extended(ExtKind.LocalTime, "07:32:00")],
    ]));
    // Round-trips back out through serialize.
    assert.equal(serialize(doc.toValue(), Format.Toml), "d = 2026-06-18\nt = 07:32:00\n");
  }

  // ZON char literals report as Int; enum literals as String. Both recover.
  {
    using doc = Document.parse(".{ .mode = .fast, .c = 'a' }", Format.Zon);
    assert.deepEqual(doc.toValue(), V.map([
      [V.string("mode"), V.extended(ExtKind.EnumLiteral, "fast")],
      [V.string("c"), V.extended(ExtKind.CharLiteral, "97")],
    ]));
  }

  // A plain string is not extended.
  {
    using doc = Document.parse("s = \"hi\"\n", Format.Toml);
    assert.equal(doc.asExtended(doc.valueOf(doc.firstChild(doc.root()!)!)!), null);
  }
});

test("serialize a Value to multiple formats", () => {
  const value = V.map([
    [V.string("name"), V.string("fig")],
    [V.string("nums"), V.seq([V.int(1), V.int(2)])],
  ]);
  assert.equal(serialize(value, Format.Json), '{\n  "name": "fig",\n  "nums": [\n    1,\n    2\n  ]\n}\n');
  assert.equal(serialize(value, Format.Yaml), "name: fig\nnums:\n- 1\n- 2\n");
});

test("serialize honors JSON pretty/compact options", () => {
  const value = V.map([
    [V.string("name"), V.string("fig")],
    [V.string("nums"), V.seq([V.int(1), V.int(2)])],
  ]);
  // No options == pretty default.
  assert.equal(serialize(value, Format.Json, {}), serialize(value, Format.Json));
  // Compact: no insignificant whitespace.
  assert.equal(serialize(value, Format.Json, { pretty: false }), '{"name":"fig","nums":[1,2]}\n');
  // Custom indent width.
  assert.equal(
    serialize(value, Format.Json, { indent: 4 }),
    '{\n    "name": "fig",\n    "nums": [\n        1,\n        2\n    ]\n}\n',
  );
  // ZON honors pretty/compact too (keeping its idiomatic four-space indent).
  assert.equal(serialize(value, Format.Zon, { pretty: false }), ".{ .name = \"fig\", .nums = .{ 1, 2 } }\n");
});

test("fromJS / toJS round-trip", () => {
  const js = { a: 1, b: [true, null, "x"], c: { d: 3.5 } };
  assert.deepEqual(toJS(fromJS(js)), js);
});

test("serialize rejects an unrepresentable value cleanly", () => {
  const value = V.map([[V.string("k"), V.null()]]);
  assert.equal(serialize(value, Format.Json), '{\n  "k": null\n}\n');
  assert.throws(
    () => serialize(value, Format.Toml),
    (err: unknown) => err instanceof FigError && err.status === Status.UnsupportedFormat,
  );
});

test("large integers survive as bigint", () => {
  const big = 9999999999999999999n; // > Number.MAX_SAFE_INTEGER and > i64
  assert.equal(serialize(V.uint(big), Format.Json), `${big}\n`);
  const round = toJS(fromJS(big));
  assert.equal(typeof round, "bigint");
  assert.equal(round, big);
});

test("Editor inserts while preserving the rest", () => {
  using ed = Editor.open("a: 1\nb: 2\n", Format.Yaml);
  ed.insertValue([], "c", 3);
  assert.equal(ed.source(), "a: 1\nb: 2\nc: 3\n");
});

test("Editor preserves comments on reorder", () => {
  using ed = Editor.open("title: Hi\n# keep\ntags:\n- x\nauthor: me\n", Format.Yaml);
  ed.reorderKeys([], ["author", "title"]);
  assert.equal(ed.source(), "author: me\ntitle: Hi\n# keep\ntags:\n- x\n");
});

test("Editor edits an empty document", () => {
  using ed = Editor.open("", Format.Yaml);
  ed.insertValue([], "k", "v");
  assert.equal(ed.source(), "k: v\n");
});

test("Embed edits YAML frontmatter, fences and body intact", () => {
  using fm = Embed.frontmatter("---\ntitle: Hi\n# keep\ntags:\n- x\n---\n# Body\ntext\n");
  fm.insertValue([], "author", "me");
  fm.appendValue(["tags"], "y");
  assert.equal(
    fm.render(),
    "---\ntitle: Hi\n# keep\ntags:\n- x\n- y\nauthor: me\n---\n# Body\ntext\n",
  );
});

test("Embed edits JSON frontmatter via raw text", () => {
  using fm = Embed.open(';;;\n{"title": "Hi", "draft": true}\n;;;\n# Body\n', EmbedType.FrontmatterJson);
  fm.replaceValueRaw(["title"], '"Hello"');
  assert.equal(fm.render(), ';;;\n{"title": "Hello", "draft": true}\n;;;\n# Body\n');
});

test("Embed.extract locates the region", () => {
  const md = "---\nk: v\n---\nbody\n";
  const region = Embed.extract(md, EmbedType.FrontmatterYaml);
  assert.equal(md.slice(region.content.start, region.content.end), "k: v\n");
});

test("parse error surfaces as FigError", () => {
  assert.throws(
    () => Document.parse("{ not valid", Format.Json),
    (err: unknown) => err instanceof FigError && err.status === Status.ParseError,
  );
});
