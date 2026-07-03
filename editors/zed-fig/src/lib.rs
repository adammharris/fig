//! Zed extension glue for fig.
//!
//! The grammar (highlighting) needs no code — it is declared in extension.toml.
//! This file exists solely to tell Zed how to launch the fig language server,
//! which is where diagnostics/formatting/hover come from. The server itself is
//! the `fig-lsp` binary built by `zig build` (see src/lsp/main.zig).

use zed_extension_api::{self as zed, LanguageServerId, Result};

/// Fallback used only during local development, when `fig-lsp` is not yet on the
/// PATH. Points at the binary `zig build` installs. Once you `install` or symlink
/// `fig-lsp` onto your PATH, `worktree.which` finds it and this is never used.
const DEV_FALLBACK: &str = "/Users/adamharris/Documents/fig/zig-out/bin/fig-lsp";

struct FigExtension;

impl zed::Extension for FigExtension {
    fn new() -> Self {
        FigExtension
    }

    fn language_server_command(
        &mut self,
        _language_server_id: &LanguageServerId,
        worktree: &zed::Worktree,
    ) -> Result<zed::Command> {
        let command = worktree
            .which("fig-lsp")
            .unwrap_or_else(|| DEV_FALLBACK.to_string());
        Ok(zed::Command {
            command,
            args: vec![],
            env: Default::default(),
        })
    }
}

zed::register_extension!(FigExtension);
