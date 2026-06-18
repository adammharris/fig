// Public enums and the error type, shared across the binding.
import { Status } from "./ffi.ts";

export { Status };

/** A config format. Parsing and editing support `Json`/`Jsonc`/`Yaml`;
 *  serialization additionally supports `Toml`/`Zon`. Values match the C ABI. */
export enum Format {
  Json = 1,
  Jsonc = 2,
  Yaml = 3,
  Toml = 4,
  Zon = 5,
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

/** A format-specific scalar kind (TOML datetimes, ZON enum/char literals). */
export enum ExtKind {
  OffsetDateTime = 0,
  LocalDateTime = 1,
  LocalDate = 2,
  LocalTime = 3,
  EnumLiteral = 4,
  CharLiteral = 5,
}

/** An embedded region within a host file (e.g. markdown frontmatter). */
export enum EmbedType {
  FrontmatterYaml = 0,
  FrontmatterJson = 1,
  EndmatterYaml = 2,
}

const STATUS_MESSAGE: Record<number, string> = {
  [Status.InvalidArgument]: "invalid argument",
  [Status.ParseError]: "parse error",
  [Status.OutOfMemory]: "out of memory",
  [Status.UnsupportedFormat]: "unsupported format",
  [Status.NotFound]: "not found",
  [Status.InternalError]: "internal error",
};

/** An error carrying the originating fig {@link Status} code. */
export class FigError extends Error {
  readonly status: Status;
  constructor(status: Status, op?: string) {
    const detail = STATUS_MESSAGE[status] ?? `status ${status}`;
    super(op ? `${op}: ${detail}` : detail);
    this.name = "FigError";
    this.status = status;
  }
}

/** Throw a {@link FigError} unless `status` is `Ok`. */
export function check(status: number, op?: string): void {
  if (status !== Status.Ok) throw new FigError(status, op);
}
