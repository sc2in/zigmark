{
  description = "ZigMark - Simple markdown processing for zig";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    zig2nix.url = "github:Cloudef/zig2nix";
  };

  outputs = {
    self,
    nixpkgs,
    zig2nix,
    ...
  }: let
    # Systems to generate outputs for
    supportedSystems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];
    forAllSystems = f: nixpkgs.lib.genAttrs supportedSystems f;
    # Version is system-independent; shared by packages and checks.
    version = self.shortRev or self.dirtyShortRev or "dev";
  in {
    packages = forAllSystems (
      system: let
        # Use the pre-built Zig from nixpkgs (on the public binary cache)
        # instead of letting zig2nix build its own.
        env = zig2nix.outputs.zig-env.${system} {zig = nixpkgs.legacyPackages.${system}.zig;};
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;
        # Read name and version directly from build.zig.zon
        zon = env.fromZON ./build.zig.zon;

        # Only include files that affect the build output so that changes to
        # README, flake.nix, examples/, docs/ etc. don't bust the Nix cache.
        buildSrc = lib.fileset.toSource {
          root = ./.;
          fileset = lib.fileset.unions [
            ./build.zig
            ./build.zig.zon
            ./build.zig.zon2json-lock
            ./src
            ./include
          ];
        };
      in rec {
        default = env.package {
          pname = zon.name;
          inherit version;
          src = buildSrc;

          zigBuildFlags = [
            "-Dversion=${version}"
          ];

          # If your project has zig dependencies listed in build.zig.zon,
          # generate the lock file first:
          # nix run github:Cloudef/zig2nix -- zon2lock build.zig.zon
          # Then uncomment the line below:
          zigBuildZonLock = ./build.zig.zon2json-lock;
        };
      }
    );

    # `nix flake check` / omnix ci — runs `zig build test` (unit + cmark + gfm spec)
    checks = forAllSystems (system: {
      test = self.packages.${system}.default.overrideAttrs (_: {
        pname = "zigmark-test";
        buildPhase = "zig build test -Dversion=${version}";
        installPhase = "touch $out";
      });
    });

    devShells = forAllSystems (
      system: let
        pkgs = nixpkgs.legacyPackages.${system};
        env = zig2nix.outputs.zig-env.${system} {zig = pkgs.zig;};
        benchmark = pkgs.writeShellApplication {
          name = "benchmark";
          runtimeInputs = with pkgs; [
            hyperfine
          ];
          text = ''
            hyperfine -N --warmup 100 -m 1000 --export-markdown benchmark.md -L mode "Safe,Small,Fast" --setup "zig build -Doptimize=Release{mode}"  "./zig-out/bin/zigmark ./Readme.md > /dev/null"
          '';
        };
      in {
        default = env.mkShell {
          nativeBuildInputs = [
            pkgs.zls
            pkgs.bash
            (pkgs.writeShellScriptBin "update-zon" ''
              set -euo pipefail
              if ! command -v zig &>/dev/null; then
                echo "zig is not installed or not in PATH" >&2
                exit 1
              fi
              echo "Updating build.zig.zon dependencies..."
              zig fetch --save .
              echo "build.zig.zon updated."
            '')
            benchmark
          ];

          shellHook = ''
            export ZIG_GLOBAL_CACHE_DIR=.zig-cache
            echo "To update Zig dependencies, run: update-zon"
            # Auto-generate/update zon2json-lock when entering the dev shell.
            # This requires network access, which the dev shell has but nix build does not.
            if [ -f build.zig.zon ]; then
              if [ ! -f build.zig.zon2json-lock ] || [ build.zig.zon -nt build.zig.zon2json-lock ]; then
                echo "zig2nix: regenerating build.zig.zon2json-lock..."
                zig2nix zon2lock
              fi
            fi
          '';
        };
      }
    );

    # Convenience: `nix run .` executes the built binary
    apps = forAllSystems (
      system: let
        pkgs = nixpkgs.legacyPackages.${system};
        env = zig2nix.outputs.zig-env.${system} {zig = pkgs.zig;};
      in {
        default = env.app [] "zig build run -- \"$@\"";

        # Serve the WASM live-preview demo:  nix run .#wasm-demo
        wasm-demo = {
          type = "app";
          program = "${pkgs.writeShellScript "zigmark-wasm-demo" ''
            set -euo pipefail
            cd "$(${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null || echo .)"
            echo "▸ Building WASM module…"
            zig build wasm
            PORT="''${1:-8080}"
            echo "✓ Serving zig-out/wasm/ on http://localhost:$PORT"
            ${pkgs.python3}/bin/python3 -m http.server "$PORT" -d zig-out/wasm
          ''}";
        };
      }
    );
  };
}
