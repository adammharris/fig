//! Derive macros for the `fig` crate's `ToValue`/`FromValue` traits.
//!
//! These generate straight-line conversions to and from `fig::Value` — no
//! format-generic visitor machinery, so the emitted code stays small. The
//! macros are re-exported from `fig` behind its `derive` feature; depend on
//! `fig`, not on this crate directly.
//!
//! # Structs
//! Named-field, newtype (one field), and unit structs. Field attributes:
//! `#[fig(rename = "..")]`, `#[fig(skip)]`, `#[fig(flatten)]`, `#[fig(default)]`
//! or `#[fig(default = "path")]` (call `path()` for a missing key),
//! `#[fig(skip_serializing_if = "path")]` (omit from `ToValue` output when the
//! predicate `fn(&Field) -> bool` is true), and `#[fig(deserialize_with =
//! "path")]` (parse a present value with `path(&fig::Value) -> Result<Field,
//! fig::Error>`). `Option<_>` fields are optional
//! (absent key → `None`). The container attribute `#[fig(rename_all = "..")]`
//! applies a case rule (`camelCase`, `snake_case`, `PascalCase`, `kebab-case`,
//! and their SCREAMING variants, plus `lowercase`/`UPPERCASE`) to every field
//! name not carrying an explicit `rename`.
//!
//! # Enums
//! All four serde-style taggings, chosen by container attribute:
//! * external (default) — `"Variant"` / `{ "Variant": <content> }`
//! * internal — `#[fig(tag = "type")]` → `{ "type": "Variant", ..fields }`
//! * adjacent — `#[fig(tag = "type", content = "data")]`
//! * untagged — `#[fig(untagged)]` (first matching variant wins, in order)
//!
//! Variant shapes: unit, newtype, tuple, struct. Variant `#[fig(rename = "..")]`
//! is honored, and the container `#[fig(rename_all = "..")]` applies to variant
//! names (matching serde — it does not rename a struct-variant's inner fields).
//! Restrictions (matching/extending serde): tuple variants are not allowed with
//! internal tagging, and `#[fig(flatten)]` is not yet supported inside enum
//! variants.

use proc_macro::TokenStream;
use proc_macro2::TokenStream as TokenStream2;
use quote::quote;
use syn::{
    Data, DeriveInput, Fields, FieldsNamed, Generics, Ident, LitStr, Type, Variant,
    parse_macro_input,
};

#[proc_macro_derive(ToValue, attributes(fig))]
pub fn derive_to_value(input: TokenStream) -> TokenStream {
    let input = parse_macro_input!(input as DeriveInput);
    expand_to_value(&input)
        .unwrap_or_else(syn::Error::into_compile_error)
        .into()
}

#[proc_macro_derive(FromValue, attributes(fig))]
pub fn derive_from_value(input: TokenStream) -> TokenStream {
    let input = parse_macro_input!(input as DeriveInput);
    expand_from_value(&input)
        .unwrap_or_else(syn::Error::into_compile_error)
        .into()
}

// ============================================================================
// Attribute parsing
// ============================================================================

/// Case-conversion for `#[fig(rename_all = "..")]`, matching serde's rules.
///
/// Field names are assumed snake_case and variant names PascalCase, so the two
/// `apply_to_*` methods differ exactly as serde's do — this keeps generated keys
/// byte-identical to serde output (and therefore to ts-rs bindings).
#[derive(Clone, Copy)]
enum RenameRule {
    Lower,
    Upper,
    Pascal,
    Camel,
    Snake,
    ScreamingSnake,
    Kebab,
    ScreamingKebab,
}

impl RenameRule {
    fn from_str(s: &str) -> Result<Self, String> {
        Ok(match s {
            "lowercase" => RenameRule::Lower,
            "UPPERCASE" => RenameRule::Upper,
            "PascalCase" => RenameRule::Pascal,
            "camelCase" => RenameRule::Camel,
            "snake_case" => RenameRule::Snake,
            "SCREAMING_SNAKE_CASE" => RenameRule::ScreamingSnake,
            "kebab-case" => RenameRule::Kebab,
            "SCREAMING-KEBAB-CASE" => RenameRule::ScreamingKebab,
            other => {
                return Err(format!(
                    "unknown `rename_all` rule `{other}` (expected one of: lowercase, \
                     UPPERCASE, PascalCase, camelCase, snake_case, SCREAMING_SNAKE_CASE, \
                     kebab-case, SCREAMING-KEBAB-CASE)"
                ));
            }
        })
    }

