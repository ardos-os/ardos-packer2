[
  {
    cpu = "x86_64";
    llvmTarget = "X86";
    rust.rustcTargetSpec = "x86_64-ardos-linux-gnu";
  }
  {
    cpu = "aarch64";
    llvmTarget = "AArch64";
    rust.rustcTargetSpec = "aarch64-ardos-linux-gnu";
  }
  {
    cpu = "riscv64";
    llvmTarget = "RISCV";
    rust.rustcTargetSpec = "riscv64gc-ardos-linux-gnu";
    enableDevShell = false;
  }
]
