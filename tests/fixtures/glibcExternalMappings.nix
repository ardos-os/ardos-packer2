# glibcExternalMappings.nix — external mappings for glibc + libgcc.
#
# Maps shared libraries from glibc and libgcc into the ROM at /ardos/lib.
# The overlay installs glibc to $out/lib (inst_* overrides redirect the
# install destinations), so glibc's lib directory is always at ${glibc}/lib
# regardless of runtimePrefix.
crossPkgs: let
  libgcc = crossPkgs.gcc.cc.libgcc;
  glibc = crossPkgs.glibc;
in [
  {
    drv = glibc;
    runtimeLayoutScript = ''
      for so in ${glibc}/lib/*.so*; do
        [ -e "$so" ] || continue
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
]