    /// Apply to a snake_case field name.
    fn apply_to_field(self, field: &str) -> String {
        match self {
            RenameRule::Lower | RenameRule::Snake => field.to_owned(),
            RenameRule::Upper | RenameRule::ScreamingSnake => field.to_ascii_uppercase(),
            RenameRule::Pascal => {
                let mut out = String::new();
                let mut capitalize = true;
                for ch in field.chars() {
                    if ch == '_' {
                        capitalize = true;
                    } else if capitalize {
                        out.push(ch.to_ascii_uppercase());
                        capitalize = false;
                    } else {
                        out.push(ch);
                    }
                }
                out
            }
            RenameRule::Camel => {
                let pascal = RenameRule::Pascal.apply_to_field(field);
                match pascal.char_indices().nth(1) {
                    Some((i, _)) => pascal[..1].to_ascii_lowercase() + &pascal[i..],
                    None => pascal.to_ascii_lowercase(),
                }
            }
            RenameRule::Kebab => field.replace('_', "-"),
            RenameRule::ScreamingKebab => field.to_ascii_uppercase().replace('_', "-"),
        }
    }

    /// Apply to a PascalCase variant name.
    fn apply_to_variant(self, variant: &str) -> String {
        match self {
            RenameRule::Pascal => variant.to_owned(),
            RenameRule::Lower => variant.to_ascii_lowercase(),
            RenameRule::Upper => variant.to_ascii_uppercase(),
            RenameRule::Camel => match variant.char_indices().nth(1) {
                Some((i, _)) => variant[..1].to_ascii_lowercase() + &variant[i..],
                None => variant.to_ascii_lowercase(),
            },
            RenameRule::Snake => {
                let mut out = String::new();
                for (i, ch) in variant.char_indices() {
                    if i > 0 && ch.is_uppercase() {
                        out.push('_');
                    }
                    out.push(ch.to_ascii_lowercase());
                }
                out
            }
            RenameRule::ScreamingSnake => {
                RenameRule::Snake.apply_to_variant(variant).to_ascii_uppercase()
            }
            RenameRule::Kebab => RenameRule::Snake.apply_to_variant(variant).replace('_', "-"),
            RenameRule::ScreamingKebab => RenameRule::ScreamingSnake
                .apply_to_variant(variant)
                .replace('_', "-"),
        }
    }
}

/// Parsed `#[fig(..)]` attributes on a single field.
#[derive(Default)]
struct FieldAttrs {
    rename: Option<String>,
    skip: bool,
    flatten: bool,
    default: bool,
    /// `#[fig(default = "path")]` — call `path()` for a missing key instead of
    /// `Default::default()`. Mirrors serde's `default = ".."`.
    default_path: Option<syn::Path>,
    /// `#[fig(skip_serializing_if = "path")]` — predicate `fn(&Field) -> bool`
    /// that, when true, omits the field from `ToValue` output.
    skip_serializing_if: Option<syn::Path>,
    /// `#[fig(deserialize_with = "path")]` — parse a present value with
    /// `path(&fig::Value) -> Result<Field, fig::Error>` instead of the field
    /// type's `FromValue`. Mirrors serde's `deserialize_with`.
    deserialize_with: Option<syn::Path>,
    /// `#[fig(alias = "old")]` — additional key(s) accepted when reading, tried
    /// in order after the primary key. Mirrors serde's `alias`.
    aliases: Vec<String>,
}

fn parse_field_attrs(attrs: &[syn::Attribute]) -> syn::Result<FieldAttrs> {
    let mut parsed = FieldAttrs::default();
    for attr in attrs {
        if !attr.path().is_ident("fig") {
            continue;
        }
        attr.parse_nested_meta(|meta| {
            if meta.path.is_ident("rename") {
                parsed.rename = Some(meta.value()?.parse::<LitStr>()?.value());
            } else if meta.path.is_ident("skip") {
                parsed.skip = true;
            } else if meta.path.is_ident("flatten") {
                parsed.flatten = true;
            } else if meta.path.is_ident("default") {
                // Bare `default` (use `Default`) or `default = "path"` (call fn).
                if let Ok(value) = meta.value() {
                    parsed.default_path = Some(value.parse::<LitStr>()?.parse::<syn::Path>()?);
                } else {
                    parsed.default = true;
                }
            } else if meta.path.is_ident("skip_serializing_if") {
                let path = meta.value()?.parse::<LitStr>()?.parse::<syn::Path>()?;
                parsed.skip_serializing_if = Some(path);
            } else if meta.path.is_ident("deserialize_with") {
                let path = meta.value()?.parse::<LitStr>()?.parse::<syn::Path>()?;
                parsed.deserialize_with = Some(path);
            } else if meta.path.is_ident("alias") {
                parsed.aliases.push(meta.value()?.parse::<LitStr>()?.value());
            } else {
                return Err(meta.error(
                    "unknown `fig` field attribute (expected: rename, skip, flatten, \
                     default, skip_serializing_if, deserialize_with, alias)",
                ));
            }
            Ok(())
        })?;
    }
    Ok(parsed)
}

/// Parsed `#[fig(..)]` attributes on a variant.
#[derive(Default)]
struct VariantAttrs {
    rename: Option<String>,
}

fn parse_variant_attrs(attrs: &[syn::Attribute]) -> syn::Result<VariantAttrs> {
    let mut parsed = VariantAttrs::default();
    for attr in attrs {
        if !attr.path().is_ident("fig") {
            continue;
        }
        attr.parse_nested_meta(|meta| {
            if meta.path.is_ident("rename") {
                parsed.rename = Some(meta.value()?.parse::<LitStr>()?.value());
            } else {
                return Err(meta.error("unknown `fig` variant attribute (expected: rename)"));
            }
            Ok(())
        })?;
    }
    Ok(parsed)
}

