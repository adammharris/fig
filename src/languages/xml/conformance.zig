//! XML conformance scoreboard.
//!
//! Phase 1 SCAFFOLD: the harness (structural compare of testdata/xml/valid/*.xml
//! against paired *.json, rejection of testdata/xml/invalid/*.xml, with a
//! ratcheting baseline like the TOML harness) lands in Phase 5. Gated behind
//! `-Dxml-conformance=true`; skipped until then.

const std = @import("std");

test "xml conformance: scaffold (harness pending — Phase 5)" {
    return error.SkipZigTest;
}
