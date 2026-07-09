# ardos-packer2 — public library entry point.
#
# Thin aggregator over the pipeline stages. Each stage has its own directory
# under `lib/`:
#
#   lib/host/         Stage 0 — host nixpkgs (for devShells, helper builds)
#   lib/toolchain/    Stage 1 — cross-compilation toolchain (crossPkgs)
#   lib/builder/      Stage 2 — per-package builder (mkArdosDerivation)
#   lib/sysroot/      Stage 3 — package merge (Milestone 3, not yet implemented)
#   lib/rom/          Stage 4 — ROM / squashfs assembly (Milestone 3, not yet implemented)
#
# External consumers (e.g. flake.nix) only ever call `init` here. They should
# not import from the per-stage directories directly.
{nixpkgs}: let
  lib = nixpkgs.lib;
  platforms = import ./platforms.nix {inherit lib;};
in rec {
  inherit platforms;

  # Initialise a build context for a specific target platform.
  #
  # Args:
  #   targetPlatform: attrset as produced by ./platforms.nix
  #                   (e.g. { cpu = "x86_64"; kernel = "linux"; abi = "ardos"; ... })
  #   buildSystem:    string identifying the host nix system
  #                   (e.g. "x86_64-linux")
  init = args: let
    inherit (args) targetPlatform buildSystem;
    externalMappingsArg = args.externalMappings or [];
    host = import ./host {inherit nixpkgs;};
    toolchain = import ./toolchain {
      inherit nixpkgs targetPlatform buildSystem host;
      rustScript = import ./builder/rustScript.nix {
        buildPkgs = nixpkgs.legacyPackages.${buildSystem} or
          (throw "lib/default.nix: buildPkgs for ${buildSystem} not available; check that nixpkgs.legacyPackages.${buildSystem} is set");
      };
    };
    inherit (toolchain) crossPkgs buildPkgs;
    externalMappings =
      if builtins.isFunction externalMappingsArg
      then externalMappingsArg crossPkgs
      else externalMappingsArg;
    builder = import ./builder {
      inherit buildPkgs crossPkgs externalMappings;
    };
  in let
    instance = rec {
      inherit buildPkgs crossPkgs;
      inherit (builder) mkArdosDerivation mkRuntimeTree;

      stdenv = crossPkgs.stdenv;
      cc = toolchain.toolchain.cc;

      callPackage = path: overrides:
        let
          scope = crossPkgs // {
            inherit mkArdosDerivation mkRuntimeTree;
            ap2 = instance;
          };
        in
          lib.callPackageWith scope path overrides;

      rom = {
        includePackages,
        name ? "ardos-rom",
      }: let
        closure = buildPkgs.closureInfo {rootPaths = includePackages;};
      in
        buildPkgs.runCommand "${name}.squashfs" {
          nativeBuildInputs = [
            buildPkgs.coreutils
            buildPkgs.findutils
            buildPkgs.squashfsTools
          ];
        } ''
        root=$(mktemp -d)

        copy_mapping() {
          src_path="$1"
          dest_path="$2"

          if [ ! -e "$src_path" ] && [ ! -L "$src_path" ]; then
            echo "error: broken Ardos runtime mapping: $src_path -> ''${dest_path#$root}" >&2
            exit 1
          fi

          # Runtime mappings are represented by a symlink tree. Resolve exactly
          # one symlink level: a link to a directory copies that directory's
          # contents, a link to a file copies the file, and a link to another
          # symlink copies that second symlink verbatim.
          copy_source="$src_path"
          if [ -L "$src_path" ]; then
            link_target=$(readlink -- "$src_path")
            case "$link_target" in
              /*) resolved="$link_target" ;;
              *) resolved="$(dirname "$src_path")/$link_target" ;;
            esac

            if [ ! -e "$resolved" ] && [ ! -L "$resolved" ]; then
              echo "error: broken Ardos runtime mapping symlink: $src_path -> $link_target" >&2
              exit 1
            fi

            copy_source="$resolved"
          fi

          if [ -e "$dest_path" ] || [ -L "$dest_path" ]; then
            echo "error: duplicate Ardos runtime path: ''${dest_path#$root}" >&2
            exit 1
          fi

          mkdir -p "$(dirname "$dest_path")"
          if [ -d "$copy_source" ] && [ ! -L "$copy_source" ]; then
            mkdir -p "$dest_path"
            cp -a --no-preserve=ownership "$copy_source"/. "$dest_path"/
          else
            cp -a --no-preserve=ownership "$copy_source" "$dest_path"
          fi
        }

        while IFS= read -r store_path; do
          layout="$store_path/nix-support/ardos-layout"
          [ -f "$layout" ] || continue

          while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in ""|\#*) continue ;; esac

            src_rel="''${line%% -> *}"
            dest_abs="''${line#* -> }"
            case "$src_rel" in
              /*) src_path="$src_rel" ;;
              *) src_path="$store_path/$src_rel" ;;
            esac
            dest_path="$root/''${dest_abs#/}"

            copy_mapping "$src_path" "$dest_path"
          done < "$layout"
        done < ${closure}/store-paths

        mksquashfs "$root" "$out" -noappend -all-root -no-progress
      '';

    };
  in
    instance;
}
