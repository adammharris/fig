//! Comment-preserving editing of a config embedded in a host file.
//!
//! [`Embed`] opens the config region selected by an [`EmbedType`] — markdown
//! YAML frontmatter, JSON frontmatter, or YAML endmatter — and edits only that
//! block in its inner format. The fences and surrounding host text are left
//! byte-identical, and within the embed only the changed node's bytes move
//! (comments, key order, and formatting are preserved). This generalizes the
//! former YAML-frontmatter-only `Frontmatter`.
//!
//! Value-taking methods mirror [`crate::Editor`]: `*_value` take a [`Value`] and
//! are always available; the `serde`-gated forms accept any `Serialize`.

use std::ptr::NonNull;

use crate::editor::{Segment, borrow_str, to_ffi_keys, to_ffi_path};
use crate::error::Error;
use crate::value::{Value, value_text};
use crate::{Format, ffi};

/// Which embedded config to open. Each fixes both the host delimiters and the
/// inner format, mirroring fig's `Embed.Type`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EmbedType {
    /// `---` … `---` YAML frontmatter at the top of a markdown file.
    FrontmatterYaml,
    /// `;;;` … `;;;` JSON frontmatter at the top of a markdown file.
    FrontmatterJson,
    /// YAML in a trailing ```` ```endmatter ```` code block.
    EndmatterYaml,
}

impl EmbedType {
    fn ffi(self) -> ffi::FigEmbedType {
        match self {
            EmbedType::FrontmatterYaml => ffi::FigEmbedType::FrontmatterYaml,
            EmbedType::FrontmatterJson => ffi::FigEmbedType::FrontmatterJson,
            EmbedType::EndmatterYaml => ffi::FigEmbedType::EndmatterYaml,
        }
    }

    /// The inner format values are serialized to when spliced in.
    fn inner_format(self) -> Format {
        match self {
            EmbedType::FrontmatterYaml | EmbedType::EndmatterYaml => Format::Yaml,
            EmbedType::FrontmatterJson => Format::Json,
        }
    }
}

/// A half-open `[start, end)` byte range within the host file.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Span {
    pub start: usize,
    pub end: usize,
}

impl From<ffi::FigSpan> for Span {
    fn from(s: ffi::FigSpan) -> Self {
        Span { start: s.start, end: s.end }
    }
}

/// A located embed region in host-file byte coordinates (the content is not
/// parsed). `body` is the host prose outside the fences — the suffix after the
/// close fence for frontmatter, the prefix before the open fence for endmatter.
#[derive(Clone, Copy, Debug)]
pub struct Region {
    pub open_fence: Span,
    pub content: Span,
    pub close_fence: Span,
    pub body: Span,
}

/// The result of [`Embed::extract`]: a located [`Region`] plus the borrowed host
/// text, with helpers to slice out the embedded content and body without parsing
/// or copying.
#[derive(Clone, Copy, Debug)]
pub struct Extracted<'a> {
    source: &'a str,
    region: Region,
}

impl<'a> Extracted<'a> {
    /// The located region's byte spans.
    pub fn region(&self) -> Region {
        self.region
    }

    /// The raw config text between the fences (the embedded YAML/JSON); not parsed.
    pub fn content(&self) -> &'a str {
        &self.source[self.region.content.start..self.region.content.end]
    }

    /// The host body outside the fences (the markdown prose).
    pub fn body(&self) -> &'a str {
        &self.source[self.region.body.start..self.region.body.end]
    }
}

/// Split an embedded region of `kind` from its host body without parsing or
/// copying — the read-only `(content, body)` twin of opening an [`Embed`].
/// `None` when `content` has no such region (or its opening fence has no close).
/// Both slices borrow `content`: the first is the text between the fences (no
/// fences), the second is the host prose outside them.
pub fn split(content: &str, kind: EmbedType) -> Option<(&str, &str)> {
    let e = Embed::extract(content, kind).ok()?;
    Some((e.content(), e.body()))
}

