{
  description = "fig — a format-preserving config-file parser/editor CLI and library";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # Pins the exact Zig toolchain (0.16.0) fig is built with, matching CI.
    zig-overlay.url = "github:mitchellh/zig-overlay";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        zig = zig-overlay.packages.${system}."0.16.0";

        # This flake ships the `fig` CLI binary, which carries its OWN SemVer
        # track (`cli_version` in build.zig), independent of the core library
        # version in build.zig.zon. Parse that so the flake reports the same
        # version as `fig version` rather than the core number.
        cliVersion =
          let m = builtins.match ''.*cli_version = std\.SemanticVersion\.parse\("([^"]+)"\).*''
                    (builtins.readFile ./build.zig);
          in if m == null
             then throw "fig flake: could not find `cli_version` in build.zig"
             else builtins.head m;
      in {
        packages = rec {
          default = fig;

          fig = pkgs.stdenv.mkDerivation {
            pname = "fig";
            version = cliVersion;
            src = ./.;

            nativeBuildInputs = [ zig ];

            # fig has no build.zig.zon dependencies, so the build needs no
            # network access — but Zig still wants a writable cache dir, which
            # the read-only Nix store won't provide.
            dontConfigure = true;
            dontInstall = true; # `zig build --prefix $out` installs directly.

            buildPhase = ''
              runHook preBuild
              export HOME="$TMPDIR"
              export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
              export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
              zig build --prefix "$out" -Doptimize=ReleaseFast -Dstrip=true
              runHook postBuild
            '';

            meta = {
              description = "Format-preserving config-file parser/editor (YAML, JSON, TOML, ZON, INI, ...)";
              homepage = "https://github.com/diaryx-org/fig";
              license = with pkgs.lib.licenses; [ mit asl20 ];
              mainProgram = "fig";
              platforms = pkgs.lib.platforms.unix ++ pkgs.lib.platforms.windows;
            };
          };
        };

        apps.default = {
          type = "app";
          program = "${self.packages.${system}.fig}/bin/fig";
        };

        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [ zig ];
        };
      });
}
