# mkArdosDerivation — Stage 2 (per-package builder).
#
# Exposes the package builder abstraction for Ardos runtime packages.
# Separates target compilation/linking (stdenv) from package runtime layout
# definition.
#
# A package declares its runtime layout with `runtimeLayout`: a list of
# { source, target } entries where source is relative to $out and target is
# an absolute Ardos path. Sources ending with "/" are folder mappings — the
# ld wrapper expands them on-the-fly via longest-prefix matching at link
# time, and the sysroot expands them at assembly time.
#
# The layout entries are written directly to `$out/nix-support/ardos-layout`
# without an intermediate symlink tree. This file is the single source of
# truth consumed by the linker wrapper, downstream packages, and the ROM
# generator.
#
# File-local relative paths (./hooks/*) are relative to this file's location
# in lib/builder/.
{
  nixpkgs,
  crossPkgs,
  rustScript,
  crane ? null,
  externalMappings ? [],
}: let
  lib = nixpkgs.lib;
  stdenv = crossPkgs.stdenv;

  # Convert a runtimeLayout list to raw ardos-layout text (for env vars).
  # Each entry becomes a "source -> target" line.
  layoutListToText = entries:
    lib.concatMapStrings (entry: ''
      ${entry.source} -> ${entry.target}
    '') entries;

  # Convert a runtimeLayout list to shell commands that write ardos-layout.
  layoutListToLayout = entries:
    lib.concatMapStrings (entry: ''
      printf '%s\n' '${entry.source} -> ${entry.target}' >> $out/nix-support/ardos-layout
    '') entries;

  # Generate external mappings file from a list of { drv, runtimeLayout } entries.
  # Each entry's runtimeLayout is written as ardos-layout lines prefixed by a
  # section header so populate-map.rs can apply them per-dependency.
  mappingScriptToLayout = mapping: ''
    echo "# ardos-external-mapping ${mapping.drv}" >> "$out"
    ${lib.concatMapStrings (entry: ''
      printf '%s -> %s\n' "${entry.source}" "${entry.target}" >> "$out"
    '') mapping.runtimeLayout}
  '';

  externalMappingsFile =
    if externalMappings == []
    then null
    else
      nixpkgs.runCommand "ardos-external-runtime-mappings" {
        nativeBuildInputs = [nixpkgs.coreutils nixpkgs.bash];
      } ''
        : > "$out"
        ${lib.concatMapStringsSep "\n" mappingScriptToLayout externalMappings}
      '';
