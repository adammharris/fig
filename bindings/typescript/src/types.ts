// Public enums and the error type, shared across the binding.
import { Status } from "./ffi.ts";

export { Status };

/** A config format. `Json`/`Jsonc`/`Json5`/`Yaml`/`Toml`/`Fig` parse, edit, and
 *  serialize in the module published to npm. `Zon` is fully editable too — full
 *  parity with the other formats — but is **not compiled into the default
 *  published wasm module**; it's left out to keep the inlined payload smaller,
 *  since it's the newest format and the least likely to be needed by a typical
 *  consumer. Build with `FIG_WASM_ZON=1 npm run build:wasm` to get a module
 *  with ZON support, and call {@link capabilities} at runtime rather than
 *  assuming which module you're running. Values match the C ABI (`Json5 = 7`
 *  is appended, leaving a gap at the reader-only `Xml = 6`; `Fig` is appended
 *  after it for the same reason). */
export enum Format {
  Json = 1,
  Jsonc = 2,
  Yaml = 3,
  Toml = 4,
  Zon = 5,
  Json5 = 7,
  /** The native `fig` authoring dialect (see `src/languages/fig/DESIGN.md` in
   *  the core repo) — a memorable, typeable surface over the same AST. */
  Fig = 8,
  /** INI (`[section]` + `key = value`). Read/edit/serialize. Untyped-string
   *  scalars: `port = 8080` reads back as the string "8080". */
  Ini = 9,
  /** dotenv / `.env` (flat `KEY=value`). Read/edit/serialize. Flat string map
   *  only — no nesting, untyped scalars (serialize surfaces a diagnostic when
   *  a nested value cannot be represented). */
  Dotenv = 10,
  /** Java `.properties` (flat `key=value`). Read/edit/serialize. Same flat,
   *  untyped limits as {@link Format.Dotenv}. */
  Properties = 11,
  /** Apple XML property list. Read/edit/serialize. Typed and nested
   *  (dict/array/string/integer/real/bool, date/data via the extended scalar). */
  Plist = 12,
  /** NestedText (https://nestedtext.org). Read/edit/serialize. Nested
   *  (dict/list) but deliberately untyped — every leaf is a string. */
  Nestedtext = 13,
}

/** Controls how {@link serialize} renders output. Omitted fields fall back to
 *  fig's historical style (pretty-printed, two-space indent), so passing no
 *  options renders exactly as before. `pretty` is honored by `Format.Json`
 *  (multi-line vs. minified), `Format.Zon` (`zig fmt` multi-line vs. inline
 *  `.{ a, b }`), and `Format.Toml` (gates array wrapping); `indent` by
 *  `Format.Json` and `Format.Toml`'s wrapped arrays; `width` by `Format.Toml`'s
 *  inline-vs-section layout. `Format.Yaml` renders with its own fixed layout. */
export interface SerializeOptions {
  /** `true` (default): multi-line, indented output. `false`: compact
   *  single-line output with no insignificant whitespace. For TOML, `false`
   *  keeps every array on one line; `true` lets a wide array wrap (see `width`). */
  pretty?: boolean;
  /** Spaces per indentation level when `pretty` (JSON, and TOML's wrapped
   *  arrays). Defaults to 2. */
  indent?: number;
  /** Drop comments carried on the value instead of emitting them. Defaults to
   *  `false` (preserve where the target format allows). */
  stripComments?: boolean;
  /** `Document.serialize` only: preserve values the target cannot represent
   *  natively (a null in TOML, a TOML datetime in JSON, …) through a `$fig`
   *  envelope, and decode any such envelope in the source. Defaults to `false`
   *  (lossy — an unrepresentable value throws `UnsupportedFormat`). Ignored by
   *  the value `serialize` (a built value has no source envelopes). */
  lossless?: boolean;
  /** `Format.Toml` only: the column budget for its inline-vs-expanded layout. A
   *  mapping/array that renders within `width` columns stays inline
   *  (`k = { … }` / `[a, b]`); a wider one expands to a `[section]` / a wrapped
   *  array. Defaults to `80`. Ignored by the other formats. */
  width?: number;
}

/** The kind of an AST node reached during read-path traversal. */
export enum NodeKind {
  Invalid = -1,
  Null = 0,
  Bool = 1,
  Int = 2,
  Float = 3,
  String = 4,
  Sequence = 5,
  Mapping = 6,
  KeyValue = 7,
  Alias = 8,
}

/** A format-specific scalar kind (TOML datetimes, ZON enum/char literals, JSON5
 *  non-finite numbers). */
