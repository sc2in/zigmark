{
  description = "ZigMark - Simple markdown processing for zig";

  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1.964459.tar.gz";
    zig2nix.url = "https://flakehub.com/f/Cloudef/zig2nix/0.1.885.tar.gz";
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
          pname = "zigmark";
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
            runtimeInputs = with pkgs; [hyperfine pandoc discount lowdown cmark cmark-gfm python3 zig];
            text = ''
              set -euo pipefail
              REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
              cd "$REPO"

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

              echo "▸ Building zigmark (ReleaseSafe, ReleaseSmall, ReleaseFast)…"
              zig build -Doptimize=ReleaseSafe  && cp zig-out/bin/zigmark /tmp/zigmark-safe
              zig build -Doptimize=ReleaseSmall && cp zig-out/bin/zigmark /tmp/zigmark-small
              zig build -Doptimize=ReleaseFast  && cp zig-out/bin/zigmark /tmp/zigmark-fast

              RESULT_MD=$(mktemp /tmp/bench-result-XXXXXX.md)
              PANDOC_MD=$(mktemp /tmp/bench-pandoc-XXXXXX.md)
              # cmark and cmark-gfm write to stdout; wrap them so -N (no-shell) mode can discard output.
              CMARK_WRAP=$(mktemp /tmp/cmark-wrap-XXXXXX)
              printf '#!/bin/sh\nexec cmark "$@" > /dev/null\n' > "$CMARK_WRAP"
              chmod +x "$CMARK_WRAP"
              CMARK_GFM_WRAP=$(mktemp /tmp/cmark-gfm-wrap-XXXXXX)
              printf '#!/bin/sh\nexec cmark-gfm "$@" > /dev/null\n' > "$CMARK_GFM_WRAP"
              chmod +x "$CMARK_GFM_WRAP"
              trap 'rm -f "$RESULT_MD" "$PANDOC_MD" "$CMARK_WRAP" "$CMARK_GFM_WRAP" /tmp/zigmark-safe /tmp/zigmark-small /tmp/zigmark-fast' EXIT

              echo "▸ Running hyperfine (fast tools — 500 runs)…"
              hyperfine \
                -N \
                --warmup 50 \
                --runs 500 \
                --export-markdown "$RESULT_MD" \
                --command-name "zigmark (ReleaseSafe)"  "/tmp/zigmark-safe  -o /dev/null $BENCH_FILE" \
                --command-name "zigmark (ReleaseSmall)" "/tmp/zigmark-small -o /dev/null $BENCH_FILE" \
                --command-name "zigmark (ReleaseFast)"  "/tmp/zigmark-fast  -o /dev/null $BENCH_FILE" \
                --command-name "cmark"                   "$CMARK_WRAP $BENCH_FILE" \
                --command-name "cmark-gfm"              "$CMARK_GFM_WRAP $BENCH_FILE" \
                --command-name "discount"               "markdown -o /dev/null $BENCH_FILE" \
                --command-name "lowdown"                "lowdown  -o /dev/null $BENCH_FILE"

              echo "▸ Running hyperfine (pandoc — 20 runs)…"
              hyperfine \
                -N \
                --warmup 3 \
                --runs 20 \
                --export-markdown "$PANDOC_MD" \
                --command-name "pandoc" "pandoc -o /dev/null $BENCH_FILE"

              echo ""
              echo "▸ Updating README.md…"
              python3 - "$REPO/README.md" "$RESULT_MD" "$PANDOC_MD" "$BENCH_FILE" <<'PYEOF'
              import re, sys, pathlib, datetime

              readme_path = pathlib.Path(sys.argv[1])
              fast_md     = pathlib.Path(sys.argv[2]).read_text()
              pandoc_md   = pathlib.Path(sys.argv[3]).read_text()
              bench_file  = sys.argv[4]

              def parse_mean_ms(row):
                  # row cells: | cmd | mean ± sd | min | max | rel |
                  cells = [c.strip() for c in row.strip().strip("|").split("|")]
                  try:
                      return float(cells[1].split()[0])
                  except (IndexError, ValueError):
                      return float("inf")

              def is_data_row(line):
                  return line.startswith("|") and not line.startswith("| Command") and not line.startswith("|:")

              # Collect all data rows from both tables.
              fast_lines   = fast_md.rstrip().splitlines()
              pandoc_lines = pandoc_md.rstrip().splitlines()
              header = [l for l in fast_lines if l.startswith("| Command")][0]
              sep    = [l for l in fast_lines if l.startswith("|:")][0]
              data_rows = [l for l in fast_lines + pandoc_lines if is_data_row(l)]

              # Sort by mean time ascending.
              data_rows.sort(key=parse_mean_ms)

              # Bold zigmark rows (the command cell is the first column).
              def bold_if_zigmark(row):
                  if "zigmark" not in row:
                      return row
                  # Replace the backtick-quoted command name with a bolded version.
                  return re.sub(r"(`[^`]+`)", r"**\1**", row, count=1)

              data_rows = [bold_if_zigmark(r) for r in data_rows]
              bench_md = "\n".join([header, sep] + data_rows) + "\n"

              bench_size = pathlib.Path(bench_file).stat().st_size
              readme = readme_path.read_text()
              today  = datetime.date.today().isoformat()
              new_section = (
                  f"<!-- bench-start -->\n"
                  f"_Last updated: {today} · input: `{pathlib.Path(bench_file).name}`"
                  f" ({bench_size // 1024} KB) · run `nix run .#bench` to reproduce_\n\n"
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
