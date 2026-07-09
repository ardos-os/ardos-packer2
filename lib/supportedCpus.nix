[
  {
    cpu = "x86_64";
    llvmTarget = "X86";
    rust.rustcTargetSpec = ./rustTargets/x86_64-linux-ardos.json;
  }
  {
    cpu = "aarch64";
    llvmTarget = "AArch64";
    rust.rustcTargetSpec = ./rustTargets/aarch64-linux-ardos.json;
  }
  # {
  #   cpu = "riscv64";
  #   llvmTarget = "RISCV";
  #   rust.rustcTargetSpec = ./rustTargets/riscv64gc-linux-ardos.json;
  # }
]