export enum ExtKind {
  OffsetDateTime = 0,
  LocalDateTime = 1,
  LocalDate = 2,
  LocalTime = 3,
  EnumLiteral = 4,
  CharLiteral = 5,
  /** A non-finite JSON5 number (`Infinity`/`-Infinity`/`NaN`). */
  NumberSpecial = 6,
}

/** What kind of loss a {@link Warning} describes. Mirrors `FigWarningCode`. */
export enum WarningCode {
  /** A carried comment is not emitted at all. */
  CommentDropped = 0,
  /** A block comment is rendered as a run of line comments. */
  CommentStyleDegraded = 1,
  /** A node is removed entirely (the target cannot represent it even degraded). */
  ValueDropped = 2,
  /** An extended/non-finite value is rendered as a poorer type. */
  TypeDegraded = 3,
}

/** Why a {@link Warning}'s loss happens. Mirrors `FigWarningCause`. */
export enum WarningCause {
  /** The target format inherently cannot represent it. */
  FormatLimitation = 0,
  /** A caller option forced it (e.g. `stripComments`). */
  ExplicitOption = 1,
}

/** One lossy event reported by `Document.diagnose` / value `diagnose`. `code`
 *  and `cause` carry the raw ABI value; a value not listed in the enums above is
 *  a forward-compatible addition from a newer core (compare numerically). */
export interface Warning {
  code: WarningCode;
  cause: WarningCause;
  /** Dotted / `[i]` location; empty for the document root. */
  path: string;
  /** Degraded-to type for {@link WarningCode.TypeDegraded}, else empty. */
  note: string;
}

/** An embedded region within a host file (e.g. markdown frontmatter). */
export enum EmbedType {
  // Values 0–3 are ABI-frozen; historical names kept (FrontmatterJson is `;;;`,
  // FrontmatterFig is the ```fig fenced block).
  FrontmatterYaml = 0, // ---            markdown frontmatter, YAML
  FrontmatterJson = 1, // ;;;            JSON frontmatter
  EndmatterYaml = 2, //   ```endmatter   trailing YAML block
  FrontmatterFig = 3, //  ```fig         fenced fig block
  PlusToml = 4, //        +++            TOML frontmatter (Hugo/Zola)
  // Fenced ```<lang> code blocks.
  FencedYaml = 5,
  FencedJson = 6,
  FencedToml = 7,
  // Markdown ---<lang> frontmatter (bare --- is FrontmatterYaml above).
  MdFrontmatterJson = 8,
  MdFrontmatterToml = 9,
  MdFrontmatterFig = 10,
  // HTML <script type="application/<lang>"> data islands.
  HtmlScriptFig = 11,
  HtmlScriptYaml = 12,
  HtmlScriptJson = 13,
  HtmlScriptToml = 14,
}

const STATUS_MESSAGE: Record<number, string> = {
  [Status.InvalidArgument]: "invalid argument",
  [Status.ParseError]: "parse error",
  [Status.OutOfMemory]: "out of memory",
  [Status.UnsupportedFormat]: "unsupported format",
  [Status.NotFound]: "not found",
  [Status.InternalError]: "internal error",
};

/** Extra detail from a parse failure (`fig_parse_ex` / `FigError`). `byteOffset`/
 *  `line`/`column` are present only when the core reports them (not yet — offset
 *  plumbing is a planned core follow-up). */
export interface ParseDetail {
  message?: string | undefined;
  byteOffset?: number | undefined;
  line?: number | undefined;
  column?: number | undefined;
}

/** An error carrying the originating fig {@link Status} code, plus (for parse
 *  failures) the core's message and source location when available. */
export class FigError extends Error {
  readonly status: Status;
  readonly byteOffset?: number | undefined;
  readonly line?: number | undefined;
  readonly column?: number | undefined;
  constructor(status: Status, op?: string, detail?: ParseDetail) {
    const base = detail?.message && detail.message.length > 0
      ? detail.message
      : (STATUS_MESSAGE[status] ?? `status ${status}`);
    const loc = detail?.line != null && detail?.column != null
      ? ` (line ${detail.line}, column ${detail.column})`
      : detail?.byteOffset != null
        ? ` (byte offset ${detail.byteOffset})`
        : "";
    super((op ? `${op}: ${base}` : base) + loc);
    this.name = "FigError";
    this.status = status;
    this.byteOffset = detail?.byteOffset;
    this.line = detail?.line;
    this.column = detail?.column;
  }
}

/** Throw a {@link FigError} unless `status` is `Ok`. */
export function check(status: number, op?: string): void {
  if (status !== Status.Ok) throw new FigError(status, op);
}
