{lib}: let
  supportedCpus = import ./supportedCpus.nix;
  mkArdosPlatform = {
    cpu,
    llvmTarget,
    rust ? {},
    enableDevShell ? true,
  }: {
    name = cpu;
    value = rec {
      inherit cpu llvmTarget rust enableDevShell;
      kernel = "linux";
      abi = "ardos";
      isLinux = true;
      libc = "glibc";
      isArdos = true;
      ardosTriple = "${cpu}-${kernel}-${abi}";
      config = ardosTriple;
      linuxTriple = "${cpu}-${kernel}";
    };
  };
in
  lib.listToAttrs (map mkArdosPlatform supportedCpus)
