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

        # CLI performance benchmark vs cmark:  nix run .#bench
        #
        # Builds zigmark (ReleaseFast), then runs hyperfine comparing zigmark
        # and cmark on the CommonMark spec file.  Results are written back into
        # the README.md <!-- bench-start / bench-end --> section.
        bench = let
          bench-app = pkgs.writeShellApplication {
            name = "zigmark-bench";
            runtimeInputs = with pkgs; [hyperfine cmark python3 zig];
            text = ''
              set -euo pipefail
              REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
              cd "$REPO"

              echo "▸ Building zigmark (ReleaseFast)…"
              zig build -Doptimize=ReleaseFast
              ZIGMARK="$REPO/zig-out/bin/zigmark"

              # Locate cmark reference binary
              CMARK_BIN="${pkgs.cmark}/bin/cmark"

              # Use the CommonMark spec as a large representative input.
              # Fall back to README.md if the dependency cache is unavailable.
              SPEC_TXT="$(find "$REPO/.zig-cache" -name "spec.txt" -path "*/commonmark_spec*" 2>/dev/null | head -1 || true)"
              if [ -z "$SPEC_TXT" ]; then
                echo "  spec.txt not cached yet — using README.md as benchmark input"
                BENCH_FILE="$REPO/README.md"
              else
                BENCH_FILE="$SPEC_TXT"
              fi
              echo "  Benchmark file: $BENCH_FILE ($(wc -c < "$BENCH_FILE") bytes)"

              RESULT_MD=$(mktemp /tmp/bench-result-XXXXXX.md)
              trap 'rm -f "$RESULT_MD"' EXIT

              echo "▸ Running hyperfine…"
              hyperfine \
                --warmup 50 \
                --runs 500 \
                --export-markdown "$RESULT_MD" \
                --command-name "zigmark" \
                "$ZIGMARK $BENCH_FILE > /dev/null" \
                --command-name "cmark" \
                "$CMARK_BIN $BENCH_FILE > /dev/null"

              echo ""
              echo "▸ Updating README.md…"
              python3 - "$REPO/README.md" "$RESULT_MD" <<'PYEOF'
              import re, sys, pathlib, datetime

              readme_path = pathlib.Path(sys.argv[1])
              bench_path  = pathlib.Path(sys.argv[2])

              bench_md = bench_path.read_text()
              readme   = readme_path.read_text()

              today = datetime.date.today().isoformat()
              new_section = (
                  f"<!-- bench-start -->\n"
                  f"_Last updated: {today}_\n\n"
                  f"{bench_md}\n"
                  f"<!-- bench-end -->"
              )

              updated = re.sub(
                  r"<!-- bench-start -->.*?<!-- bench-end -->",
                  new_section,
                  readme,
                  flags=re.DOTALL,
              )

              if updated == readme:
                  print("  WARNING: bench markers not found in README.md — appending.")
                  updated = readme.rstrip() + "\n\n" + new_section + "\n"

              readme_path.write_text(updated)
              print(f"  README.md updated.")
              PYEOF

              echo "✓ Done. Benchmark results written to README.md."
            '';
          };
        in {
          type = "app";
          program = "${bench-app}/bin/zigmark-bench";
        };
      }
    );
  };
}
