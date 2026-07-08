{
  buildSystem,
  nixpkgs,
  targetPlatform,
  ...
}: let
  lib = nixpkgs.lib;

  cacheNixConfigPart = {
    extra-substituters = ["https://ardos-os.cachix.org"];
    extra-trusted-public-keys = ["ardos-os.cachix.org-1:ER39Zub8rFCCCdjZ7VUG+654TvPFkH8fvk2Iofzt74s="];
  };

  # Helper to inject config.sub patching into a derivation's preConfigure phase.
  # Runs in preConfigure (i.e. inside configurePhase), which is AFTER
  # updateAutotoolsGnuConfigScriptsPhase, so these sed expressions always win
  # even when that phase replaces config.sub with a vanilla gnu-config copy.
  # Multiple -e expressions are used to cover both the current gnu-config version
  # of config.sub and the slightly older version bundled inside glibc itself.
  # Unmatched expressions are silently ignored by sed.
  patchAutotoolsConfig = preConfigure: ''
    find . -name config.sub -exec sed -i {} \
      -e 's/| redox\* | bme\*/| redox* | ardos* | bme*/' \
      -e 's/| linux-relibc\*- | linux-uclibc\*- )/| linux-relibc*- | linux-uclibc*- | linux-ardos*- )/' \
      -e 's/| rtmk-nova\*)/| rtmk-nova* | ardos*)/' \
      -e 's/gnu\* | android\*/gnu* | android* | ardos*/' \
      -e 's/linux-android\* | linux-newlib\*/linux-android* | linux-ardos* | linux-newlib*/' \;
  '' + (if preConfigure == null then "" else preConfigure);

  # Wrap stdenv to automatically patch config.sub for autotools packages
  wrapStdenvForArdos = stdenv: stdenv // {
    mkDerivation = args: stdenv.mkDerivation (
      if builtins.isFunction args
      then (finalAttrs: let
        attrs = args finalAttrs;
      in attrs // {
        preConfigure = patchAutotoolsConfig (attrs.preConfigure or null);
      })
      else args // {
        preConfigure = patchAutotoolsConfig (args.preConfigure or null);
      }
    );
  };

  # Overlay to adapt Nixpkgs toolchain and packages for the Ardos target
  ardosOverlay = final: prev: let
    isTarget = prev.stdenv.hostPlatform.config == targetPlatform.config;
    isCrossTool = prev.stdenv.targetPlatform.config == targetPlatform.config && !isTarget;
  in
    if prev.stdenv.targetPlatform.config == targetPlatform.config
    then {
      # Wrap stdenv only for target packages (host == ardos) to patch config.sub in-place
      stdenv = if isTarget then wrapStdenvForArdos prev.stdenv else prev.stdenv;

      # Patch cross-binutils to support ardos target
      binutils-unwrapped = if isCrossTool
                           then prev.binutils-unwrapped.overrideAttrs (old: {
                             patches = (old.patches or []) ++ [ ./patches/binutils-add-ardos.patch ];
                             dontUpdateAutotoolsGnuConfigScripts = true;
                           })
                           else prev.binutils-unwrapped;

      # Apply LLVM/Clang environment overrides
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

      # Patch target glibc (and its bootstrap variants).
      # config.sub is handled via patchAutotoolsConfig in preConfigure (runs after
      # updateAutotoolsGnuConfigScriptsPhase, so it always takes precedence).
      # We set it explicitly here so it applies regardless of which bootstrap
      # stdenv stage is used to build glibc or glibc-nolibgcc.
      glibc = prev.glibc.overrideAttrs (old: {
        preConfigure = patchAutotoolsConfig (old.preConfigure or null);
      });
    }
    else {};
in rec {
  beforePatchBuildPkgs = import nixpkgs ({
      system = buildSystem;
    }
    // cacheNixConfigPart);

  patchedNixpkgs = beforePatchBuildPkgs.applyPatches {
    name = "nixpkgs-ardos";
    src = nixpkgs;
    patches = [./patches/nixpkgs.patch];
  };

  buildPkgs = import patchedNixpkgs ({
      system = buildSystem;
    }
    // cacheNixConfigPart);

  crossPkgs = let
    pkgs = import patchedNixpkgs ({
        system = buildPkgs.stdenv.buildPlatform.system;
        crossSystem = targetPlatform;
        overlays = [ ardosOverlay ];
      }
      // cacheNixConfigPart);
  in
    assert buildPkgs.stdenv.buildPlatform.config != targetPlatform.config;
    assert pkgs.stdenv.buildPlatform.config == buildPkgs.stdenv.buildPlatform.config;
    assert pkgs.stdenv.hostPlatform.config == targetPlatform.config;
    assert pkgs.stdenv.targetPlatform.config == targetPlatform.config; pkgs;

  toolchain = {
    cc = crossPkgs.clang;
    libgcc = crossPkgs.libgcc.meta.position;
  };
}
