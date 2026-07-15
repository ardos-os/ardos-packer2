# glibcExternalMappings.nix — external mappings for glibc + libgcc.
#
# Maps shared libraries from glibc and libgcc into the ROM at /ardos/lib.
# The overlay installs glibc to $out/lib (inst_* overrides redirect the
# install destinations), so glibc's lib directory is always at ${glibc}/lib
# regardless of runtimePrefix.
#
# NSS modules (libnss_*) are excluded by the sysroot's GNU ld script
# filtering and glibcPlugins mechanism.
crossPkgs: let
  inherit (crossPkgs) glibc;
  inherit (crossPkgs.stdenv.cc.cc) libgcc lib;
  nssFiles = (import ../../lib/plugins/nss-files.nix {
    glibc = crossPkgs.glibc;
    runCommand = crossPkgs.runCommand;
  });
in [
  {
    drv = glibc;
    runtimeLayout = [{ source = "lib/"; target = "/ardos/lib/"; }];
  }
  {
    drv = nssFiles;
    runtimeLayout = [{ source = "lib/"; target = "/ardos/lib/"; }];
  }
  {
    drv = libgcc;
    runtimeLayout = [{ source = "lib/"; target = "/ardos/lib/"; }];
  }
  {
    drv = lib;
    runtimeLayout = [{ source = "${crossPkgs.stdenv.hostPlatform.config}/lib/"; target = "/ardos/lib/"; }];
  }
]
