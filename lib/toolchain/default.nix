# lib/toolchain — Stage 1: cross-compilation toolchain.
#
# Builds `crossPkgs`, a Nixpkgs instance configured for the Ardos target
# (e.g. x86_64-ardos-linux-gnu). Wires the overlay that:
#
#   * strips Nix-specific runtime artifacts from glibc (via overlay/ardos-glibc.nix)
#   * wraps the target stdenv so every Ardos package gets config.sub patched
#     (without invalidating the toolchain itself) and the ardos-setup hook
#   * injects the stable ld-wrapper stub into the cross bintools wrapper
#
# `host` is the patched host nixpkgs from Stage 0.
# `builder` exposes `rustScript`, used here to compile ardos-setup-tool.
# `toolchainConfig` carries toolchain-level concerns (e.g. glibc.runtimePrefix).
{
  nixpkgs,
  targetPlatform,
  buildSystem,
  host,
  rustScript,
  toolchainConfig ? {},
}: let
  inherit (host) patchedNixpkgs;

  # Helper to inject config.sub patching into a derivation's preConfigure phase.
  # Runs in preConfigure (i.e. inside configurePhase), which is AFTER
  # updateAutotoolsGnuConfigScriptsPhase, so these sed expressions always win
  # even when that phase replaces config.sub with a vanilla gnu-config copy.
  # Multiple -e expressions are used to cover both the current gnu-config version
  # of config.sub and the slightly older version bundled inside glibc itself.
  # Unmatched expressions are silently ignored by sed.
  patchAutotoolsConfig = preConfigure:
    ''
      find . -name config.sub -exec sed -i {} \
        -e 's/| redox\* | bme\*/| redox* | ardos* | bme*/' \
        -e 's/| rtmk-nova\*)/| rtmk-nova* | ardos*)/' \
        -e 's/gnu\* | android\*/gnu* | android* | ardos*/' \;
    ''
    + (
      if preConfigure == null
      then ""
      else preConfigure
    );

  # Wrap stdenv to automatically patch config.sub and register setup hooks
  wrapStdenvForArdos = stdenv: setupHook:
    stdenv
    // {
      mkDerivation = args:
        stdenv.mkDerivation (
          if builtins.isFunction args
          then
            (finalAttrs: let
              attrs = args finalAttrs;
            in
              attrs
              // {
                preConfigure = patchAutotoolsConfig (attrs.preConfigure or null);
                nativeBuildInputs = (attrs.nativeBuildInputs or []) ++ [setupHook];
              })
          else
            args
            // {
              preConfigure = patchAutotoolsConfig (args.preConfigure or null);
              nativeBuildInputs = (args.nativeBuildInputs or []) ++ [setupHook];
            }
        );
    };

  # Overlay to adapt Nixpkgs toolchain and packages for the Ardos target
  ardosOverlay = final: prev: let
    isTarget = prev.stdenv.hostPlatform.config == targetPlatform.config;
    isCrossTool = prev.stdenv.targetPlatform.config == targetPlatform.config && !isTarget;
    ardosSetupHookDrv = let
      ardosEarlyInit = rustScript "ardos-setup-early-init" ../builder/setup/early-init.rs;
      ardosEarlyInitExe = "${ardosEarlyInit}/bin/ardos-setup-early-init";
      ardosPopulateMap = rustScript "ardos-setup-populate-map" ../builder/setup/populate-map.rs;
      ardosPopulateMapExe = "${ardosPopulateMap}/bin/ardos-setup-populate-map";
      ardosGenerateDefaultLayout = rustScript "ardos-setup-generate-layout" ../builder/setup/generate-layout.rs;
      ardosGenerateDefaultLayoutExe = "${ardosGenerateDefaultLayout}/bin/ardos-setup-generate-layout";
      ardosTranslateShebangs = rustScript "ardos-setup-translate-shebangs" ../builder/setup/translate-shebangs.rs;
      ardosTranslateShebangsExe = "${ardosTranslateShebangs}/bin/ardos-setup-translate-shebangs";
    in
      prev.makeSetupHook {
        name = "ardos-setup-hook";
      } (prev.replaceVars ../builder/setup/ardos-setup.sh {
        ardosEarlyOut = ardosEarlyInitExe;
        ardosPopulateMapOut = ardosPopulateMapExe;
        ardosGenerateDefaultLayoutOut = ardosGenerateDefaultLayoutExe;
        ardosTranslateShebangsOut = ardosTranslateShebangsExe;
      });
  in
    if prev.stdenv.targetPlatform.config == targetPlatform.config
    then {
      stdenv =
        if isTarget
        then wrapStdenvForArdos prev.stdenv ardosSetupHookDrv
        else prev.stdenv;

      bintools =
        if isCrossTool
        then
          prev.bintools.overrideAttrs (old: {
            postFixup =
              (old.postFixup or "")
              + ''
                cp ${../builder/hooks/ld-wrapper.sh} $out/nix-support/ld-wrapper-hook
              '';
          })
        else prev.bintools;

      clang = prev.llvmPackages.clang;

      glibc = let
        ardosGlibcOverlay = import ./overlay/ardos-glibc.nix {lib = nixpkgs.lib;};
        glibcConfig = toolchainConfig.glibc or {};
        overlay = ardosGlibcOverlay {
          glibc = prev.glibc;
          runtimePrefix = glibcConfig.runtimePrefix or null;
        };
      in (overlay final prev).glibc.overrideAttrs (old: {
        preConfigure = patchAutotoolsConfig (old.preConfigure or null);
      });

      # glibc-nolibgcc is the bootstrap variant (libgcc=null) used to
      # build libgcc.  Because `override` preserves `overrideAttrs`,
      # glibc.override { libgcc = null; } inherits our --prefix/libdir
      # and install_root overrides, which break its install (double-nested
      # store paths) and would also break libgcc (wrong library paths).
      # Pin it to the pre-overlay version so the bootstrap chain stays clean.
      glibc-nolibgcc = prev.glibc.override { libgcc = null; };

      # Redirect nixpkgs' libgcc (defined inline with glibc.override) to
      # use the clean glibc-nolibgcc above instead of inheriting ours.
      libgcc = prev.libgcc.override {
        glibc = final.glibc-nolibgcc;
      };
    }
    else {};
in rec {
  buildPkgs = import patchedNixpkgs {
    system = buildSystem;
  };

  crossPkgs = let
    pkgs = import patchedNixpkgs {
      system = buildPkgs.stdenv.buildPlatform.system;
      crossSystem = targetPlatform;
      overlays = [ardosOverlay];
    };
  in
    assert buildPkgs.stdenv.buildPlatform.config != targetPlatform.config;
    assert pkgs.stdenv.buildPlatform.config == buildPkgs.stdenv.buildPlatform.config;
    assert pkgs.stdenv.hostPlatform.config == targetPlatform.config;
    assert pkgs.stdenv.targetPlatform.config == targetPlatform.config; pkgs;

  toolchain = {
    cc = crossPkgs.stdenv.cc;
    binutils = crossPkgs.pkgsBuildTarget.bintools;
    glibc = crossPkgs.pkgsBuildTarget.glibc;
    bash = buildPkgs.pkgsBuildTarget.bash;
  };
}
