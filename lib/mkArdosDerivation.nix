# mkArdosDerivation — Exposes the package builder abstraction for Ardos runtime packages.
# Separates target compilation/linking (stdenv) from package runtime layout definition.
#
# A package declares its runtime layout with `runtimeLayoutScript`: a bash snippet that
# is executed inside an empty staging directory. The script uses normal `ln -s` calls
# to materialise the final Ardos filesystem layout as symlinks pointing back at the
# package's own `$out`. After the script runs, the resulting symlink tree is walked
# and the discovered mappings are written to `$out/nix-support/ardos-layout`, which is
# the single source of truth consumed by the linker wrapper, downstream packages and
# the ROM generator.
#
# Backwards-compatible: if a package still passes the legacy `runtimeLayout` list, it
# is converted into an equivalent script (one `ln -s` per entry).
{
  stdenv,
  nixpkgs,
  rustScript,
}: let
  lib = nixpkgs.lib;
  glibc = stdenv.crossPkgs.glibc;

  # Convert a list of {source, target} entries into a tiny shell script that creates
  # the same symlink tree. Used to bridge packages still on the old declarative form.
  layoutListToScript = entries:
    lib.concatMapStrings (entry: ''
      mkdir -p "$stage$(dirname "${entry.target}")"
      ln -sfn "$out/${entry.source}" "$stage${entry.target}"
    '')
    entries;

  # Build a runtimeTree (materialized symlink structure of target paths)
  mkRuntimeTree = {
    pname,
    version,
    drv,
  }:
    stdenv.crossPkgs.runCommand "${pname}-runtime-tree-${version}" {
      nativeBuildInputs = [stdenv.crossPkgs.coreutils];
    } ''
      mkdir -p $out
      # Parse the layout of the package and create symlinks at the target paths
      if [ -f "${drv}/nix-support/ardos-layout" ]; then
        while read -r line || [[ -n "$line" ]]; do
          [[ "$line" =~ ^# ]] && continue
          [[ -z "$line" ]] && continue

          # Extract source relative path and absolute destination target path
          src_rel="''${line%% -> *}"
          dest_abs="''${line#* -> }"

          # Compute full source path in the nix store
          src_path="${drv}/''${src_rel}"

          # Strip the leading slash from the destination path to make it a relative path inside $out
          dest_rel="build-root/''${dest_abs#/}"
          dest_path="$out/$dest_rel"

          # Create parent directories of target destination in the output
          mkdir -p "$(dirname "$dest_path")"
          # Create the symlink pointing to the real nix store path
          ln -s "$src_path" "$dest_path"
        done < "${drv}/nix-support/ardos-layout"
      fi
    '';
in rec {
  inherit mkRuntimeTree;

  # The main package builder
  mkArdosDerivation = {
    pname,
    version,
    # New: developer-authored bash snippet. Receives $out (the package's nix-support
    # output) and $stage (an empty staging directory). Use `ln -s $out/... $stage/...`
    # to express the final Ardos filesystem layout. Arbitrary logic — loops, globs,
    # conditionals over generated file names — is welcome and encouraged.
    runtimeLayoutScript ? null,
    # Legacy: list of {source, target} entries. Translated to a script internally.
    runtimeLayout ? [],
    ...
  } @ args: let
    # Strip ardos-specific attrs before forwarding to mkDerivation.
    cleanArgs = removeAttrs args ["runtimeLayout" "runtimeLayoutScript"];

    # Resolve whichever form was provided into a single bash snippet.
    resolvedLayoutScript =
      if runtimeLayoutScript != null
      then runtimeLayoutScript
      else layoutListToScript runtimeLayout;

    # Build the derivation using our target stdenv
    drv = stdenv.crossPkgs.stdenv.mkDerivation (cleanArgs
      // {
        _ardos_hook_dir = rustScript "ardos-ld-translate" ./stdenv/hooks/ardos-ld-translate.rs;
        __ardosLdHook__ = ./stdenv/hooks/ld-wrapper-hook-impl;
        __ardosMapTargetGlibc__ = "${glibc}";
        __ardosMapTargetLibgcc__ = "${stdenv.toolchain.cc.cc}";
        NIX_DEBUG = "1";

        # Auto-derive ardos-layout from the developer-provided script.
        # Runs the script against an empty stage, then walks the resulting symlink
        # tree and writes one `<rel-source> -> <abs-target>` line per symlink into
        # $out/nix-support/ardos-layout. This file is the single source of truth
        # consumed by the linker wrapper, downstream packages, and the ROM generator.
        postInstall =
          (args.postInstall or "")
          + ''
            echo "[Ardos Layout] Resolving runtime layout script for ${pname}..."

            # Honour NIX_DEBUG: the script (and the walk below) is silent unless the
            # user opted in. This keeps rebuild logs short on cache hits.
            if [ "''${NIX_DEBUG:-0}" = "1" ]; then
              layout_debug=1
            else
              layout_debug=0
            fi

            mkdir -p $out/nix-support

            if [ -z "${toString resolvedLayoutScript}" ]; then
              echo "[Ardos Layout] No runtimeLayoutScript / runtimeLayout declared; writing empty layout." >&2
              : > $out/nix-support/ardos-layout
            else
              stage=$(mktemp -d -t ardos-layout-XXXXXX)
              trap 'rm -rf "$stage"' EXIT

              out=$out stage=$stage bash -c ${lib.escapeShellArg resolvedLayoutScript}

              # Walk the stage, recording every symlink (and the regular files the
              # script may have copied, for completeness). Each entry becomes a
              # "<source-in-$out> -> <abs-target>" line in the layout file.
              : > $out/nix-support/ardos-layout
              [ "$layout_debug" = "1" ] && echo "[Ardos Layout] Walking $stage..." >&2

              # Use a NUL-delimited find so paths with spaces/newlines survive.
              while IFS= read -r -d $'\0' entry; do
                # Skip entries under $stage itself (we want its children).
                rel="''${entry#$stage/}"
                [ "$rel" = "$entry" ] && continue

                target="/$rel"

                if [ -L "$entry" ]; then
                  # Resolve the symlink relative to its own directory.
                  pointed=$(readlink -f -- "$entry" 2>/dev/null || true)
                  if [ -n "$pointed" ] && [[ "$pointed" == "$out"/* ]]; then
                    src_rel="''${pointed#$out/}"
                  else
                    # Symlink escaped the package output — preserve it verbatim so
                    # downstream consumers can still see the intended target.
                    src_rel=$(readlink -- "$entry")
                  fi
                elif [ -f "$entry" ]; then
                  src_rel="''${entry#$out/}"
                  if [ "$src_rel" = "$entry" ]; then
                    # File outside $out: record by absolute path.
                    src_rel="$entry"
                  fi
                else
                  # Directory or other: skip — we only emit leaf mappings.
                  continue
                fi

                printf '%s -> %s\n' "$src_rel" "$target" >> $out/nix-support/ardos-layout
              done < <(find "$stage" -mindepth 1 -print0)

              if [ "$layout_debug" = "1" ]; then
                echo "[Ardos Layout] Resolved layout for ${pname}:" >&2
                sed 's/^/  /' $out/nix-support/ardos-layout >&2
              fi
            fi
          '';
      });
  in
    drv.overrideAttrs (old: {
      passthru =
        old.passthru or {
          ardos = {
            # Always expose the resolved script — even when the caller used the
            # legacy list form — so introspection sees a single canonical shape.
            runtimeLayoutScript = resolvedLayoutScript;
            runtimeTree = mkRuntimeTree {
              inherit pname version;
              drv = drv;
            };
          };
        };
    });
}