/// Parsed `#[fig(..)]` attributes on a struct or enum container.
#[derive(Default)]
struct ContainerAttrs {
    rename_all: Option<RenameRule>,
    tag: Option<String>,
    content: Option<String>,
    untagged: bool,
}

fn parse_container_attrs(attrs: &[syn::Attribute]) -> syn::Result<ContainerAttrs> {
    let mut parsed = ContainerAttrs::default();
    for attr in attrs {
        if !attr.path().is_ident("fig") {
            continue;
        }
        attr.parse_nested_meta(|meta| {
            if meta.path.is_ident("rename_all") {
                let lit = meta.value()?.parse::<LitStr>()?;
                let rule = RenameRule::from_str(&lit.value())
                    .map_err(|msg| syn::Error::new(lit.span(), msg))?;
                parsed.rename_all = Some(rule);
            } else if meta.path.is_ident("tag") {
                parsed.tag = Some(meta.value()?.parse::<LitStr>()?.value());
            } else if meta.path.is_ident("content") {
                parsed.content = Some(meta.value()?.parse::<LitStr>()?.value());
            } else if meta.path.is_ident("untagged") {
                parsed.untagged = true;
            } else {
                return Err(meta.error(
                    "unknown `fig` container attribute (expected: rename_all, tag, content, untagged)",
                ));
            }
            Ok(())
        })?;
    }
    Ok(parsed)
}

/// The container-level `rename_all` rule, if any.
fn container_rename_all(attrs: &[syn::Attribute]) -> syn::Result<Option<RenameRule>> {
    Ok(parse_container_attrs(attrs)?.rename_all)
}

/// How an enum's variants are distinguished on the wire.
enum Tagging {
    External,
    Internal(String),
    Adjacent(String, String),
    Untagged,
}

fn tagging_of(input: &DeriveInput) -> syn::Result<Tagging> {
    let c = parse_container_attrs(&input.attrs)?;
    match (c.untagged, c.tag, c.content) {
        (true, None, None) => Ok(Tagging::Untagged),
        (true, _, _) => Err(syn::Error::new_spanned(
            input,
            "`#[fig(untagged)]` cannot be combined with `tag`/`content`",
        )),
        (false, Some(tag), Some(content)) => Ok(Tagging::Adjacent(tag, content)),
        (false, Some(tag), None) => Ok(Tagging::Internal(tag)),
        (false, None, Some(_)) => Err(syn::Error::new_spanned(
            input,
            "`#[fig(content = ..)]` requires `#[fig(tag = ..)]`",
        )),
        (false, None, None) => Ok(Tagging::External),
    }
}

// ============================================================================
// Shared field model
// ============================================================================

struct FieldInfo<'a> {
    ident: &'a Ident,
    ty: &'a Type,
    /// Serialized key (rename or field name). Unused for flattened fields.
    key: String,
    skip: bool,
    flatten: bool,
    /// Whether a missing key falls back to a default instead of erroring.
    use_default: bool,
    /// `default = "path"` function to call for a missing key (overrides the
    /// plain `Default::default()` fallback).
    default_path: Option<syn::Path>,
    /// `skip_serializing_if` predicate path, omitting the field from output
    /// when it returns `true`.
    skip_serializing_if: Option<syn::Path>,
    /// `deserialize_with` function to parse a present value.
    deserialize_with: Option<syn::Path>,
    /// Alternate keys accepted when reading (after the primary key).
    aliases: Vec<String>,
}

/// Collect a struct/variant's named fields. `rename_all` (the container rule, if
/// any) is applied to each field name unless the field carries an explicit
/// `#[fig(rename = "..")]`, which always wins.
fn collect_named_fields(
    fields: &FieldsNamed,
    rename_all: Option<RenameRule>,
) -> syn::Result<Vec<FieldInfo<'_>>> {
    let mut infos = Vec::with_capacity(fields.named.len());
    for field in &fields.named {
        let attrs = parse_field_attrs(&field.attrs)?;
        if attrs.flatten && attrs.rename.is_some() {
            return Err(syn::Error::new_spanned(
                field,
                "`#[fig(flatten)]` and `#[fig(rename)]` are mutually exclusive",
            ));
        }
        let ident = field.ident.as_ref().expect("named field has an ident");
        let key = match attrs.rename {
            Some(explicit) => explicit,
            None => match rename_all {
                Some(rule) => rule.apply_to_field(&ident.to_string()),
                None => ident.to_string(),
            },
        };
        let use_default = attrs.default || attrs.default_path.is_some() || is_option(&field.ty);
        infos.push(FieldInfo {
            ident,
            ty: &field.ty,
            key,
            skip: attrs.skip,
            flatten: attrs.flatten,
            use_default,
            default_path: attrs.default_path,
            skip_serializing_if: attrs.skip_serializing_if,
            deserialize_with: attrs.deserialize_with,
            aliases: attrs.aliases,
        });
    }
    Ok(infos)
}

