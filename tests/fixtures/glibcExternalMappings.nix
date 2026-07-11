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
  inherit (crossPkgs.gcc.cc) libgcc lib;
in [
  {
    drv = glibc;
    runtimeLayoutScript = ''
      for so in ${glibc}/lib/*.so*; do
        [ -e "$so" ] || continue
        case "$(basename "$so")" in libnss_*) continue ;; esac
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
        mkdir -p "$stage/ardos/lib"
        ln -sfn "$so" "$stage/ardos/lib/$(basename "$so")"
      done
    '';
  }
]
