## ROM with custom runtimePrefix — validates toolchainConfig.glibc.runtimePrefix.
##
## Sets runtimePrefix = "/ardos" and verifies the dynamic linker
## has the correct compiled-in PREFIX (no /nix/store paths).
{
  name = "toolchain-config";

  ## glibc and libgcc must be in the closure for the linker to be present.
  packages = crossPkgs: [
    crossPkgs.glibc
    crossPkgs.gcc.cc.libgcc
  ];

  toolchainConfig = {
    glibc = {
      runtimePrefix = "/ardos";
    };
  };

  ## Verify the dynamic linker has no /nix/store references.
  check = ctx: sysroot: let
    linkerNames = {
      x86_64-linux-ardos = "ld-linux-x86-64.so.2";
      aarch64-linux-ardos = "ld-linux-aarch64.so.1";
      riscv64-linux-ardos = "ld-linux-riscv64-lp64d.so.1";
    };
    ldName = linkerNames.${ctx.targetTriple};
  in ctx.buildPkgs.runCommand "e2e-toolchain-config-check" {} ''
    ld="${sysroot}/ardos/lib/${ldName}"
    if [ ! -f "$ld" ]; then
      echo "FAIL: dynamic linker not found at $ld" >&2
      exit 1
    fi

    # The linker must not contain embedded /nix/store paths.
    if strings "$ld" | grep -q '/nix/store/'; then
      echo "FAIL: dynamic linker contains /nix/store paths:" >&2
      strings "$ld" | grep '/nix/store/' >&2
      exit 1
    fi

    echo "PASS: toolchain-config e2e check" >&2
    touch $out
  '';
}
