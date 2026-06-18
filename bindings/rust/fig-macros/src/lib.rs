//! Derive macros for the `fig` crate's `ToValue`/`FromValue` traits.
//!
//! These generate straight-line conversions to and from `fig::Value` — no
//! format-generic visitor machinery, so the emitted code stays small. The
//! macros are re-exported from `fig` behind its `derive` feature; depend on
//! `fig`, not on this crate directly.
//!
//! Supported shapes (v1): named-field structs, newtype structs, and unit
//! structs. Field attributes: `#[fig(rename = "..")]`, `#[fig(skip)]`,
//! `#[fig(flatten)]`, `#[fig(default)]`. `Option<_>` fields are treated as
//! optional (absent key → `None`). Enums and multi-field tuple structs are not
//! yet supported and produce a compile error.

use proc_macro::TokenStream;
use proc_macro2::TokenStream as TokenStream2;
use quote::quote;
use syn::{Data, DeriveInput, Fields, Generics, Ident, LitStr, Type, parse_macro_input};

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

/// Parsed `#[fig(..)]` attributes on a single field.
#[derive(Default)]
struct FieldAttrs {
    rename: Option<String>,
    skip: bool,
    flatten: bool,
    default: bool,
}

fn parse_field_attrs(attrs: &[syn::Attribute]) -> syn::Result<FieldAttrs> {
    let mut parsed = FieldAttrs::default();
    for attr in attrs {
        if !attr.path().is_ident("fig") {
            continue;
        }
        attr.parse_nested_meta(|meta| {
            if meta.path.is_ident("rename") {
                let lit: LitStr = meta.value()?.parse()?;
                parsed.rename = Some(lit.value());
            } else if meta.path.is_ident("skip") {
                parsed.skip = true;
            } else if meta.path.is_ident("flatten") {
                parsed.flatten = true;
            } else if meta.path.is_ident("default") {
                parsed.default = true;
            } else {
                return Err(meta.error(
                    "unknown `fig` attribute (expected one of: rename, skip, flatten, default)",
                ));
            }
            Ok(())
        })?;
    }
    Ok(parsed)
}

/// A field after attribute resolution.
struct FieldInfo<'a> {
    ident: &'a Ident,
    ty: &'a Type,
    /// The serialized key (rename or the field name). Unused for flattened fields.
    key: String,
    skip: bool,
    flatten: bool,
    /// Whether a missing key falls back to `Default` instead of erroring.
    use_default: bool,
}

