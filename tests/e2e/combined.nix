## Combined test: runtimePrefix + glibcPlugins together.
##
## Validates that plugins are installed to the correct runtime prefix
## paths (e.g. /ardos/lib/libnss_files.so, /ardos/etc/nsswitch.conf)
## when both toolchainConfig and glibcPlugins are active.
{
  name = "combined";

  packages = crossPkgs: [
    crossPkgs.glibc
    crossPkgs.gcc.cc.libgcc
  ];

  toolchainConfig = {
    glibc = {
      runtimePrefix = "/ardos";
    };
  };

  glibcPlugins = crossPkgs: [
    (import ../../lib/plugins/nss-files.nix {
      glibc = crossPkgs.glibc;
      runCommand = crossPkgs.runCommand;
    })
  ];

  check = ctx: sysroot: let
    linkerNames = {
      x86_64-ardos-linux-gnu = "ld-linux-x86-64.so.2";
      aarch64-ardos-linux-gnu = "ld-linux-aarch64.so.1";
      riscv64-ardos-linux-gnu = "ld-linux-riscv64-lp64d.so.1";
    };
    ldName = linkerNames.${ctx.targetTriple} or (throw
      "combined e2e test: no linker name defined for ${ctx.targetTriple}");
  in ctx.buildPkgs.runCommand "e2e-combined-check" {} ''
    # Verify nsswitch.conf is at the runtime prefix etc path.
    if [ ! -f "${sysroot}/ardos/etc/nsswitch.conf" ]; then
      echo "FAIL: nsswitch.conf not found at /ardos/etc/nsswitch.conf" >&2
      exit 1
    fi

    # Verify the nsswitch.conf content is correct.
    if ! grep -q "^passwd: files$" "${sysroot}/ardos/etc/nsswitch.conf"; then
      echo "FAIL: nsswitch.conf missing passwd: files" >&2
      exit 1
    fi

    # Verify libnss_files.so is at the runtime prefix lib path.
    if [ ! -f "${sysroot}/ardos/lib/libnss_files.so.2" ]; then
      echo "FAIL: libnss_files.so.2 not found at /ardos/lib/libnss_files.so.2" >&2
      ls -la ${sysroot}/ardos/lib
      exit 1
    fi

    # Verify the dynamic linker has no nix store paths.
    ld="${sysroot}/ardos/lib/${ldName}"
    if [ -f "$ld" ] && strings "$ld" | grep -q '/nix/store/'; then
      echo "FAIL: dynamic linker contains /nix/store paths" >&2
      strings "$ld" | grep '/nix/store/' >&2
      exit 1
    fi

    echo "PASS: combined e2e check" >&2
    touch $out
  '';
}
