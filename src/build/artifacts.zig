//! The buildable outputs: the `fig` library module, the CLI and LSP
//! executables, the C ABI library (static + shared), the wasm/wasi modules, and
//! the `run` step. Everything a consumer actually installs or links.

const std = @import("std");
const Context = @import("Context.zig");

/// The handles later stages need to hang more graph off of:
///   * `fig_mod`  — the `fig` library module (the gen-* dev tools import it).
///   * `exe`      — the CLI (its tests, and the sync-figl/version-set tools that
///                  shell out to it, reference it).
///   * `c_lib`    — the static C ABI lib the abi probes link against.
pub const Result = struct {
    fig_mod: *std.Build.Module,
    exe: *std.Build.Step.Compile,
    c_lib: *std.Build.Step.Compile,
};

pub fn add(ctx: Context) Result {
    const b = ctx.b;
    const target = ctx.target;
    const optimize = ctx.optimize;
    const strip = ctx.strip;
    const options_mod = ctx.options_mod;
    const resolved_target = target.result;

    const mod = b.addModule("fig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    mod.addImport("build_options", options_mod);
    // `root.zig`'s `test {}` block pulls in `c_api.zig`, which uses
    // `std.heap.c_allocator` on non-wasm targets — that allocator is only
    // available when linking libc. macOS links libc implicitly, so the test
    // suite builds there regardless, but Linux requires it to be explicit or the
    // module-test compile fails. WebAssembly uses `wasm_allocator` and must not
    // link libc, so gate on the architecture.
    mod.link_libc = !resolved_target.cpu.arch.isWasm();

    const exe = b.addExecutable(.{
        .name = "fig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .imports = &.{
                .{ .name = "fig", .module = mod },
            },
        }),
    });
    exe.root_module.addImport("build_options", options_mod);

    b.installArtifact(exe);

    // fig-lsp: a Language Server (LSP over stdio) that wraps the fig parser to
    // publish its teaching diagnostics to editors. Thin shell over `mod`.
    const lsp_exe = b.addExecutable(.{
        .name = "fig-lsp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lsp/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .imports = &.{
                .{ .name = "fig", .module = mod },
            },
        }),
    });
    lsp_exe.root_module.addImport("build_options", options_mod);
    b.installArtifact(lsp_exe);

    const lsp_run = b.addRunArtifact(lsp_exe);
    const lsp_run_step = b.step("run-lsp", "Run the fig language server (LSP over stdio)");
    lsp_run_step.dependOn(&lsp_run.step);

    const c_lib = addCApiLibrary(b, .static, target, optimize, strip, options_mod);
    const install_c_lib = b.addInstallArtifact(c_lib, .{});
    b.getInstallStep().dependOn(&install_c_lib.step);

    const install_c_lib_step = b.step("install-c-lib", "Install the C ABI static library");
    install_c_lib_step.dependOn(&install_c_lib.step);

    // Shared-library variant of the same C ABI: `libfig.so` (ELF, incl.
    // `*-linux-android`), `libfig.dylib` (Mach-O), or `fig.dll` (PE), chosen by
    // the target. This is the enabler for consumers that can only load a shared
    // object — Android/iOS through JNI/`System.loadLibrary`, and any
    // `dlopen`/`ctypes`/FFI binding. Kept OFF the default install (like the
    // `wasm`/`wasi` steps) so desktop/Homebrew builds stay lean; cross-compile
    // it explicitly, e.g.
    //   zig build shared -Dtarget=aarch64-linux-android -Doptimize=ReleaseSmall
    // (repeat per Android ABI: aarch64/x86_64/arm/x86). No NDK sysroot is
    // needed: the Android build links no libc at all (see `addCApiLibrary`'s
    // `link_libc` gate and `activeAllocator` in c_api.zig), producing a
    // self-contained `static-pie` `.so`.
    const c_shared = addCApiLibrary(b, .dynamic, target, optimize, strip, options_mod);
    const install_c_shared = b.addInstallArtifact(c_shared, .{});
    const shared_step = b.step("shared", "Build the C ABI as a shared library (.so/.dylib/.dll) — for Android/iOS/dlopen consumers");
    shared_step.dependOn(&install_c_shared.step);

    // WebAssembly build for the TypeScript bindings: compile the same C ABI to a
    // freestanding `reactor` module (no `_start`; `rdynamic` keeps every
    // exported `fig_*` symbol). `c_api.zig` already selects `wasm_allocator` and
    // drops logging on wasm, so no libc is needed. `zig build wasm` writes
    // `fig.wasm` into the install prefix's `bin/`.
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const wasm = b.addExecutable(.{
        .name = "fig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .strip = true,
        }),
    });
    wasm.root_module.addImport("build_options", options_mod);
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    const install_wasm = b.addInstallArtifact(wasm, .{});
    const wasm_step = b.step("wasm", "Build the WebAssembly module for the TypeScript bindings");
    wasm_step.dependOn(&install_wasm.step);

    // WASI build of the *CLI* (`main.zig`), distinct from the freestanding
    // `fig.wasm` above. This is a real `_start` command module: run it with a
    // WASI runtime, e.g. `wasmtime run --dir=.::. zig-out/bin/fig-wasi.wasm get foo.yaml`.
    // File access is capability-gated, so map a dir onto the guest cwd (`--dir`).
    const wasi_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });
    const wasi_mod = b.addModule("fig-wasi", .{
        .root_source_file = b.path("src/root.zig"),
        .target = wasi_target,
    });
    wasi_mod.addImport("build_options", options_mod);
    const wasi_cli = b.addExecutable(.{
        .name = "fig-wasi",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = wasi_target,
            .optimize = .ReleaseSmall,
            .strip = true,
            .imports = &.{
                .{ .name = "fig", .module = wasi_mod },
            },
        }),
    });
    wasi_cli.root_module.addImport("build_options", options_mod);
    const install_wasi = b.addInstallArtifact(wasi_cli, .{});
    const wasi_step = b.step("wasi", "Build the fig CLI as a WASI module (fig-wasi.wasm)");
    wasi_step.dependOn(&install_wasi.step);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    return .{ .fig_mod = mod, .exe = exe, .c_lib = c_lib };
}

