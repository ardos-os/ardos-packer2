## Minimal ROM — empty sysroot, no applications, no plugins.
##
## Validates that the build pipeline produces a valid (empty) ROM
## end-to-end with an empty closure.
{
  name = "minimal";

  ## No packages — empty closure, empty sysroot.
  packages = [];

  ## No glibc plugins.
  glibcPlugins = [];
}
