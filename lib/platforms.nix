{lib}: let
  supportedCpus = import ./supportedCpus.nix;
  mkArdosPlatform = {
    cpu,
    llvmTarget,
    rust ? {},
    enableDevShell ? true
  }: {
    name = cpu;
    value = {
      inherit cpu llvmTarget rust enableDevShell;
      kernel = "linux";
      abi = "ardos";
      isLinux = true;
      libc = "glibc";
      isArdos = true;
      config = "${cpu}-linux-ardos";
    };
  };
in
  lib.listToAttrs (map mkArdosPlatform supportedCpus)
