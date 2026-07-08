//! plist conformance scoreboard.
//!
//! SCAFFOLD: the corpus already exists (`testdata/plist/{valid,invalid}/`,
//! vendored from real system `Info.plist` files, hand-authored DTD-coverage
//! fixtures, and `plutil`-verified edge cases — see `testdata/plist/valid/*.json`
//! for the paired `plutil -convert json` oracles where one exists; `<date>`/
//! `<data>`-bearing fixtures have none, since `plutil` itself refuses to
//! convert those to JSON). The harness (structural compare against the JSON
//! oracles, rejection of `invalid/*.plist`, a ratcheting baseline like TOML's)
//! is a later phase. Gated behind `-Dplist-conformance=true`; skipped until
//! then.

const std = @import("std");

test "plist conformance: scaffold (harness pending)" {
    return error.SkipZigTest;
}
