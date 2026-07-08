# rustScript — Helper to compile inline Rust code into executable host build tools.
# Uses the host's rustc for fast compilation.
{buildPkgs}: name: src:
buildPkgs.runCommand name {
  nativeBuildInputs = [buildPkgs.rustc];
  inherit src;
  passAsFile = ["src"];
} ''
  mkdir -p $out/bin
  # Compile single-file Rust program using the modern Edition 2024
  rustc "$srcPath" -o "$out/bin/${name}" --edition 2024 -C opt-level=3
''
