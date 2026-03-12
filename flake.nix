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
  in {
    packages = forAllSystems (
      system: let
        env = zig2nix.outputs.zig-env.${system} {};
        # Read name and version directly from build.zig.zon
        zon = env.fromZON ./build.zig.zon;
      in rec {
        default = env.package {
          pname = zon.name;
          version = zon.version;
          src = ./.;

          # If your project has zig dependencies listed in build.zig.zon,
          # generate the lock file first:
          # nix run github:Cloudef/zig2nix -- zon2lock build.zig.zon
          # Then uncomment the line below:
          zigBuildZonLock = ./build.zig.zon2json-lock;
        };
      }
    );

    devShells = forAllSystems (
      system: let
        env = zig2nix.outputs.zig-env.${system} {};
        pkgs = nixpkgs.legacyPackages.${system};
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
            benchmark
          ];

          shellHook = ''
            export ZIG_GLOBAL_CACHE_DIR=.zig-cache
            # Auto-generate/update zon2json-lock when entering the dev shell.
            # This requires network access, which the dev shell has but nix build does not.
            if [ -f build.zig.zon ]; then
              if [ ! -f build.zig.zon2json-lock ] || [ build.zig.zon -nt build.zig.zon2json-lock ]; then
                echo "zig2nix: regenerating build.zig.zon2json-lock..."
                zig2nix zon2lock build.zig.zon
              fi
            fi
          '';
        };
      }
    );

    # Convenience: `nix run .` executes the built binary
    apps = forAllSystems (
      system: let
        env = zig2nix.outputs.zig-env.${system} {};
      in {
        default = env.app [] "zig build run -- \"$@\"";
      }
    );
  };
}
