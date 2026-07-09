# lib/toolchain — Stage 1: cross-compilation toolchain.
#
# Builds `crossPkgs`, a Nixpkgs instance configured for the Ardos target
# (e.g. x86_64-linux-ardos). Wires the overlay that:
#
#   * patches cross-binutils and glibc for the ardos ABI
#   * wraps the target stdenv so every Ardos package gets config.sub patched
#     (without invalidating the toolchain itself) and the ardos-setup hook
#   * injects the stable ld-wrapper stub into the cross bintools wrapper
#   * patches LLVM's environment detection
#
# `host` is the patched host nixpkgs from Stage 0.
# `builder` exposes `rustScript`, used here to compile ardos-setup-tool.
{
  nixpkgs,
  targetPlatform,
  buildSystem,
  host,
  rustScript,
}: let
  inherit (host) cacheNixConfigPart patchedNixpkgs;

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
        -e 's/| linux-relibc\*- | linux-uclibc\*- )/| linux-relibc*- | linux-uclibc*- | linux-ardos*- )/' \
        -e 's/| rtmk-nova\*)/| rtmk-nova* | ardos*)/' \
        -e 's/gnu\* | android\*/gnu* | android* | ardos*/' \
        -e 's/linux-android\* | linux-newlib\*/linux-android* | linux-ardos* | linux-newlib*/' \;
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

      binutils-unwrapped =
        if isCrossTool
        then
          prev.binutils-unwrapped.overrideAttrs (old: {
            patches = (old.patches or []) ++ [./patches/binutils-add-ardos.patch];
            dontUpdateAutotoolsGnuConfigScripts = true;
          })
        else prev.binutils-unwrapped;

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

      llvmPackages = prev.llvmPackages.overrideScope (llvmFinal: llvmPrev: {
        llvm = llvmPrev.llvm.overrideAttrs (old: {
          patches =
            (old.patches or [])
            ++ [
              ./patches/llvm-add-ardos-environment.patch
            ];
        });
      });
      clang = final.llvmPackages.clang;

      glibc = prev.glibc.overrideAttrs (old: {
        preConfigure = patchAutotoolsConfig (old.preConfigure or null);
      });
    }
    else {};
in rec {
  buildPkgs =
    import patchedNixpkgs {
      system = buildSystem;
    }
    // cacheNixConfigPart;

  crossPkgs = let
    pkgs =
      import patchedNixpkgs {
        system = buildPkgs.stdenv.buildPlatform.system;
        crossSystem = targetPlatform;
        overlays = [ardosOverlay];
      }
      // cacheNixConfigPart;
  in
    assert buildPkgs.stdenv.buildPlatform.config != targetPlatform.config;
    assert pkgs.stdenv.buildPlatform.config == buildPkgs.stdenv.buildPlatform.config;
    assert pkgs.stdenv.hostPlatform.config == targetPlatform.config;
    assert pkgs.stdenv.targetPlatform.config == targetPlatform.config; pkgs;

  toolchain = {
    cc = crossPkgs.stdenv.cc;
    binutils = crossPkgs.bintools;
    glibc = crossPkgs.glibc;
    bash = buildPkgs.bash;
  };
}
