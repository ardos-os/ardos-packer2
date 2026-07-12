# Probe: does nixpkgs automatically provide rust-std for Ardos targets?
#
# Run with:
#   nix eval --json .#probe-rust.x86_64  (eval-only, no build)
#   nix build .#probe-rust.x86_64.rustStdCheck  (builds rustc + checks)

{
  lib,
  nixpkgs,
  ap2,
}: let
  probe = buildSystem: targetPlatform: let
    instance = ap2.init {
      inherit nixpkgs buildSystem targetPlatform;
      externalMappings = import ../tests/fixtures/glibcExternalMappings.nix;
    };
    crossPkgs = instance.crossPkgs;
    target = targetPlatform.config;

    # The cross-compiling toolchain lives in pkgsBuildTarget:
    # packages that run on the build machine but target the Ardos platform.
    buildTarget = crossPkgs.pkgsBuildTarget;

    rustcTargetSpec = builtins.toString (crossPkgs.stdenv.hostPlatform.rust.rustcTargetSpec or "N/A");
    cargoShortTarget_ = crossPkgs.stdenv.hostPlatform.rust.cargoShortTarget or "N/A";
  in {
    # Structural attributes (eval-only, no build needed)
    inherit target rustcTargetSpec cargoShortTarget_;

    # Does the cross-compiling toolchain exist?
    rustcExists = buildTarget ? rustc;
    cargoExists = buildTarget ? cargo;
    rustPlatformExists = buildTarget ? rustPlatform;
    buildRustPackageExists = buildTarget.rustPlatform ? buildRustPackage;
    cargoSetupHookExists = buildTarget.rustPlatform ? cargoSetupHook;
    cargoBuildHookExists = buildTarget.rustPlatform ? cargoBuildHook;

    # Also check what the native crossPkgs exposes (for comparison)
    nativeRustcExists = crossPkgs ? rustc;
    nativeRustPlatformExists = crossPkgs ? rustPlatform;

    # Derivation that, when built, checks if rust-std exists and compiles a file
    rustStdCheck = buildTarget.runCommand "probe-rust-std-${target}" {
      nativeBuildInputs = [buildTarget.rustc];
    } ''
      echo "=== Rust cross-compiler sysroot probe for ${target} ==="
      echo "rustc: $(which rustc)"
      rustc --version
      echo ""

      # Check what --target the cross-compiler expects
      echo "=== Target spec ==="
      echo "rustcTargetSpec: ${rustcTargetSpec}"
      echo "cargoShortTarget: ${cargoShortTarget_}"
      echo ""

      # Check if rust-std libraries exist in the sysroot
      RUSTC_LIBDIR="${buildTarget.rustc}/lib/rustlib/${cargoShortTarget_}/lib"
      echo "Looking for rust-std at: $RUSTC_LIBDIR"

      if [ -d "$RUSTC_LIBDIR" ]; then
        echo "PASS: rust-std directory exists"
        ls "$RUSTC_LIBDIR/" | head -20
      else
        echo "WARN: rust-std directory does NOT exist at expected path"
        echo "Contents of rustlib:"
        ls "${buildTarget.rustc}/lib/rustlib/" 2>/dev/null || true
        echo "Trying to compile anyway..."
      fi
      echo ""

      # Try compiling a no_std file to prove the toolchain targets Ardos
      echo "=== Testing: compile a trivial .rs file ==="
      cat > /tmp/hello.rs << 'RSEOF'
#![no_std]
#[no_mangle]
pub extern "C" fn ardosprobe() -> i32 { 42 }
RSEOF

      rustc \
        --target "${rustcTargetSpec}" \
        --crate-type lib \
        /tmp/hello.rs \
        -o "$out/hello.o" \
        && echo "PASS: rustc compiled a .rs file for ${target}" \
        || { echo "FAIL: rustc could not compile for ${target}"; exit 1; }

      file "$out/hello.o"
      echo "Done."
    '';
  };

  x86_64Probe = probe "x86_64-linux" ap2.platforms.x86_64;
in {
  x86_64 = x86_64Probe;
}