/// An editor over an embedded config region of a host file.
#[derive(Debug)]
pub struct Embed {
    raw: NonNull<ffi::FigEmbed>,
    inner: Format,
}

impl Embed {
    /// Open the embed of `kind` in `host`. Returns [`Error::NotFound`] if no such
    /// region exists.
    pub fn open(host: &[u8], kind: EmbedType) -> Result<Self, Error> {
        let mut raw = std::ptr::null_mut();
        let status =
            unsafe { ffi::fig_embed_open(host.as_ptr(), host.len(), kind.ffi() as i32, &mut raw) };
        Error::from_status(status)?;
        let raw = NonNull::new(raw).ok_or(Error::Internal)?;
        Ok(Self {
            raw,
            inner: kind.inner_format(),
        })
    }

    /// Locate `kind`'s region in `content` and borrow its content/body slices
    /// without parsing or copying — the read-only counterpart to [`Embed::open`].
    /// [`Error::NotFound`] when no such region exists (or its fence is unterminated).
    pub fn extract(content: &str, kind: EmbedType) -> Result<Extracted<'_>, Error> {
        let mut region = ffi::FigRegion {
            size: core::mem::size_of::<ffi::FigRegion>() as u32,
            ..Default::default()
        };
        let status = unsafe {
            ffi::fig_embed_extract(content.as_ptr(), content.len(), kind.ffi() as i32, &mut region)
        };
        Error::from_status(status)?;
        Ok(Extracted {
            source: content,
            region: Region {
                open_fence: region.open_fence.into(),
                content: region.content.into(),
                close_fence: region.close_fence.into(),
                body: region.body.into(),
            },
        })
    }

    fn ptr(&self) -> *mut ffi::FigEmbed {
        self.raw.as_ptr()
    }

    // ── value edits (over `Value`) ──────────────────────────────────────────

    /// Replace the value at `path` with `value`.
    pub fn replace_value(&mut self, path: &[Segment], value: &Value) -> Result<(), Error> {
        let repl = value_text(value, self.inner)?;
        let p = to_ffi_path(path);
        let status = unsafe {
            ffi::fig_embed_replace_val(self.ptr(), p.as_ptr(), p.len(), repl.as_ptr(), repl.len())
        };
        Error::from_status(status)
    }

    /// Replace the key at `path` with `key`.
    pub fn replace_key(&mut self, path: &[Segment], key: &str) -> Result<(), Error> {
        let repl = value_text(&Value::Str(key.to_string()), self.inner)?;
        let p = to_ffi_path(path);
        let status = unsafe {
            ffi::fig_embed_replace_key(self.ptr(), p.as_ptr(), p.len(), repl.as_ptr(), repl.len())
        };
        Error::from_status(status)
    }

    /// Insert `key: value` into the mapping at `path` (empty path = root).
    pub fn insert_value(
        &mut self,
        path: &[Segment],
        key: &str,
        value: &Value,
    ) -> Result<(), Error> {
        let key_text = value_text(&Value::Str(key.to_string()), self.inner)?;
        let val = value_text(value, self.inner)?;
        let p = to_ffi_path(path);
        let status = unsafe {
            ffi::fig_embed_insert_key(
                self.ptr(),
                p.as_ptr(),
                p.len(),
                key_text.as_ptr(),
                key_text.len(),
                val.as_ptr(),
                val.len(),
            )
        };
        Error::from_status(status)
    }

    /// Upsert a mapping value: replace the value at `path`, or insert it when
    /// only the trailing key is absent. Folds the common
    /// `replace_value` → (on [`Error::NotFound`]) `insert_value` two-step into a
    /// single call. `path` must end in a key (it only ever creates a mapping
    /// entry); a missing intermediate container surfaces as [`Error::NotFound`].
    pub fn set_value(&mut self, path: &[Segment], value: &Value) -> Result<(), Error> {
        let val = value_text(value, self.inner)?;
        let p = to_ffi_path(path);
        let status =
            unsafe { ffi::fig_embed_set(self.ptr(), p.as_ptr(), p.len(), val.as_ptr(), val.len()) };
        Error::from_status(status)
    }

    /// Append `value` to the sequence at `path`.
    pub fn append_value(&mut self, path: &[Segment], value: &Value) -> Result<(), Error> {
        let val = value_text(value, self.inner)?;
        let p = to_ffi_path(path);
        let status = unsafe {
            ffi::fig_embed_append_seq(self.ptr(), p.as_ptr(), p.len(), val.as_ptr(), val.len())
        };
        Error::from_status(status)
    }

    /// Prepend `value` to the sequence at `path`.
    pub fn prepend_value(&mut self, path: &[Segment], value: &Value) -> Result<(), Error> {
        let val = value_text(value, self.inner)?;
        let p = to_ffi_path(path);
        let status = unsafe {
            ffi::fig_embed_prepend_seq(self.ptr(), p.as_ptr(), p.len(), val.as_ptr(), val.len())
        };
        Error::from_status(status)
    }

    // ── value edits (serde convenience) ─────────────────────────────────────

    /// Replace the value at `path` with the serialized form of `value`.
    #[cfg(feature = "serde")]
    pub fn replace<T: serde::Serialize + ?Sized>(
        &mut self,
        path: &[Segment],
        value: &T,
    ) -> Result<(), Error> {
        self.replace_value(path, &crate::ser::to_value(value)?)
    }

    /// Insert `key: value` into the mapping at `path` (empty path = root).
    #[cfg(feature = "serde")]
    pub fn insert<T: serde::Serialize + ?Sized>(
        &mut self,
        path: &[Segment],
        key: &str,
        value: &T,
    ) -> Result<(), Error> {
        self.insert_value(path, key, &crate::ser::to_value(value)?)
    }

    /// Upsert: replace the value at `path`, or insert it when only the trailing
    /// key is absent (see [`set_value`](Self::set_value)).
    #[cfg(feature = "serde")]
    pub fn set<T: serde::Serialize + ?Sized>(
        &mut self,
        path: &[Segment],
        value: &T,
    ) -> Result<(), Error> {
        self.set_value(path, &crate::ser::to_value(value)?)
    }

    /// Append the serialized form of `value` to the sequence at `path`.
    #[cfg(feature = "serde")]
    pub fn append<T: serde::Serialize + ?Sized>(
        &mut self,
        path: &[Segment],
        value: &T,
    ) -> Result<(), Error> {
        self.append_value(path, &crate::ser::to_value(value)?)
    }

    /// Prepend the serialized form of `value` to the sequence at `path`.
    #[cfg(feature = "serde")]
    pub fn prepend<T: serde::Serialize + ?Sized>(
        &mut self,
        path: &[Segment],
        value: &T,
    ) -> Result<(), Error> {
        self.prepend_value(path, &crate::ser::to_value(value)?)
    }

    // ── comment editing ─────────────────────────────────────────────────────

    /// Add an own-line comment ABOVE the node at `path`. Mirrors
    /// [`crate::Editor::add_leading_comment`] (YAML frontmatter uses `#`; JSON
    /// frontmatter is strict JSON and returns [`Error::UnsupportedFormat`]).
    pub fn add_leading_comment(&mut self, path: &[Segment], text: &str) -> Result<(), Error> {
        let p = to_ffi_path(path);
        let status = unsafe {
            ffi::fig_embed_add_leading_comment(self.ptr(), p.as_ptr(), p.len(), text.as_ptr(), text.len())
        };
        Error::from_status(status)
    }

    /// Set the same-line trailing comment on the value at `path`. Mirrors
    /// [`crate::Editor::set_trailing_comment`].
    pub fn set_trailing_comment(&mut self, path: &[Segment], text: &str) -> Result<(), Error> {
        let p = to_ffi_path(path);
        let status = unsafe {
            ffi::fig_embed_set_trailing_comment(self.ptr(), p.as_ptr(), p.len(), text.as_ptr(), text.len())
        };
        Error::from_status(status)
    }

    /// Remove the own-line comment block above the node at `path` (no-op if none).
    pub fn delete_leading_comments(&mut self, path: &[Segment]) -> Result<(), Error> {
        let p = to_ffi_path(path);
        let status = unsafe { ffi::fig_embed_delete_leading_comments(self.ptr(), p.as_ptr(), p.len()) };
        Error::from_status(status)
    }

    /// Remove the same-line trailing comment on the value at `path` (no-op if none).
    pub fn delete_trailing_comment(&mut self, path: &[Segment]) -> Result<(), Error> {
        let p = to_ffi_path(path);
        let status = unsafe { ffi::fig_embed_delete_trailing_comment(self.ptr(), p.as_ptr(), p.len()) };
        Error::from_status(status)
    }

    /// Read the own-line comment block above the node at `path` in the embedded
    /// config (markers stripped). `None` when absent, `Some("")` for a bare
    /// marker. Mirrors [`crate::Editor::leading_comment`].
    pub fn leading_comment(&self, path: &[Segment]) -> Result<Option<String>, Error> {
        self.read_comment(path, false)
    }

    /// Read the same-line trailing comment on the value at `path` in the embedded
    /// config (marker stripped). `None` when absent, `Some("")` for a bare marker.
    /// Mirrors [`crate::Editor::trailing_comment`].
    pub fn trailing_comment(&self, path: &[Segment]) -> Result<Option<String>, Error> {
        self.read_comment(path, true)
    }

    fn read_comment(&self, path: &[Segment], trailing: bool) -> Result<Option<String>, Error> {
        let p = to_ffi_path(path);
        let mut ptr: *const u8 = std::ptr::null();
        let mut len: usize = 0;
        let status = unsafe {
            if trailing {
                ffi::fig_embed_get_trailing_comment(self.ptr(), p.as_ptr(), p.len(), &mut ptr, &mut len)
            } else {
                ffi::fig_embed_get_leading_comment(self.ptr(), p.as_ptr(), p.len(), &mut ptr, &mut len)
            }
        };
        if status.0 == ffi::FigStatus::NOT_FOUND {
            return Ok(None);
        }
        Error::from_status(status)?;
        Ok(Some(borrow_str(ptr, len)?.to_string()))
    }

    // ── structural edits (no value) ─────────────────────────────────────────

    /// Delete the mapping entry named by `path`.
    pub fn delete(&mut self, path: &[Segment]) -> Result<(), Error> {
        let p = to_ffi_path(path);
        let status = unsafe { ffi::fig_embed_delete_key(self.ptr(), p.as_ptr(), p.len()) };
        Error::from_status(status)
    }

    /// Remove the item at `index` from the sequence at `path`.
    pub fn remove_item(&mut self, path: &[Segment], index: usize) -> Result<(), Error> {
        let p = to_ffi_path(path);
        let status =
            unsafe { ffi::fig_embed_remove_seq_item(self.ptr(), p.as_ptr(), p.len(), index) };
        Error::from_status(status)
    }

    /// Move the mapping entry at `src_path` to immediately before the entry at
    /// `dest_path`. Both must name keys in the same mapping. The moved entry
    /// keeps its owned comments; bytes between the two entries are preserved.
    pub fn move_key(&mut self, src_path: &[Segment], dest_path: &[Segment]) -> Result<(), Error> {
        let s = to_ffi_path(src_path);
        let d = to_ffi_path(dest_path);
        let status = unsafe {
            ffi::fig_embed_move_key(self.ptr(), s.as_ptr(), s.len(), d.as_ptr(), d.len())
        };
        Error::from_status(status)
    }

    /// Reorder the entries of the mapping at `path` (empty path = root) so
    /// `keys` come first in that order; entries whose key is not listed keep
    /// their original relative order and follow. Unknown keys are ignored. Each
    /// entry's comments and interleaved trivia are preserved.
    pub fn reorder_keys<S: AsRef<str>>(
        &mut self,
        path: &[Segment],
        keys: &[S],
    ) -> Result<(), Error> {
        let p = to_ffi_path(path);
        let k = to_ffi_keys(keys);
        let status = unsafe {
            ffi::fig_embed_reorder_keys(self.ptr(), p.as_ptr(), p.len(), k.as_ptr(), k.len())
        };
        Error::from_status(status)
    }

    /// Move the sequence item at index `from` to index `to` (array-move
    /// semantics). A block item keeps its owned comments; a flow sequence keeps
    /// its separators. No-op when `from == to`.
    pub fn move_item(&mut self, path: &[Segment], from: usize, to: usize) -> Result<(), Error> {
        let p = to_ffi_path(path);
        let status = unsafe { ffi::fig_embed_move_item(self.ptr(), p.as_ptr(), p.len(), from, to) };
        Error::from_status(status)
    }

    /// Reorder the items of the sequence at `path` so the items at `indices`
    /// (positions in the current order) come first, in that order; items not
    /// listed keep their original relative order and follow. Out-of-range
    /// indices are ignored.
    pub fn reorder_items(&mut self, path: &[Segment], indices: &[usize]) -> Result<(), Error> {
        let p = to_ffi_path(path);
        let status = unsafe {
            ffi::fig_embed_reorder_items(
                self.ptr(),
                p.as_ptr(),
                p.len(),
                indices.as_ptr(),
                indices.len(),
            )
        };
        Error::from_status(status)
    }

    /// Reconcile the sequence at `path` so its items are exactly `items`, while
    /// preserving the comments on items that survive the change (see
    /// [`Editor::set_sequence`](crate::Editor::set_sequence) for the full
    /// semantics). Declines with [`Error::InvalidArgument`] when the shape can't
    /// be safely diffed.
    pub fn set_sequence(&mut self, path: &[Segment], items: &[Value]) -> Result<(), Error> {
        let texts: Vec<String> = items
            .iter()
            .map(|v| value_text(v, self.inner))
            .collect::<Result<_, _>>()?;
        let strs = to_ffi_keys(&texts);
        let p = to_ffi_path(path);
        let status = unsafe {
            ffi::fig_embed_set_sequence(self.ptr(), p.as_ptr(), p.len(), strs.as_ptr(), strs.len())
        };
        Error::from_status(status)
    }

    /// Replace the host body — the prose the config is embedded in — with `body`,
    /// keeping the fences and the current (possibly edited) content byte-identical.
    /// The body is the suffix after the close fence (frontmatter) or the prefix
    /// before the open fence (endmatter); only that side is swapped. `body` is
    /// taken verbatim (not parsed); an empty `body` clears it. Composes with the
    /// value edits — change keys, replace the body, then [`render`](Self::render)
    /// once. Takes effect at the next render.
    pub fn replace_body(&mut self, body: &str) -> Result<(), Error> {
        let status =
            unsafe { ffi::fig_embed_replace_body(self.ptr(), body.as_ptr(), body.len()) };
        Error::from_status(status)
    }

    /// Render the full host file with the edited embed spliced back between the
    /// (untouched) fences. Borrows handle memory; invalidated by the next call
    /// or edit. Takes `&mut self` because the render buffer is rebuilt in place.
    pub fn render(&mut self) -> Result<&str, Error> {
        let mut ptr: *const u8 = std::ptr::null();
        let mut len: usize = 0;
        let status = unsafe { ffi::fig_embed_render(self.raw.as_ptr(), &mut ptr, &mut len) };
        Error::from_status(status)?;
        borrow_str(ptr, len)
    }
}

impl Drop for Embed {
    fn drop(&mut self) {
        unsafe { ffi::fig_embed_destroy(self.raw.as_ptr()) };
    }
}