in rec {
  # Turn an existing derivation into an Ardos derivation by attaching runtime
  # layout metadata. The original derivation is rebuilt via `overrideAttrs` so
  # that a `postInstall` hook can generate `$out/nix-support/ardos-layout`.
  #
  # Ardos-specific build attrs (`_ardos_translate`, `__ardosLdHook__`,
  # `ARDOS_EXTERNAL_MAPPINGS`) are injected so the rebuild has full linker
  # translation support even when the original derivation lacked them.
  #
  # Two-pass overrideAttrs: the first pass generates the layout file, the
  # second attaches `passthru.ardos` metadata.
  #
  # Usage:
  #   wrapDerivation someDrv { runtimeLayout = [ { source = "lib/..."; target = "/..."; } ]; }
  wrapDerivation = drv: {
    runtimeLayout ? [],
  }: let
    pname = drv.pname or drv.name;
    version = drv.version or "0";

    resolvedLayout = layoutListToLayout runtimeLayout;
    layoutText = layoutListToText runtimeLayout;

    # Pass 1: rebuild with ardos build attrs and layout-generating postInstall.
    drvWithLayout = drv.overrideAttrs (old: {
      # The ld wrapper handles RPATH translation at link time — patchelf is
      # redundant and would interfere with the translated paths.
      dontPatchELF = true;
      dontShrinkRpath = true;

      _ardos_translate = let
        ardosEarlyInit = rustScript "ardos_ld_translate" ./hooks/ardos_ld_translate.rs;
        ardosEarlyInitExe = "${ardosEarlyInit}/bin/ardos_ld_translate";
      in
        ardosEarlyInitExe;
      __ardosLdHook__ = ./hooks/ld-wrapper-impl.sh;
      ARDOS_EXTERNAL_MAPPINGS = lib.optionalString (externalMappingsFile != null) "${externalMappingsFile}";
        ARDOS_CURRENT_PACKAGE_LAYOUT = layoutText;

      postInstall =
        (old.postInstall or "")
        + ''
          echo "[Ardos Layout] Writing runtime layout for ${pname} (wrapDerivation)..."

          if [ "''${NIX_DEBUG:-0}" = "1" ]; then
            layout_debug=1
          else
            layout_debug=0
          fi

          mkdir -p $out/nix-support

          if [ -z "${toString resolvedLayout}" ]; then
            echo "[Ardos Layout] No runtimeLayout declared; writing empty layout." >&2
            : > $out/nix-support/ardos-layout
          else
            : > $out/nix-support/ardos-layout
            ${resolvedLayout}

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

    # Pass 2: attach passthru.ardos metadata.
    wrappedDrv = drvWithLayout.overrideAttrs (old: {
      passthru =
        (old.passthru or {})
        // {
          ardos = {
            runtimeLayout = runtimeLayout;
          };
        };
    });
  in
    wrappedDrv;

  # Convenience wrapper: crane buildPackage + wrapDerivation.
  buildArdosRustPackage = {
    runtimeLayout ? [],
    ...
  } @ args: let
    rustArgs = removeAttrs args ["runtimeLayout"];
    # Use `crossPkgs` so crane detects cross-compilation (build != host) and
    # auto-emits CARGO_BUILD_TARGET / CARGO_TARGET_<arch>_LINKER / CC_<arch>
    # for the Ardos triple. But override the toolchain crane would otherwise
    # pull from the host=ardos splice (which forces a from-source rustc build
    # for the unknown `ardos` host) and point it back at the build-hosted,
    # Ardos-patched rustc/cargo from `pkgsBuildTarget` (the same derivation the
    # previous `crane.mkLib crossPkgs.pkgsBuildTarget` used).
    craneLib =
      if crane == null
      then throw "buildArdosRustPackage: crane input is null — pass crane to ap2.init"
      else crane.mkLib crossPkgs;
    drv = craneLib.buildPackage (rustArgs // {
      strictDeps = true;
      doCheck = false;
    });
  in
    wrapDerivation drv {
      inherit runtimeLayout;
    };

  # The main package builder
  mkArdosDerivation = {
    pname,
    version,
    # List of { source, target } entries. Source is relative to $out.
    # Sources ending with "/" are folder mappings.
    runtimeLayout ? [],
    ...
  } @ args: let
    # Strip ardos-specific attrs before forwarding to mkDerivation.
    cleanArgs = removeAttrs args ["runtimeLayout"];

    resolvedLayout = layoutListToLayout runtimeLayout;
    layoutText = layoutListToText runtimeLayout;

    # Build the derivation using our target stdenv
    drv = crossPkgs.stdenv.mkDerivation (cleanArgs
      // {
        # The ld wrapper handles RPATH translation at link time — patchelf is
        # redundant and would interfere with the translated paths.
        dontPatchELF = true;
        dontShrinkRpath = true;

        _ardos_translate = let
          ardosEarlyInit = rustScript "ardos_ld_translate" ./hooks/ardos_ld_translate.rs;
          ardosEarlyInitExe = "${ardosEarlyInit}/bin/ardos_ld_translate";
        in
          ardosEarlyInitExe;
        __ardosLdHook__ = ./hooks/ld-wrapper-impl.sh;
        ARDOS_EXTERNAL_MAPPINGS = lib.optionalString (externalMappingsFile != null) "${externalMappingsFile}";
        ARDOS_CURRENT_PACKAGE_LAYOUT = layoutText;
        NIX_DEBUG = "1";

        # Write ardos-layout directly from runtimeLayout entries.
        # No symlink tree, no find-based expansion. Folder mappings are
        # preserved as-is and expanded by the ld translator (at link time)
        # and the sysroot (at assembly time).
        postInstall =
          (args.postInstall or "")
          + ''
            echo "[Ardos Layout] Writing runtime layout for ${pname}..."

            if [ "''${NIX_DEBUG:-0}" = "1" ]; then
              layout_debug=1
            else
              layout_debug=0
            fi

            mkdir -p $out/nix-support

            if [ -z "${toString resolvedLayout}" ]; then
              echo "[Ardos Layout] No runtimeLayout declared; leaving layout to default generator." >&2
            else
              : > $out/nix-support/ardos-layout
              ${resolvedLayout}

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
            runtimeLayout = runtimeLayout;
          };
        };
    });

  # Identical to mkArdosDerivation but uses clangStdenv instead of stdenv.
  # Required for packages that need clang as the cross compiler (e.g. systemd
  # BPF compilation, which invokes clang -target bpf directly).
  mkArdosDerivationClang = {
    pname,
    version,
    runtimeLayout ? [],
    ...
  } @ args: let
    cleanArgs = removeAttrs args ["runtimeLayout"];

    resolvedLayout = layoutListToLayout runtimeLayout;
    layoutText = layoutListToText runtimeLayout;

    drv = crossPkgs.clangStdenv.mkDerivation (cleanArgs
      // {
        dontPatchELF = true;
        dontShrinkRpath = true;

        _ardos_translate = let
          ardosEarlyInit = rustScript "ardos_ld_translate" ./hooks/ardos_ld_translate.rs;
          ardosEarlyInitExe = "${ardosEarlyInit}/bin/ardos_ld_translate";
        in
          ardosEarlyInitExe;
        __ardosLdHook__ = ./hooks/ld-wrapper-impl.sh;
        ARDOS_EXTERNAL_MAPPINGS = lib.optionalString (externalMappingsFile != null) "${externalMappingsFile}";
        ARDOS_CURRENT_PACKAGE_LAYOUT = layoutText;
        NIX_DEBUG = "1";

        postInstall =
          (args.postInstall or "")
          + ''
            echo "[Ardos Layout] Writing runtime layout for ${pname} (clang)..."

            if [ "''${NIX_DEBUG:-0}" = "1" ]; then
              layout_debug=1
            else
              layout_debug=0
            fi

            mkdir -p $out/nix-support

            if [ -z "${toString resolvedLayout}" ]; then
              echo "[Ardos Layout] No runtimeLayout declared; leaving layout to default generator." >&2
            else
              : > $out/nix-support/ardos-layout
              ${resolvedLayout}

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
  in
    drv.overrideAttrs (old: {
      passthru =
        old.passthru or {
          ardos = {
            runtimeLayout = runtimeLayout;
          };
        };
    });
}