/// Heuristic: does this type's final path segment read as `Option`? Good enough
/// to make `Option<T>` fields optional without an explicit `#[fig(default)]`.
fn is_option(ty: &Type) -> bool {
    matches!(ty, Type::Path(tp) if tp.qself.is_none()
        && tp.path.segments.last().is_some_and(|s| s.ident == "Option"))
}

/// Rebuild the where-clause adding `T: <bound>` for every generic type param.
fn bounded_where(generics: &Generics, bound: TokenStream2) -> TokenStream2 {
    let mut preds: Vec<TokenStream2> = Vec::new();
    if let Some(existing) = &generics.where_clause {
        for p in &existing.predicates {
            preds.push(quote!(#p));
        }
    }
    for tp in generics.type_params() {
        let id = &tp.ident;
        preds.push(quote!(#id: #bound));
    }
    if preds.is_empty() {
        quote!()
    } else {
        quote!(where #(#preds),*)
    }
}

/// The wire key for an enum variant. An explicit `#[fig(rename = "..")]` wins;
/// otherwise the container `rename_all` rule (if any) is applied.
fn variant_key(variant: &Variant, rename_all: Option<RenameRule>) -> syn::Result<String> {
    let attrs = parse_variant_attrs(&variant.attrs)?;
    Ok(match attrs.rename {
        Some(explicit) => explicit,
        None => match rename_all {
            Some(rule) => rule.apply_to_variant(&variant.ident.to_string()),
            None => variant.ident.to_string(),
        },
    })
}

// ============================================================================
// ToValue
// ============================================================================

fn expand_to_value(input: &DeriveInput) -> syn::Result<TokenStream2> {
    let name = &input.ident;
    let (impl_g, ty_g, _) = input.generics.split_for_impl();
    let where_clause = bounded_where(&input.generics, quote!(fig::ToValue));

    let body = match &input.data {
        Data::Struct(s) => to_value_struct(&s.fields, input)?,
        Data::Enum(e) => to_value_enum(input, e)?,
        Data::Union(_) => {
            return Err(syn::Error::new_spanned(
                input,
                "fig's ToValue derive does not support unions",
            ));
        }
    };

    Ok(quote! {
        impl #impl_g fig::ToValue for #name #ty_g #where_clause {
            fn to_value(&self) -> fig::Value {
                #body
            }
        }
    })
}

fn to_value_struct(fields: &Fields, input: &DeriveInput) -> syn::Result<TokenStream2> {
    match fields {
        Fields::Named(named) => {
            let infos = collect_named_fields(named, container_rename_all(&input.attrs)?)?;
            let stmts = infos.iter().filter(|f| !f.skip).map(|f| {
                let ident = f.ident;
                if f.flatten {
                    quote! {
                        if let fig::Value::Map(mut __m) = fig::ToValue::to_value(&self.#ident) {
                            __entries.append(&mut __m);
                        }
                    }
                } else {
                    let key = &f.key;
                    let push = quote! {
                        __entries.push((
                            fig::Value::Str(::std::string::String::from(#key)),
                            fig::ToValue::to_value(&self.#ident),
                        ));
                    };
                    match &f.skip_serializing_if {
                        Some(pred) => quote! {
                            if !#pred(&self.#ident) { #push }
                        },
                        None => push,
                    }
                }
            });
            Ok(quote! {
                let mut __entries: ::std::vec::Vec<(fig::Value, fig::Value)> = ::std::vec::Vec::new();
                #(#stmts)*
                fig::Value::Map(__entries)
            })
        }
        Fields::Unnamed(unnamed) if unnamed.unnamed.len() == 1 => {
            Ok(quote! { fig::ToValue::to_value(&self.0) })
        }
        Fields::Unnamed(_) => Err(syn::Error::new_spanned(
            input,
            "fig's ToValue derive supports newtype structs (one field) but not multi-field tuple structs yet",
        )),
        Fields::Unit => Ok(quote! { fig::Value::Null }),
    }
}

fn to_value_enum(input: &DeriveInput, data: &syn::DataEnum) -> syn::Result<TokenStream2> {
    let tagging = tagging_of(input)?;
    let rename_all = container_rename_all(&input.attrs)?;
    let mut arms = Vec::with_capacity(data.variants.len());
    for variant in &data.variants {
        arms.push(to_value_variant_arm(variant, &tagging, rename_all)?);
    }
    Ok(quote! {
        match self {
            #(#arms)*
        }
    })
}

/// Build one `match self` arm for an enum variant's `ToValue`.
fn to_value_variant_arm(
    variant: &Variant,
    tagging: &Tagging,
    rename_all: Option<RenameRule>,
) -> syn::Result<TokenStream2> {
    let vident = &variant.ident;
    let key = variant_key(variant, rename_all)?;
    let key_value = quote! { fig::Value::Str(::std::string::String::from(#key)) };

    // Destructuring pattern + the "content" Value expression for non-unit shapes.
    let (pattern, content): (TokenStream2, Option<TokenStream2>) = match &variant.fields {
        Fields::Unit => (quote! { Self::#vident }, None),
        Fields::Unnamed(u) if u.unnamed.len() == 1 => (
            quote! { Self::#vident(__f0) },
            Some(quote! { fig::ToValue::to_value(__f0) }),
        ),
        Fields::Unnamed(u) => {
            let binds: Vec<Ident> = (0..u.unnamed.len())
                .map(|i| Ident::new(&format!("__f{i}"), vident.span()))
                .collect();
            (
                quote! { Self::#vident( #(#binds),* ) },
                Some(quote! { fig::Value::Seq(vec![ #(fig::ToValue::to_value(#binds)),* ]) }),
            )
        }
        Fields::Named(named) => {
            // serde applies the container `rename_all` to variant *names*, not
            // to a struct-variant's fields (that is serde's separate
            // `rename_all_fields`, not implemented here), so pass `None`.
            let infos = collect_named_fields(named, None)?;
            if let Some(f) = infos.iter().find(|f| f.flatten) {
                return Err(syn::Error::new_spanned(
                    f.ident,
                    "`#[fig(flatten)]` is not supported inside enum variants yet",
                ));
            }
            let binds: Vec<Ident> = infos
                .iter()
                .map(|f| Ident::new(&format!("__f_{}", f.ident), f.ident.span()))
                .collect();
            let pat_fields = infos.iter().zip(&binds).map(|(f, b)| {
                let id = f.ident;
                quote! { #id: #b }
            });
            let entry_stmts = infos.iter().zip(&binds).filter(|(f, _)| !f.skip).map(|(f, b)| {
                let fkey = &f.key;
                let push = quote! {
                    __vmap.push((
                        fig::Value::Str(::std::string::String::from(#fkey)),
                        fig::ToValue::to_value(#b),
                    ));
                };
                match &f.skip_serializing_if {
                    Some(pred) => quote! { if !#pred(#b) { #push } },
                    None => push,
                }
            });
            (
                quote! { Self::#vident { #(#pat_fields),* } },
                Some(quote! {{
                    let mut __vmap: ::std::vec::Vec<(fig::Value, fig::Value)> =
                        ::std::vec::Vec::new();
                    #(#entry_stmts)*
                    fig::Value::Map(__vmap)
                }}),
            )
        }
    };

    let is_tuple_multi = matches!(&variant.fields, Fields::Unnamed(u) if u.unnamed.len() > 1);

    let body = match tagging {
        Tagging::External => match &content {
            None => quote! { #key_value },
            Some(c) => quote! { fig::Value::Map(vec![(#key_value, #c)]) },
        },
        Tagging::Adjacent(tag, content_key) => match &content {
            None => quote! {
                fig::Value::Map(vec![(
                    fig::Value::Str(::std::string::String::from(#tag)),
                    #key_value,
                )])
            },
            Some(c) => quote! {
                fig::Value::Map(vec![
                    (fig::Value::Str(::std::string::String::from(#tag)), #key_value),
                    (fig::Value::Str(::std::string::String::from(#content_key)), #c),
                ])
            },
        },
        Tagging::Internal(tag) => {
            if is_tuple_multi {
                return Err(syn::Error::new_spanned(
                    variant,
                    "internally tagged enums do not support tuple variants (matching serde); use adjacent or external tagging",
                ));
            }
            match &content {
                None => quote! {
                    fig::Value::Map(vec![(
                        fig::Value::Str(::std::string::String::from(#tag)),
                        #key_value,
                    )])
                },
                // struct/newtype: merge the content map alongside the tag. A
                // newtype whose inner is not a mapping cannot be merged here
                // (serde rejects it at runtime); we keep just the tag.
                Some(c) => quote! {
                    {
                        let mut __entries: ::std::vec::Vec<(fig::Value, fig::Value)> = vec![(
                            fig::Value::Str(::std::string::String::from(#tag)),
                            #key_value,
                        )];
                        if let fig::Value::Map(mut __m) = #c {
                            __entries.append(&mut __m);
                        }
                        fig::Value::Map(__entries)
                    }
                },
            }
        }
        Tagging::Untagged => match &content {
            None => quote! { fig::Value::Null },
            Some(c) => quote! { #c },
        },
    };

    Ok(quote! { #pattern => #body, })
}

// ============================================================================
// FromValue
// ============================================================================

fn expand_from_value(input: &DeriveInput) -> syn::Result<TokenStream2> {
    let name = &input.ident;
    let (impl_g, ty_g, _) = input.generics.split_for_impl();
    let where_clause = bounded_where(&input.generics, quote!(fig::FromValue));

    let body = match &input.data {
        Data::Struct(s) => from_value_struct(&s.fields, name, input)?,
        Data::Enum(e) => from_value_enum(input, e)?,
        Data::Union(_) => {
            return Err(syn::Error::new_spanned(
                input,
                "fig's FromValue derive does not support unions",
            ));
        }
    };

    Ok(quote! {
        impl #impl_g fig::FromValue for #name #ty_g #where_clause {
            fn from_value(value: &fig::Value) -> ::core::result::Result<Self, fig::Error> {
                #body
            }
        }
    })
}

fn from_value_struct(
    fields: &Fields,
    name: &Ident,
    input: &DeriveInput,
) -> syn::Result<TokenStream2> {
    match fields {
        Fields::Named(named) => from_map_named(
            named,
            &quote! { Self },
            &quote! { value },
            &name.to_string(),
            true,
            container_rename_all(&input.attrs)?,
        ),
        Fields::Unnamed(unnamed) if unnamed.unnamed.len() == 1 => {
            let ty = &unnamed.unnamed[0].ty;
            Ok(quote! {
                ::core::result::Result::Ok(Self(<#ty as fig::FromValue>::from_value(value)?))
            })
        }
        Fields::Unnamed(_) => Err(syn::Error::new_spanned(
            input,
            "fig's FromValue derive supports newtype structs (one field) but not multi-field tuple structs yet",
        )),
        Fields::Unit => Ok(quote! { ::core::result::Result::Ok(Self) }),
    }
}

/// Build `Result<Self, Error>` from a mapping value, for a named-field struct or
/// struct variant. `ctor` is `Self` or `Self::Variant`; `map_value` is an
/// expression evaluating to `&fig::Value`.
fn from_map_named(
    fields: &FieldsNamed,
    ctor: &TokenStream2,
    map_value: &TokenStream2,
    type_label: &str,
    allow_flatten: bool,
    rename_all: Option<RenameRule>,
) -> syn::Result<TokenStream2> {
    let infos = collect_named_fields(fields, rename_all)?;
    if !allow_flatten && let Some(f) = infos.iter().find(|f| f.flatten) {
        return Err(syn::Error::new_spanned(
            f.ident,
            "`#[fig(flatten)]` is not supported inside enum variants yet",
        ));
    }

    let known_keys: Vec<&String> = infos
        .iter()
        .filter(|f| !f.skip && !f.flatten)
        .map(|f| &f.key)
        .collect();
    let has_flatten = infos.iter().any(|f| f.flatten && !f.skip);

    let rest = if has_flatten {
        quote! {
            const __KNOWN: &[&str] = &[#(#known_keys),*];
            let mut __rest: ::std::vec::Vec<(fig::Value, fig::Value)> = ::std::vec::Vec::new();
            for (__k, __v) in __entries.iter() {
                let __consumed = matches!(__k, fig::Value::Str(__s) if __KNOWN.contains(&__s.as_str()));
                if !__consumed {
                    __rest.push((__k.clone(), __v.clone()));
                }
            }
            let __rest = fig::Value::Map(__rest);
        }
    } else {
        quote! {}
    };

    let field_lets = infos.iter().map(|f| {
        let ident = f.ident;
        let ty = f.ty;
        if f.skip {
            return quote! { let #ident: #ty = ::core::default::Default::default(); };
        }
        if f.flatten {
            return quote! {
                let #ident: #ty = <#ty as fig::FromValue>::from_value(&__rest)?;
            };
        }
        let key = &f.key;

        // Common case — no alias, no custom `deserialize_with`, no custom
        // default path — routes through the shared `fig::field`/`field_or_default`
        // helpers. The lookup/convert/error scaffold is then compiled once per
        // field *type* and shared, instead of inlined at every field site (the
        // bulk of large derived `from_value` bodies, e.g. `Command`).
        if f.aliases.is_empty() && f.deserialize_with.is_none() && f.default_path.is_none() {
            if f.use_default {
                return quote! { let #ident: #ty = fig::field_or_default(__entries, #key)?; };
            }
            return quote! { let #ident: #ty = fig::field(__entries, #key, #type_label)?; };
        }

        let missing = match &f.default_path {
            Some(path) => quote! { #path() },
            None if f.use_default => quote! { ::core::default::Default::default() },
            None => {
                quote! { return ::core::result::Result::Err(fig::Error::missing_field(#key, #type_label)) }
            }
        };
        let present = match &f.deserialize_with {
            Some(path) => quote! { #path(__v)? },
            None => quote! { <#ty as fig::FromValue>::from_value(__v)? },
        };
        let aliases = &f.aliases;
        quote! {
            let #ident: #ty = match fig::map_get(__entries, #key)
                #(.or_else(|| fig::map_get(__entries, #aliases)))*
            {
                ::std::option::Option::Some(__v) => #present,
                ::std::option::Option::None => #missing,
            };
        }
    });

    let field_names = infos.iter().map(|f| f.ident);

    Ok(quote! {{
        let __entries = match #map_value {
            fig::Value::Map(__e) => __e,
            _ => return ::core::result::Result::Err(
                fig::Error::expected_mapping(#type_label),
            ),
        };
        let _ = &__entries;
        #rest
        #(#field_lets)*
        ::core::result::Result::Ok(#ctor { #(#field_names),* })
    }})
}

/// Build `Result<Self, Error>` for a non-unit variant from a `&fig::Value`
/// expression `value_expr`, used wherever the variant's *content* is parsed
/// (external map value, adjacent content, untagged whole value).
fn build_variant(
    variant: &Variant,
    value_expr: &TokenStream2,
    label: &str,
) -> syn::Result<TokenStream2> {
    let vident = &variant.ident;
    match &variant.fields {
        Fields::Unit => Ok(quote! { ::core::result::Result::Ok(Self::#vident) }),
        Fields::Unnamed(u) if u.unnamed.len() == 1 => {
            let ty = &u.unnamed[0].ty;
            Ok(quote! {
                ::core::result::Result::Ok(Self::#vident(<#ty as fig::FromValue>::from_value(#value_expr)?))
            })
        }
        Fields::Unnamed(u) => {
            let tys: Vec<&Type> = u.unnamed.iter().map(|f| &f.ty).collect();
            let idxs: Vec<usize> = (0..tys.len()).collect();
            let n = tys.len();
            let seq_msg = format!("expected a sequence for tuple variant `{label}`");
            Ok(quote! {{
                let __items = match #value_expr {
                    fig::Value::Seq(__s) => __s,
                    _ => return ::core::result::Result::Err(
                        fig::Error::msg_static(#seq_msg),
                    ),
                };
                if __items.len() != #n {
                    return ::core::result::Result::Err(
                        fig::Error::wrong_seq_len(#label, #n, __items.len()),
                    );
                }
                ::core::result::Result::Ok(Self::#vident(
                    #(<#tys as fig::FromValue>::from_value(&__items[#idxs])?),*
                ))
            }})
        }
        Fields::Named(named) => from_map_named(
            named,
            &quote! { Self::#vident },
            value_expr,
            label,
            false,
            None,
        ),
    }
}

fn from_value_enum(input: &DeriveInput, data: &syn::DataEnum) -> syn::Result<TokenStream2> {
    let tagging = tagging_of(input)?;
    let rename_all = container_rename_all(&input.attrs)?;
    let enum_name = input.ident.to_string();
    match tagging {
        Tagging::External => from_value_external(data, &enum_name, rename_all),
        Tagging::Internal(tag) => from_value_internal(data, &enum_name, &tag, rename_all),
        Tagging::Adjacent(tag, content) => {
            from_value_adjacent(data, &enum_name, &tag, &content, rename_all)
        }
        Tagging::Untagged => from_value_untagged(data, &enum_name),
    }
}

fn from_value_external(
    data: &syn::DataEnum,
    enum_name: &str,
    rename_all: Option<RenameRule>,
) -> syn::Result<TokenStream2> {
    let mut unit_arms = Vec::new();
    let mut map_arms = Vec::new();
    for variant in &data.variants {
        let vident = &variant.ident;
        let key = variant_key(variant, rename_all)?;
        let label = format!("{enum_name}::{vident}");
        if matches!(variant.fields, Fields::Unit) {
            unit_arms.push(quote! { #key => ::core::result::Result::Ok(Self::#vident), });
        } else {
            let body = build_variant(variant, &quote! { __v }, &label)?;
            map_arms.push(quote! { #key => #body, });
        }
    }
    let expected = format!("expected a string or single-key mapping for enum `{enum_name}`");
    Ok(quote! {
        match value {
            fig::Value::Str(__s) => match __s.as_str() {
                #(#unit_arms)*
                __other => ::core::result::Result::Err(fig::Error::unknown_variant(#enum_name, __other)),
            },
            fig::Value::Map(__entries) if __entries.len() == 1 => {
                let (__k, __v) = &__entries[0];
                let __name = match __k {
                    fig::Value::Str(__s) => __s.as_str(),
                    _ => return ::core::result::Result::Err(
                        fig::Error::msg_static("enum variant key must be a string"),
                    ),
                };
                match __name {
                    #(#map_arms)*
                    __other => ::core::result::Result::Err(fig::Error::unknown_variant(#enum_name, __other)),
                }
            }
            _ => ::core::result::Result::Err(fig::Error::msg_static(#expected)),
        }
    })
}

/// Shared prologue for internal/adjacent tagging: bind `__entries` (the mapping)
/// and `__tag` (the tag string), or return an error.
fn tag_prologue(enum_name: &str, tag: &str) -> TokenStream2 {
    let not_map = format!("expected a mapping for tagged enum `{enum_name}`");
    let missing_tag = format!("missing tag `{tag}` for enum `{enum_name}`");
    let tag_kind = format!("tag `{tag}` for enum `{enum_name}` must be a string");
    quote! {
        let __entries = match value {
            fig::Value::Map(__e) => __e,
            _ => return ::core::result::Result::Err(
                fig::Error::msg_static(#not_map),
            ),
        };
        let __tag = match __entries.iter().rev().find_map(|(__k, __v)| match __k {
            fig::Value::Str(__s) if __s == #tag => ::std::option::Option::Some(__v),
            _ => ::std::option::Option::None,
        }) {
            ::std::option::Option::Some(fig::Value::Str(__s)) => __s.as_str(),
            ::std::option::Option::Some(_) => return ::core::result::Result::Err(
                fig::Error::msg_static(#tag_kind),
            ),
            ::std::option::Option::None => return ::core::result::Result::Err(
                fig::Error::msg_static(#missing_tag),
            ),
        };
    }
}

fn from_value_internal(
    data: &syn::DataEnum,
    enum_name: &str,
    tag: &str,
    rename_all: Option<RenameRule>,
) -> syn::Result<TokenStream2> {
    let mut arms = Vec::new();
    for variant in &data.variants {
        let vident = &variant.ident;
        let key = variant_key(variant, rename_all)?;
        let label = format!("{enum_name}::{vident}");
        let arm = match &variant.fields {
            Fields::Unit => quote! { #key => ::core::result::Result::Ok(Self::#vident), },
            Fields::Named(named) => {
                // Fields live in the same map as the tag; look them up directly.
                let body = from_map_named(
                    named,
                    &quote! { Self::#vident },
                    &quote! { value },
                    &label,
                    false,
                    None,
                )?;
                quote! { #key => #body, }
            }
            Fields::Unnamed(u) if u.unnamed.len() == 1 => {
                // Newtype: feed the inner type the map minus the tag entry.
                let ty = &u.unnamed[0].ty;
                quote! {
                    #key => {
                        let mut __rest: ::std::vec::Vec<(fig::Value, fig::Value)> = ::std::vec::Vec::new();
                        for (__k, __v) in __entries.iter() {
                            let __is_tag = matches!(__k, fig::Value::Str(__s) if __s == #tag);
                            if !__is_tag {
                                __rest.push((__k.clone(), __v.clone()));
                            }
                        }
                        ::core::result::Result::Ok(Self::#vident(
                            <#ty as fig::FromValue>::from_value(&fig::Value::Map(__rest))?,
                        ))
                    }
                }
            }
            Fields::Unnamed(_) => {
                return Err(syn::Error::new_spanned(
                    variant,
                    "internally tagged enums do not support tuple variants (matching serde)",
                ));
            }
        };
        arms.push(arm);
    }
    let prologue = tag_prologue(enum_name, tag);
    Ok(quote! {
        #prologue
        match __tag {
            #(#arms)*
            __other => ::core::result::Result::Err(fig::Error::unknown_variant(#enum_name, __other)),
        }
    })
}

fn from_value_adjacent(
    data: &syn::DataEnum,
    enum_name: &str,
    tag: &str,
    content: &str,
    rename_all: Option<RenameRule>,
) -> syn::Result<TokenStream2> {
    let mut arms = Vec::new();
    for variant in &data.variants {
        let vident = &variant.ident;
        let key = variant_key(variant, rename_all)?;
        let label = format!("{enum_name}::{vident}");
        if matches!(variant.fields, Fields::Unit) {
            arms.push(quote! { #key => ::core::result::Result::Ok(Self::#vident), });
        } else {
            let body = build_variant(variant, &quote! { __content_val }, &label)?;
            let missing = format!("missing content `{content}` for variant `{label}`");
            arms.push(quote! {
                #key => {
                    let __content_val = match __content {
                        ::std::option::Option::Some(__c) => __c,
                        ::std::option::Option::None => return ::core::result::Result::Err(
                            fig::Error::msg_static(#missing),
                        ),
                    };
                    #body
                }
            });
        }
    }
    let prologue = tag_prologue(enum_name, tag);
    Ok(quote! {
        #prologue
        let __content: ::std::option::Option<&fig::Value> =
            __entries.iter().rev().find_map(|(__k, __v)| match __k {
                fig::Value::Str(__s) if __s == #content => ::std::option::Option::Some(__v),
                _ => ::std::option::Option::None,
            });
        match __tag {
            #(#arms)*
            __other => ::core::result::Result::Err(fig::Error::unknown_variant(#enum_name, __other)),
        }
    })
}

fn from_value_untagged(data: &syn::DataEnum, enum_name: &str) -> syn::Result<TokenStream2> {
    let mut attempts = Vec::new();
    for variant in &data.variants {
        let vident = &variant.ident;
        let label = format!("{enum_name}::{vident}");
        if matches!(variant.fields, Fields::Unit) {
            attempts.push(quote! {
                if matches!(value, fig::Value::Null) {
                    return ::core::result::Result::Ok(Self::#vident);
                }
            });
        } else {
            let body = build_variant(variant, &quote! { value }, &label)?;
            attempts.push(quote! {
                if let ::core::result::Result::Ok(__v) =
                    (|| -> ::core::result::Result<Self, fig::Error> { #body })()
                {
                    return ::core::result::Result::Ok(__v);
                }
            });
        }
    }
    let none = format!("no variant of enum `{enum_name}` matched the value");
    Ok(quote! {
        #(#attempts)*
        ::core::result::Result::Err(fig::Error::msg_static(#none))
    })
}
