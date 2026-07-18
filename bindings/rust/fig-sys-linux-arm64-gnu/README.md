# fig-sys-linux-arm64-gnu

Prebuilt `libfig.a` (fig's default language set) for `aarch64-unknown-linux-gnu`, letting
`fig-sys` link fig's native library on this target **without a Zig toolchain**.

This is an implementation detail of [`fig-sys`](https://crates.io/crates/fig-sys)
and [`fig`](https://crates.io/crates/fig). You should not depend on it directly;
`fig-sys` pulls in the right payload crate automatically for your target. A
non-default language feature set builds from source instead.

## License

MIT OR Apache-2.0
