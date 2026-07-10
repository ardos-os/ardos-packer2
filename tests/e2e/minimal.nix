## Minimal ROM — glibc + libgcc only, no applications, no plugins.
##
## Validates that the core glibc overlay produces a working sysroot
## with no embedded /nix/store paths.
{
  name = "minimal";

  ## No packages beyond what externalMappings provides (glibc + libgcc).
  packages = [];

  ## No glibc plugins — bare system.
  glibcPlugins = [];
}