/// Build one C ABI library artifact (`src/c_api.zig`) at the given `linkage`.
///
/// Factored out because the C ABI is now emitted twice from identical module
/// config: once `.static` (`libfig.a`, the default install + what the abi
/// probes link against) and once `.dynamic` (`libfig.so`/`.dylib`/`.dll`, the
/// `shared` step). A shared object is the integration surface every non-wasm
/// consumer that isn't a Zig/Rust build actually wants — Android/iOS via
/// JNI/`System.loadLibrary`, and any `dlopen`/`ctypes`/FFI binding — none of
/// which can link a `.a`. Keeping both behind one function is what stops the
/// two from drifting as `c_api.zig`'s build config changes.
fn addCApiLibrary(
    b: *std.Build,
    linkage: std.builtin.LinkMode,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    strip: bool,
    options_mod: *std.Build.Module,
) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .linkage = linkage,
        .name = "fig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            // `c_api.zig` reaches for `std.heap.c_allocator` on every target
            // that links libc, so libc must be linked there — EXCEPT two cases
            // that have no libc to link and select a different allocator (see
            // `activeAllocator` in c_api.zig):
            //   * wasm — uses `wasm_allocator`.
            //   * Android — Zig bundles glibc/musl but NOT Bionic, so a
            //     self-contained `.so` can't link one; it uses the libc-free
            //     `smp_allocator`. Dropping libc here is what lets
            //     `-Dtarget=*-linux-android` cross-compile with no NDK sysroot.
            .link_libc = !target.result.cpu.arch.isWasm() and !target.result.abi.isAndroid(),
        }),
    });
    lib.root_module.addImport("build_options", options_mod);
    return lib;
}
