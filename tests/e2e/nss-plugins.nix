## ROM with NSS files plugin — validates plugin system and nsswitch.conf generation.
##
## Builds a sysroot with glibc + libgcc + nss-files plugin.
## Checks that nsswitch.conf is generated correctly and libnss_files.so is present.
{
  name = "nss-plugins";

  ## glibc and libgcc must be in the closure for plugins to be applied.
  packages = crossPkgs: [
    crossPkgs.glibc
    crossPkgs.gcc.cc.libgcc
  ];

  toolchainConfig = {
    glibc = {
      runtimePrefix = "/ardos";
    };
  };


  ## Include the NSS files plugin.
  glibcPlugins = crossPkgs: [
    (import ../../lib/plugins/nss-files.nix {
      glibc = crossPkgs.glibc;
      runCommand = crossPkgs.runCommand;
    })
  ];

  ## Extra validation: the check derivation verifies the ROM contents.
  check = ctx: sysroot: let tree = "${ctx.ap2Instance.buildPkgs.tree}/bin/tree"; in ctx.buildPkgs.runCommand "e2e-nss-plugins-check" {} ''
    # Verify nsswitch.conf was generated.
    if [ ! -f "${sysroot}/etc/nsswitch.conf" ]; then
      echo "FAIL: nsswitch.conf not found in sysroot" >&2
      ${tree} ${sysroot}
      cat ${sysroot}/etc/nsswitch.conf || true
      exit 1
    fi

    # Verify it contains the expected database lines.
    if ! grep -q "^passwd:" "${sysroot}/etc/nsswitch.conf"; then
      echo "FAIL: nsswitch.conf missing passwd: line" >&2
      ${tree} ${sysroot}
      cat ${sysroot}/etc/nsswitch.conf || true
      exit 1
    fi
    if ! grep -q "^group:" "${sysroot}/etc/nsswitch.conf"; then
      echo "FAIL: nsswitch.conf missing group: line" >&2
      ${tree} ${sysroot}
      cat ${sysroot}/etc/nsswitch.conf || true
      exit 1
    fi

    # Verify libnss_files.so is present.
    if [ ! -f "${sysroot}/ardos/lib/libnss_files.so.2" ]; then
      echo "FAIL: libnss_files.so.2 not found in sysroot" >&2
      ${tree} ${sysroot}
      exit 1
    fi

    echo "PASS: nss-plugins e2e check" >&2
    touch $out
  '';
}
