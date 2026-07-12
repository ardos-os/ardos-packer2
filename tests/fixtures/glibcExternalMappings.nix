# glibcExternalMappings.nix — external mappings for glibc + libgcc.
#
# Maps shared libraries from glibc and libgcc into the ROM at /ardos/lib.
# The overlay installs glibc to $out/lib (inst_* overrides redirect the
# install destinations), so glibc's lib directory is always at ${glibc}/lib
# regardless of runtimePrefix.
#
# NSS modules (libnss_*) are excluded from the core glibc mapping.
# They are provided declaratively via glibcPlugins instead.
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
    runtimeLayoutScript = ''
      for so in ${glibc}/lib/*.so*; do
        [ -e "$so" ] || continue
        case "$(basename "$so")" in libnss_*) continue ;; esac
        # GNU ld scripts (e.g. libc.so, libm.so GROUP scripts) are linker
        # inputs only and must never be materialized into the runtime ROM.
        case "$(head -c 4096 "$so" 2>/dev/null)" in "/* GNU ld script"*) continue ;; esac
        mkdir -p "$stage/ardos/lib"
        ln -sfn "$so" "$stage/ardos/lib/$(basename "$so")"
      done
    '';
  }
  {
    drv = nssFiles;
    runtimeLayoutScript = ''
      for so in ${nssFiles}/lib/*.so*; do
        [ -e "$so" ] || continue
        case "$(head -c 4096 "$so" 2>/dev/null)" in "/* GNU ld script"*) continue ;; esac
        mkdir -p "$stage/ardos/lib"
        ln -sfn "$so" "$stage/ardos/lib/$(basename "$so")"
      done
    '';
  }
  {
    drv = libgcc;
    runtimeLayoutScript = ''
      for so in "$out"/lib/*.so*; do
        [ -e "$so" ] || continue
        case "$(head -c 4096 "$so" 2>/dev/null)" in "/* GNU ld script"*) continue ;; esac
        mkdir -p "$stage/ardos/lib"
        ln -sfn "$so" "$stage/ardos/lib/$(basename "$so")"
      done
    '';
  }
  {
    drv = lib;
    runtimeLayoutScript = ''
      for so in "$out"/${crossPkgs.stdenv.hostPlatform.config}/lib/*.so*; do
        [ -e "$so" ] || continue
        case "$(head -c 4096 "$so" 2>/dev/null)" in "/* GNU ld script"*) continue ;; esac
        mkdir -p "$stage/ardos/lib"
        ln -sfn "$so" "$stage/ardos/lib/$(basename "$so")"
      done
    '';
  }
]
