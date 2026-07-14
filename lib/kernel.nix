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
  enableCommonConfig ? true,
  ignoreConfigErrors ? false,
}:
let
  kernel = buildPkgs.buildLinux {
    inherit src version kernelPatches extraMeta enableCommonConfig ignoreConfigErrors;

    buildPackages = buildPkgs.pkgsBuildBuild;

    defconfig = "defconfig";
    structuredExtraConfig = structuredExtraConfig;
  };
in
kernel // {
  kernelImage = "${kernel}/bzImage";
}
