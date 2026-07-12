let
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
      vendor = "ardos";
      kernel = "linux";
      abi = "gnu";
      isLinux = true;
      libc = "glibc";
      isArdos = true;
      ardosTriple = "${cpu}-${vendor}-${kernel}-${abi}";
      config = ardosTriple;
      linuxTriple = "${cpu}-${kernel}";
    };
  };
in
  builtins.listToAttrs (map mkArdosPlatform supportedCpus)
