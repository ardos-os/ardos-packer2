{
  buildPkgs,
  lib,
  crossPkgs,
}:
{
  src,
  version,
  structuredExtraConfig ? {},
  kernelPatches ? [],
  extraMeta ? {},
}:
let
  kernel = buildPkgs.buildLinux {
    inherit src version kernelPatches extraMeta;

    stdenv = crossPkgs.stdenv;
    buildPackages = buildPkgs.pkgsBuildBuild;

    defconfig = "defconfig";
    structuredExtraConfig = structuredExtraConfig;
    ignoreConfigErrors = false;
  };
in
kernel // {
  kernelImage = "${kernel}/bzImage";
}
