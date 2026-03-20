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
        # Helper: build zigmark at a given optimization level (null = default).
        mkZigmark = optimize:
          env.package {
            pname = "zigmark";
            inherit version;
            src = buildSrc;
            zigBuildFlags =
              ["-Dversion=${version}"]
              ++ lib.optional (optimize != null) "-Doptimize=${optimize}";
            # If your project has zig dependencies listed in build.zig.zon,
            # generate the lock file first:
            # nix run github:Cloudef/zig2nix -- zon2lock build.zig.zon
            # Then uncomment the line below:
            zigBuildZonLock = ./build.zig.zon2json-lock;
          };
        withDesc = drv: desc:
          drv.overrideAttrs (old: {
            meta = (old.meta or {}) // {description = desc;};
          });
      in {
        default = withDesc (mkZigmark null) "zigmark — CommonMark + GFM markdown parser and renderer";
        zigmark-safe = withDesc (mkZigmark "ReleaseSafe") "zigmark (ReleaseSafe)";
        zigmark-small = withDesc (mkZigmark "ReleaseSmall") "zigmark (ReleaseSmall)";
        zigmark-fast = withDesc (mkZigmark "ReleaseFast") "zigmark (ReleaseFast)";
      }
    );

    # `nix flake check` / omnix ci — runs `zig build test` (unit + cmark + gfm spec)
    checks = forAllSystems (system: {
      test = self.packages.${system}.default.overrideAttrs (old: {
        pname = "zigmark-test";
        buildPhase = "zig build test -Dversion=${version}";
        installPhase = "touch $out";
        meta = (old.meta or {}) // {description = "Run zig build test — unit tests + CommonMark spec + GFM spec";};
      });
    });

    devShells = forAllSystems (
      system: let
        pkgs = nixpkgs.legacyPackages.${system};
        env = zig2nix.outputs.zig-env.${system} {zig = pkgs.zig;};
        benchmark = pkgs.writeShellApplication {
          name = "benchmark";
          meta.description = "Quick hyperfine benchmark of zigmark across all release modes";
          runtimeInputs = with pkgs; [
            hyperfine
          ];
          text = ''
            hyperfine -N --warmup 100 -m 1000 --export-markdown benchmark.md -L mode "Safe,Small,Fast" --setup "zig build -Doptimize=Release{mode}"  "./zig-out/bin/zigmark ./Readme.md > /dev/null"
          '';
        };
        fuzz = pkgs.writeShellApplication {
          name = "fuzz";
          meta.description = "Run coverage-guided fuzz tests with the Zig web UI (optional port argument, default 8080)";
          text = ''
            PORT="''${1:-8080}"
            echo "▸ Starting fuzzer — web UI at http://127.0.0.1:$PORT"
            zig build  --listen fuzz--fuzz --webui="127.0.0.1:$PORT"
          '';
        };
      in {
        default = env.mkShell {
          nativeBuildInputs = [
            pkgs.zls
            pkgs.bash
            fuzz
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
            echo "To run the fuzzer, run: fuzz [port]  (default port: 8080)"
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
        default = {
          type = "app";
          program = "${self.packages.${system}.zigmark-safe}/bin/zigmark";
          meta.description = "Run zigmark (ReleaseSafe)";
        };

        # Serve the WASM live-preview demo:  nix run .#wasm-demo
        wasm-demo = let
          wasm-demo-app = pkgs.writeShellApplication {
            name = "zigmark-wasm-demo";
            meta.description = "Build the WASM module and serve the live-preview demo locally (optional port argument, default 8080)";
            runtimeInputs = [pkgs.git pkgs.python3];
            text = ''
              cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
              echo "▸ Building WASM module…"
              zig build wasm
              PORT="''${1:-8080}"
              echo "✓ Serving zig-out/wasm/ on http://localhost:$PORT"
              python3 -m http.server "$PORT" -d zig-out/wasm
            '';
          };
        in {
          type = "app";
          program = "${wasm-demo-app}/bin/zigmark-wasm-demo";
          meta.description = "Build the WASM module and serve the live-preview demo locally (optional port argument, default 8080)";
        };

        # CLI performance benchmark vs cmark:  nix run .#bench
        #
        # Uses pre-built flake packages (zigmark-safe/small/fast) so no Zig
        # compiler is needed at runtime.  Results are written back into the
        # README.md <!-- bench-start / bench-end --> section via zigmark's own
        # --section-start/--section-end AST mutation API.
        bench = let
          bench-app = pkgs.writeShellApplication {
            name = "zigmark-bench";
            meta.description = "Benchmark zigmark against cmark, cmark-gfm, pandoc, discount, and lowdown; updates README.md with results";
            runtimeInputs = with pkgs; [hyperfine pandoc discount lowdown cmark cmark-gfm time python3];
            text = ''
              set -euo pipefail
              REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
              cd "$REPO"

              # Binaries baked in at build time from the flake's packages —
              # no compiler required at benchmark runtime.
              ZIGMARK_SAFE="${self.packages.${system}.zigmark-safe}/bin/zigmark"
              ZIGMARK_SMALL="${self.packages.${system}.zigmark-small}/bin/zigmark"
              ZIGMARK_FAST="${self.packages.${system}.zigmark-fast}/bin/zigmark"

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
              PANDOC_MD=$(mktemp /tmp/bench-pandoc-XXXXXX.md)
              # cmark and cmark-gfm write to stdout; wrap them so -N (no-shell) mode can discard output.
              CMARK_WRAP=$(mktemp /tmp/cmark-wrap-XXXXXX)
              printf '#!/bin/sh\nexec cmark "$@" > /dev/null\n' > "$CMARK_WRAP"
              chmod +x "$CMARK_WRAP"
              CMARK_GFM_WRAP=$(mktemp /tmp/cmark-gfm-wrap-XXXXXX)
              printf '#!/bin/sh\nexec cmark-gfm "$@" > /dev/null\n' > "$CMARK_GFM_WRAP"
              chmod +x "$CMARK_GFM_WRAP"
              MEM_MD=$(mktemp /tmp/bench-mem-XXXXXX.md)
              TIME_TMP=$(mktemp /tmp/bench-time-XXXXXX)
              NEW_SECTION_MD=$(mktemp /tmp/bench-new-section-XXXXXX.md)
              trap 'rm -f "$RESULT_MD" "$PANDOC_MD" "$MEM_MD" "$TIME_TMP" "$NEW_SECTION_MD" "$CMARK_WRAP" "$CMARK_GFM_WRAP"' EXIT

              echo "▸ Running hyperfine (fast tools — 500 runs)…"
              hyperfine \
                -N \
                --warmup 50 \
                --runs 500 \
                --export-markdown "$RESULT_MD" \
                --command-name "zigmark (ReleaseSafe)"  "$ZIGMARK_SAFE  -o /dev/null $BENCH_FILE" \
                --command-name "zigmark (ReleaseSmall)" "$ZIGMARK_SMALL -o /dev/null $BENCH_FILE" \
                --command-name "zigmark (ReleaseFast)"  "$ZIGMARK_FAST  -o /dev/null $BENCH_FILE" \
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

              echo "▸ Measuring peak RSS (one run each)…"
              # GNU time -v reports "Maximum resident set size (kbytes)" on Linux.
              # Shell builtin `time` can't be overridden by PATH; use the store path directly.
              rss() { "${pkgs.time}/bin/time" -v "$@" >/dev/null 2>"$TIME_TMP" || true; grep "Maximum resident" "$TIME_TMP" | awk '{print $NF}'; }
              {
                printf "| Command | Peak RSS (KB) |\n|:---|---:|\n"
                printf "| \`zigmark (ReleaseSafe)\` | %s |\n"  "$(rss "$ZIGMARK_SAFE"  -o /dev/null "$BENCH_FILE")"
                printf "| \`zigmark (ReleaseSmall)\` | %s |\n" "$(rss "$ZIGMARK_SMALL" -o /dev/null "$BENCH_FILE")"
                printf "| \`zigmark (ReleaseFast)\` | %s |\n"  "$(rss "$ZIGMARK_FAST"  -o /dev/null "$BENCH_FILE")"
                printf "| \`cmark\` | %s |\n"                  "$(rss "$CMARK_WRAP"      "$BENCH_FILE")"
                printf "| \`cmark-gfm\` | %s |\n"              "$(rss "$CMARK_GFM_WRAP"  "$BENCH_FILE")"
                printf "| \`discount\` | %s |\n"               "$(rss markdown -o /dev/null "$BENCH_FILE")"
                printf "| \`lowdown\` | %s |\n"                "$(rss lowdown  -o /dev/null "$BENCH_FILE")"
                printf "| \`pandoc\` | %s |\n"                 "$(rss pandoc   -o /dev/null "$BENCH_FILE")"
              } > "$MEM_MD"

              echo ""
              echo "▸ Preparing bench section content…"
              # Python handles the data-processing only: sort rows, bold zigmark
              # entries, and write the new section body to $NEW_SECTION_MD.
              # README.md is updated below by zigmark via its AST mutation API.
              python3 - "$RESULT_MD" "$PANDOC_MD" "$BENCH_FILE" "$MEM_MD" "$NEW_SECTION_MD" <<'PYEOF'
              import re, sys, pathlib, datetime

              fast_md     = pathlib.Path(sys.argv[1]).read_text()
              pandoc_md   = pathlib.Path(sys.argv[2]).read_text()
              bench_file  = sys.argv[3]
              mem_md      = pathlib.Path(sys.argv[4]).read_text()
              out_path    = pathlib.Path(sys.argv[5])

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
                  return re.sub(r"(`[^`]+`)", r"**\1**", row, count=1)

              data_rows = [bold_if_zigmark(r) for r in data_rows]
              bench_md = "\n".join([header, sep] + data_rows) + "\n"

              # Build sorted+bolded memory table.
              def parse_rss(row):
                  cells = [c.strip() for c in row.strip().strip("|").split("|")]
                  try:
                      return int(cells[1])
                  except (IndexError, ValueError):
                      return 10**9

              mem_lines   = mem_md.rstrip().splitlines()
              mem_header  = [l for l in mem_lines if l.startswith("| Command")][0]
              mem_sep     = [l for l in mem_lines if l.startswith("|:")][0]
              mem_rows    = [l for l in mem_lines if is_data_row(l)]
              mem_rows.sort(key=parse_rss)
              mem_rows    = [bold_if_zigmark(r) for r in mem_rows]
              mem_table   = "\n".join([mem_header, mem_sep] + mem_rows) + "\n"

              bench_size = pathlib.Path(bench_file).stat().st_size
              today      = datetime.date.today().isoformat()

              # Write just the section body (without the bench-start/bench-end
              # markers themselves — zigmark preserves those as anchor blocks).
              section_body = (
                  f"_Last updated: {today} · input: `{pathlib.Path(bench_file).name}`"
                  f" ({bench_size // 1024} KB) · run `nix run .#bench` to reproduce_\n\n"
                  f"### Speed\n\n{bench_md}\n"
                  f"### Memory (peak RSS)\n\n{mem_table}\n"
              )
              out_path.write_text(section_body)
              PYEOF

              echo "▸ Updating README.md…"
              # zigmark parses README.md, removes the blocks between the
              # <!-- bench-start --> and <!-- bench-end --> markers, inserts the
              # new content parsed from $NEW_SECTION_MD, then normalizes back to
              # Markdown — exercising the Document.Mutate API end-to-end.
              "$ZIGMARK_FAST" -f normalize \
                --section-start "bench-start" \
                --section-end   "bench-end"   \
                "$REPO/README.md"             \
                -o "$REPO/README.md"          \
                < "$NEW_SECTION_MD"

              echo "✓ Done. Benchmark results written to README.md."
            '';
          };
        in {
          type = "app";
          program = "${bench-app}/bin/zigmark-bench";
          meta.description = "Benchmark zigmark against cmark, cmark-gfm, pandoc, discount, and lowdown; updates README.md with results";
        };
      }
    );
  };
}
