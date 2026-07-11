# glibc nss-files plugin — provides NSS passwd/group/shadow resolution
# via /etc files.  This is the standard Linux user/group lookup mechanism.
#
# The .so files are copied from the nixpkgs glibc output (which already
# builds all modules).  The overlay does not change module contents.
#
# Usage (pass as a function to glibcPlugins, like externalMappings):
#   ap2.init {
#     glibcPlugins = crossPkgs: [
#       (import ./lib/plugins/nss-files.nix {
#         glibc = crossPkgs.glibc;
#         runCommand = crossPkgs.runCommand;
#       })
#     ];
#     ...
#   };
{
  glibc,
  runCommand,
}:

runCommand "glibc-nss-files" {} ''
  mkdir -p $out/lib
  for f in "${glibc}"/lib/libnss_files.so*; do
    [ -e "$f" ] || continue
    cp -a "$f" $out/lib/
  done
  if ! ls -1 "$out/lib/"libnss_files.so* >/dev/null 2>&1; then
    echo "error: nss-files plugin found no libnss_files.so in ${glibc}/lib/" >&2
    exit 1
  fi
'' // {
  passthru.glibcPlugin = {
    name = "nss-files";
    nssDatabases = {
      passwd = ["files"];
      group = ["files"];
      shadow = ["files"];
    };
  };
}