fn collect_named_fields(fields: &syn::FieldsNamed) -> syn::Result<Vec<FieldInfo<'_>>> {
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
        let key = attrs.rename.unwrap_or_else(|| ident.to_string());
        let use_default = attrs.default || is_option(&field.ty);
        infos.push(FieldInfo {
            ident,
            ty: &field.ty,
            key,
            skip: attrs.skip,
            flatten: attrs.flatten,
            use_default,
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

// --- ToValue ------------------------------------------------------------------

fn expand_to_value(input: &DeriveInput) -> syn::Result<TokenStream2> {
    let name = &input.ident;
    let (impl_g, ty_g, _) = input.generics.split_for_impl();
    let where_clause = bounded_where(&input.generics, quote!(fig::ToValue));

    let data = match &input.data {
        Data::Struct(s) => s,
        Data::Enum(_) => {
            return Err(syn::Error::new_spanned(
                input,
                "fig's ToValue derive does not support enums yet",
            ));
        }
        Data::Union(_) => {
            return Err(syn::Error::new_spanned(
                input,
                "fig's ToValue derive does not support unions",
            ));
        }
    };

    let body = match &data.fields {
        Fields::Named(named) => {
            let infos = collect_named_fields(named)?;
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
                    quote! {
                        __entries.push((
                            fig::Value::Str(::std::string::String::from(#key)),
                            fig::ToValue::to_value(&self.#ident),
                        ));
                    }
                }
            });
            quote! {
                let mut __entries: ::std::vec::Vec<(fig::Value, fig::Value)> = ::std::vec::Vec::new();
                #(#stmts)*
                fig::Value::Map(__entries)
            }
        }
        Fields::Unnamed(unnamed) if unnamed.unnamed.len() == 1 => {
            quote! { fig::ToValue::to_value(&self.0) }
        }
        Fields::Unnamed(_) => {
            return Err(syn::Error::new_spanned(
                input,
                "fig's ToValue derive supports newtype structs (one field) but not multi-field tuple structs yet",
            ));
        }
        Fields::Unit => quote! { fig::Value::Null },
    };

    Ok(quote! {
        impl #impl_g fig::ToValue for #name #ty_g #where_clause {
            fn to_value(&self) -> fig::Value {
                #body
            }
        }
    })
}

// --- FromValue ----------------------------------------------------------------

fn expand_from_value(input: &DeriveInput) -> syn::Result<TokenStream2> {
    let name = &input.ident;
    let (impl_g, ty_g, _) = input.generics.split_for_impl();
    let where_clause = bounded_where(&input.generics, quote!(fig::FromValue));

    let data = match &input.data {
        Data::Struct(s) => s,
        Data::Enum(_) => {
            return Err(syn::Error::new_spanned(
                input,
                "fig's FromValue derive does not support enums yet",
            ));
        }
        Data::Union(_) => {
            return Err(syn::Error::new_spanned(
                input,
                "fig's FromValue derive does not support unions",
            ));
        }
    };

    let body = match &data.fields {
        Fields::Named(named) => {
            let infos = collect_named_fields(named)?;
            let type_name = name.to_string();

            // Keys consumed by explicit (non-flatten, non-skip) fields; a
            // flatten field absorbs everything else.
            let known_keys: Vec<&String> = infos
                .iter()
                .filter(|f| !f.skip && !f.flatten)
                .map(|f| &f.key)
                .collect();
            let has_explicit = !known_keys.is_empty();
            let has_flatten = infos.iter().any(|f| f.flatten && !f.skip);

            let lookup = if has_explicit {
                quote! {
                    let __get = |__name: &str| -> ::std::option::Option<&fig::Value> {
                        __entries.iter().rev().find_map(|(__k, __v)| match __k {
                            fig::Value::Str(__s) if __s == __name => ::std::option::Option::Some(__v),
                            _ => ::std::option::Option::None,
                        })
                    };
                }
            } else {
                quote! {}
            };

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
                let missing = if f.use_default {
                    quote! { ::core::default::Default::default() }
                } else {
                    let msg = format!("missing field `{key}` while building `{type_name}`");
                    quote! { return ::core::result::Result::Err(fig::Error::Message(::std::string::String::from(#msg))) }
                };
                quote! {
                    let #ident: #ty = match __get(#key) {
                        ::std::option::Option::Some(__v) => <#ty as fig::FromValue>::from_value(__v)?,
                        ::std::option::Option::None => #missing,
                    };
                }
            });

            let field_names = infos.iter().map(|f| f.ident);
            let expected_msg = format!("expected a mapping to build `{type_name}`");

            quote! {
                let __entries = match value {
                    fig::Value::Map(__e) => __e,
                    _ => return ::core::result::Result::Err(
                        fig::Error::Message(::std::string::String::from(#expected_msg)),
                    ),
                };
                #lookup
                #rest
                #(#field_lets)*
                ::core::result::Result::Ok(Self { #(#field_names),* })
            }
        }
        Fields::Unnamed(unnamed) if unnamed.unnamed.len() == 1 => {
            let ty = &unnamed.unnamed[0].ty;
            quote! {
                ::core::result::Result::Ok(Self(<#ty as fig::FromValue>::from_value(value)?))
            }
        }
        Fields::Unnamed(_) => {
            return Err(syn::Error::new_spanned(
                input,
                "fig's FromValue derive supports newtype structs (one field) but not multi-field tuple structs yet",
            ));
        }
        Fields::Unit => quote! { ::core::result::Result::Ok(Self) },
    };

    Ok(quote! {
        impl #impl_g fig::FromValue for #name #ty_g #where_clause {
            fn from_value(value: &fig::Value) -> ::core::result::Result<Self, fig::Error> {
                #body
            }
        }
    })
}
