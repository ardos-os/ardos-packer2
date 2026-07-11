{buildPkgs}:
{
  sysroot,
  name ? "ardos-rom",
}:
buildPkgs.runCommand "${name}.squashfs" {
  nativeBuildInputs = [
    buildPkgs.squashfsTools
  ];
} ''
  mksquashfs "${sysroot}" "$out" -noappend -all-root -no-progress
''
