# rustScript — Helper to compile inline Rust code into executable host build tools.
# Uses the host's rustc for fast compilation.
{buildPkgs}: name: src: let
  crateName = builtins.replaceStrings ["-"] ["_"] name;

  isInline = builtins.isString src;
in
  buildPkgs.runCommand name {
    nativeBuildInputs = [buildPkgs.rustc buildPkgs.stdenv.cc];
    inherit src;
    passAsFile =
      if isInline
      then ["src"]
      else [];
  } ''
    mkdir -p $out/bin

    # Determinar dinamicamente a origem do código Rust
    if [ "${
      if isInline
      then "1"
      else "0"
    }" = "1" ]; then
      # Caso 1: Código inline via passAsFile
      TARGET_SOURCE="$srcPath"
    elif [ -d "$src" ]; then
      # Caso 2: O src é uma diretoria, procuramos o main.rs lá dentro
      if [ -f "$src/main.rs" ]; then
        TARGET_SOURCE="$src/main.rs"
      else
        echo "[rustScript Error] Directory provided but no main.rs found in $src" >&2
        exit 1
      fi
    elif [ -f "$src" ]; then
      # Caso 3: O src é um ficheiro .rs direto
      TARGET_SOURCE="$src"
    else
      echo "[rustScript Error] Invalid source type for $src" >&2
      exit 1
    fi

    # Compilação cirúrgica com o target correto
    rustc "$TARGET_SOURCE" -o "$out/bin/${name}" --crate-name "${crateName}" --edition 2024 -C opt-level=3
  ''
