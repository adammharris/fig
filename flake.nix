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
      in {
        packages = rec {
          default = fig;

          fig = pkgs.stdenv.mkDerivation {
            pname = "fig";
            version = "2.5.0";
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
              homepage = "https://github.com/adammharris/fig";
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
