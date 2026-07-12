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

    # Architecture-specific settings for the built-in Rust target.
    # Each entry maps a Nix CPU name (targetPlatform.cpu) to the values
    # needed in the generated rustc_target target file.
    archRustSettings = {
      x86_64 = {
        targetTriple = "x86_64-ardos-linux-gnu";
        rustModule = "x86_64_ardos_linux_gnu";
        llvmTarget = "x86_64-unknown-linux-gnu";
        cpu = "x86-64";
        maxAtomicWidth = 64;
        archEnum = "Arch::X86_64";
        dataLayout = ''"e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"'';
        preLinkArgs = ''
          base.add_pre_link_args(LinkerFlavor::Gnu(Cc::Yes, Lld::No), &["-m64"]);
          base.add_pre_link_args(LinkerFlavor::Gnu(Cc::Yes, Lld::Yes), &["-m64"]);
        '';
        sanitizers = "SanitizerSet::ADDRESS | SanitizerSet::CFI | SanitizerSet::KCFI | SanitizerSet::DATAFLOW | SanitizerSet::LEAK | SanitizerSet::MEMORY | SanitizerSet::SAFESTACK | SanitizerSet::THREAD | SanitizerSet::REALTIME";
        supportsXray = true;
        pltByDefault = false;
      };
      aarch64 = {
        targetTriple = "aarch64-ardos-linux-gnu";
        rustModule = "aarch64_ardos_linux_gnu";
        llvmTarget = "aarch64-unknown-linux-gnu";
        cpu = "generic";
        maxAtomicWidth = 128;
        archEnum = "Arch::AArch64";
        dataLayout = ''"e-m:e-p270:32:32-p271:32:32-p272:64:64-i8:8:32-i16:16:32-i64:64-i128:128-n32:64-S128-Fn32"'';
        preLinkArgs = "";
        sanitizers = "SanitizerSet::ADDRESS | SanitizerSet::CFI | SanitizerSet::KCFI | SanitizerSet::LEAK | SanitizerSet::MEMORY | SanitizerSet::MEMTAG | SanitizerSet::THREAD | SanitizerSet::HWADDRESS | SanitizerSet::REALTIME";
        supportsXray = true;
        pltByDefault = true;
      };
    };

    # Select settings for the current target CPU.
    ardosTargetCpu = targetPlatform.cpu;
    ardosTargetCfg = builtins.getAttr ardosTargetCpu archRustSettings;

    # Build the Rust target source file content from the settings.
    ardosTargetRs = ''
      use crate::spec::{
          Arch, Cc, LinkerFlavor, Lld, SanitizerSet, StackProbeType, Target,
          TargetMetadata, base,
      };

      pub(crate) fn target() -> Target {
          let mut base = base::linux_gnu::opts();
          base.cpu = "${ardosTargetCfg.cpu}".into();
          base.plt_by_default = ${if ardosTargetCfg.pltByDefault then "true" else "false"};
          base.max_atomic_width = Some(${toString ardosTargetCfg.maxAtomicWidth});
          base.stack_probes = StackProbeType::Inline;
          base.static_position_independent_executables = true;
          base.supported_sanitizers = ${ardosTargetCfg.sanitizers};
          base.supports_xray = ${if ardosTargetCfg.supportsXray then "true" else "false"};
          base.has_rpath = false;
          base.vendor = "ardos".into();
          ${ardosTargetCfg.preLinkArgs}
          Target {
              llvm_target: "${ardosTargetCfg.llvmTarget}".into(),
              metadata: TargetMetadata {
                  description: Some("${ardosTargetCpu} Ardos OS".into()),
                  tier: Some(3),
                  host_tools: Some(false),
                  std: Some(true),
              },
              pointer_width: 64,
              data_layout: ${ardosTargetCfg.dataLayout}.into(),
              arch: ${ardosTargetCfg.archEnum},
              options: base,
          }
      }
    '';

    # Build rustc with the Ardos target as a built-in (tier 3).
    # With fastCross=false, stage0 (pre-built) compiles stage1 from the
    # patched source; stage1 then builds std for Ardos.
    ardosRustcUnwrapped = (prev.rustc.unwrapped.override {
      fastCross = false;
    }).overrideAttrs (old: {
      postPatch = (old.postPatch or "") + ''
        TARGET_DIR=compiler/rustc_target/src/spec/targets
        cat > "$TARGET_DIR/${ardosTargetCfg.rustModule}.rs" << 'RSEOF'
    ${ardosTargetRs}
    RSEOF

        # Register in the target list (before the first x86_64 entry).
        sed -i '/^supported_targets! {$/a\    ("${ardosTargetCfg.targetTriple}", ${ardosTargetCfg.rustModule}),' compiler/rustc_target/src/spec/mod.rs

        # Stage0 (pre-built) doesn't know about our new target yet, so mark it
        # as missing so the sanity check in bootstrap doesn't panic.
        sed -i '/^const STAGE0_MISSING_TARGETS:/a\    "${ardosTargetCfg.targetTriple}",' src/bootstrap/src/core/sanity.rs
      '';
    });
    ardosRustc = prev.rustc.override {
      rustc-unwrapped = ardosRustcUnwrapped;
      sysroot = null;
    };
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

      rustc = ardosRustc;

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
