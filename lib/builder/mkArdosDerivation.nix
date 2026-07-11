# mkArdosDerivation — Stage 2 (per-package builder).
#
# Exposes the package builder abstraction for Ardos runtime packages.
# Separates target compilation/linking (stdenv) from package runtime layout
# definition.
#
# A package declares its runtime layout with `runtimeLayoutScript`: a bash
# snippet that is executed inside an empty staging directory. The script uses
# normal `ln -s` calls to materialise the final Ardos filesystem layout as
# symlinks pointing back at the package's own `$out`. After the script runs,
# the resulting symlink tree is walked and the discovered mappings are written
# to `$out/nix-support/ardos-layout`, which is the single source of truth
# consumed by the linker wrapper, downstream packages and the ROM generator.
#
# Backwards-compatible: if a package still passes the legacy `runtimeLayout`
# list, it is converted into an equivalent script (one `ln -s` per entry).
#
# File-local relative paths (./hooks/*) are relative to this file's location
# in lib/builder/.
{
  nixpkgs,
  crossPkgs,
  rustScript,
  externalMappings ? [],
}: let
  lib = nixpkgs.lib;
  stdenv = crossPkgs.stdenv;

  layoutListToScript = entries:
    lib.concatMapStrings (entry: ''
      mkdir -p "\$stage\$(dirname \"${entry.target}\")"
      ln -sfn "\$out/${entry.source}" "\$stage${entry.target}"
    '')
    entries;

  mappingScriptToLayout = mapping: ''
    mappings_out="$out"
    echo "# ardos-external-mapping ${mapping.drv}" >> "$mappings_out"
    stage=$(mktemp -d -t ardos-external-layout-XXXXXX)
    (
      out=${mapping.drv} stage=$stage bash -c ${lib.escapeShellArg mapping.runtimeLayoutScript}

      while IFS= read -r -d $'\0' entry; do
        rel="''${entry#$stage/}"
        [ "$rel" = "$entry" ] && continue

        target="/$rel"
        if [ -L "$entry" ]; then
          pointed=$(readlink -f -- "$entry" 2>/dev/null || true)
          if [ -n "$pointed" ] && [[ "$pointed" == "${mapping.drv}"/* ]]; then
            src_rel="''${pointed#${mapping.drv}/}"
          else
            src_rel=$(readlink -- "$entry")
          fi
        elif [ -f "$entry" ]; then
          echo "error: runtimeLayoutScript for ${mapping.drv} created a concrete file in ardos-layout: $entry" >&2
          exit 1
        else
          continue
        fi

        printf '%s -> %s\n' "$src_rel" "$target" >> "$mappings_out"
      done < <(find "$stage" -mindepth 1 -print0)
    )
    rm -rf "$stage"
  '';

  externalMappingsFile =
    if externalMappings == []
    then null
    else
      nixpkgs.runCommand "ardos-external-runtime-mappings" {
        nativeBuildInputs = [nixpkgs.coreutils nixpkgs.findutils nixpkgs.bash];
      } ''
        : > "$out"
        ${lib.concatMapStringsSep "\n" mappingScriptToLayout externalMappings}
      '';

  # Build a runtimeTree (materialized symlink structure of target paths)
  mkRuntimeTree = {
    pname,
    version,
    drv,
  }:
    crossPkgs.runCommand "${pname}-runtime-tree-${version}" {
      nativeBuildInputs = [crossPkgs.coreutils];
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

  # Turn an existing derivation into an Ardos derivation by attaching runtime
  # layout metadata. The original derivation is rebuilt via `overrideAttrs` so
  # that a `postInstall` hook can generate `$out/nix-support/ardos-layout`.
  #
  # Ardos-specific build attrs (`_ardos_translate`, `__ardosLdHook__`,
  # `ARDOS_EXTERNAL_MAPPINGS`) are injected so the rebuild has full linker
  # translation support even when the original derivation lacked them.
  #
  # Two-pass overrideAttrs: the first pass generates the layout file, the
  # second attaches `passthru.ardos` (including `runtimeTree`) which needs to
  # read from the first pass's output.
  #
  # Usage:
  #   wrapDerivation someDrv { runtimeLayoutScript = ''...''; }
  #   wrapDerivation someDrv { runtimeLayout = [ { source = "lib/..."; target = "/..."; } ]; }
  wrapDerivation = drv: {
    runtimeLayoutScript ? null,
    runtimeLayout ? [],
  }: let
    pname = drv.pname or drv.name;
    version = drv.version or "0";

    resolvedLayoutScript =
      if runtimeLayoutScript != null
      then runtimeLayoutScript
      else layoutListToScript runtimeLayout;

    # Pass 1: rebuild with ardos build attrs and layout-generating postInstall.
    drvWithLayout = drv.overrideAttrs (old: {
      _ardos_translate = let
        ardosEarlyInit = rustScript "ardos_ld_translate" ./hooks/ardos_ld_translate.rs;
        ardosEarlyInitExe = "${ardosEarlyInit}/bin/ardos_ld_translate";
      in
        ardosEarlyInitExe;
      __ardosLdHook__ = ./hooks/ld-wrapper-impl.sh;
      ARDOS_EXTERNAL_MAPPINGS = lib.optionalString (externalMappingsFile != null) "${externalMappingsFile}";

      postInstall =
        (old.postInstall or "")
        + ''
          echo "[Ardos Layout] Resolving runtime layout for ${pname} (wrapDerivation)..."

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

            : > $out/nix-support/ardos-layout
            [ "$layout_debug" = "1" ] && echo "[Ardos Layout] Walking $stage..." >&2

            while IFS= read -r -d $'\0' entry; do
              rel="''${entry#$stage/}"
              [ "$rel" = "$entry" ] && continue

              target="/$rel"

              if [ -L "$entry" ]; then
                pointed=$(readlink -f -- "$entry" 2>/dev/null || true)
                if [ -n "$pointed" ] && [[ "$pointed" == "$out"/* ]]; then
                  src_rel="''${pointed#$out/}"
                else
                  src_rel=$(readlink -- "$entry")
                fi
              elif [ -f "$entry" ]; then
                echo "error: runtimeLayoutScript for ${pname} created a concrete file in ardos-layout: $entry" >&2
                exit 1
              else
                continue
              fi

              printf '%s -> %s\n' "$src_rel" "$target" >> $out/nix-support/ardos-layout
            done < <(find "$stage" -mindepth 1 -print0)

            if [ "$layout_debug" = "1" ]; then
              echo "[Ardos Layout] Resolved layout for ${pname}:" >&2
              sed 's/^/  /' $out/nix-support/ardos-layout >&2
            fi
          fi

          if [ -n "''${ARDOS_RUNTIME_MAP:-}" ] && [ -f "$ARDOS_RUNTIME_MAP" ]; then
            cp "$ARDOS_RUNTIME_MAP" $out/nix-support/ardos-runtime-map
          fi
        '';
    });

    # Pass 2: attach passthru.ardos metadata. References drvWithLayout which
    # already contains nix-support/ardos-layout in its output.
    wrappedDrv = drvWithLayout.overrideAttrs (old: {
      passthru =
        (old.passthru or {})
        // {
          ardos = {
            runtimeLayoutScript = resolvedLayoutScript;
            runtimeTree = mkRuntimeTree {
              inherit pname version;
              drv = drvWithLayout;
            };
          };
        };
    });
  in
    wrappedDrv;

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
    drv = crossPkgs.stdenv.mkDerivation (cleanArgs
      // {
        _ardos_translate = let
          ardosEarlyInit = rustScript "ardos_ld_translate" ./hooks/ardos_ld_translate.rs;
          ardosEarlyInitExe = "${ardosEarlyInit}/bin/ardos_ld_translate";
        in
          ardosEarlyInitExe;
        __ardosLdHook__ = ./hooks/ld-wrapper-impl.sh;
        ARDOS_EXTERNAL_MAPPINGS = lib.optionalString (externalMappingsFile != null) "${externalMappingsFile}";
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
                  echo "error: runtimeLayoutScript for ${pname} created a concrete file in ardos-layout: $entry" >&2
                  exit 1
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

            # Keep the link-time runtime map as output metadata. The final ROM
            # never copies nix-support, but this file intentionally preserves
            # Nix references to mapped runtime dependencies so closureInfo can
            # discover transitive runtime packages even after RPATH/interpreter
            # paths have been translated away from /nix/store.
            if [ -n "''${ARDOS_RUNTIME_MAP:-}" ] && [ -f "$ARDOS_RUNTIME_MAP" ]; then
              cp "$ARDOS_RUNTIME_MAP" $out/nix-support/ardos-runtime-map
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
