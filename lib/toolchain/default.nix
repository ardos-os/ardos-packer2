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

    # Build rustc with `x86_64-ardos-linux-gnu` as a built-in target (tier 3).
    #
    # The target is injected into the rustc source via postPatch.  With
    # fastCross=false, stage0 (pre-built) compiles stage1 from the patched
    # source; stage1 then builds std for Ardos.  No JSON specs, no unstable
    # flags, no TOML injection hacks needed.
    ardosRustcUnwrapped = (prev.rustc.unwrapped.override {
      fastCross = false;
    }).overrideAttrs (old: {
      postPatch = (old.postPatch or "") + ''
        # Add `x86_64-ardos-linux-gnu` as a built-in Rust target.
        # Model: tier 3, linux-gnu ABI with Ardos vendor.
        TARGET_DIR=compiler/rustc_target/src/spec/targets
        cat > $TARGET_DIR/x86_64_ardos_linux_gnu.rs << 'RSEOF'
    use crate::spec::{
        Arch, Cc, LinkerFlavor, Lld, SanitizerSet, StackProbeType, Target,
        TargetMetadata, base,
    };

    pub(crate) fn target() -> Target {
        let mut base = base::linux_gnu::opts();
        base.cpu = "x86-64".into();
        base.plt_by_default = false;
        base.max_atomic_width = Some(64);
        base.add_pre_link_args(LinkerFlavor::Gnu(Cc::Yes, Lld::No), &["-m64"]);
        base.add_pre_link_args(LinkerFlavor::Gnu(Cc::Yes, Lld::Yes), &["-m64"]);
        base.stack_probes = StackProbeType::Inline;
        base.static_position_independent_executables = true;
        base.supported_sanitizers = SanitizerSet::ADDRESS
            | SanitizerSet::CFI
            | SanitizerSet::KCFI
            | SanitizerSet::DATAFLOW
            | SanitizerSet::LEAK
            | SanitizerSet::MEMORY
            | SanitizerSet::SAFESTACK
            | SanitizerSet::THREAD
            | SanitizerSet::REALTIME;
        base.supports_xray = true;
        base.has_rpath = false;
        base.vendor = "ardos".into();

        Target {
            llvm_target: "x86_64-unknown-linux-gnu".into(),
            metadata: TargetMetadata {
                description: Some("x86_64 Ardos OS".into()),
                tier: Some(3),
                host_tools: Some(false),
                std: Some(true),
            },
            pointer_width: 64,
            data_layout:
                "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128".into(),
            arch: Arch::X86_64,
            options: base,
        }
    }
    RSEOF

        # Register in the target list (before x86_64-unknown-linux-gnu).
        sed -i '/^supported_targets! {$/a\    ("x86_64-ardos-linux-gnu", x86_64_ardos_linux_gnu),' compiler/rustc_target/src/spec/mod.rs

        # Stage0 (pre-built) doesn't know about our new target yet, so mark it
        # as missing so the sanity check in bootstrap doesn't panic.
        sed -i '/^const STAGE0_MISSING_TARGETS:/a\    "x86_64-ardos-linux-gnu",' src/bootstrap/src/core/sanity.rs
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
