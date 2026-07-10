# Stage 2: Ardos package builder

`lib/builder` contains the per-package build abstraction used after the Ardos
cross toolchain exists.

## Public API

`default.nix` exposes:

- `rustScript`: compiles small Rust helper programs into host executables.
- `mkArdosDerivation`: wraps `crossPkgs.stdenv.mkDerivation` for packages that
  must install into the Ardos runtime layout.
- `mkRuntimeTree`: materialises a package's declared runtime layout as a symlink
  tree, useful for inspection and later image assembly.

## Runtime layout model

Every Ardos package declares where its files will live in the final ROM. The
preferred input is `runtimeLayoutScript`, a bash snippet run with:

- `$out`: the package output in `/nix/store`.
- `$stage`: an empty temporary directory representing the future Ardos root.

The script creates symlinks under `$stage` that point back to files in `$out`.
After installation, `mkArdosDerivation` walks `$stage` and writes
`$out/nix-support/ardos-layout` entries in this form:

```text
relative/source/in/out -> /absolute/ardos/runtime/path
```

That metadata is the single source of truth for downstream link steps, shebang
translation, runtime-tree generation, and ROM assembly. Consumers should not
hard-code global paths such as `/usr/lib` or `/ardos/lib` unless those paths are
provided by dependency layout metadata.

## Build-time flow

1. The target `stdenv` from `lib/toolchain` injects the setup hook from
   `setup/`.
1. Setup tools collect declared layouts from the current package and its visible
   dependencies into `ARDOS_RUNTIME_MAP`.
1. The linker hook in `hooks/` translates Nix-store RPATH and dynamic-linker
   arguments to the final Ardos runtime paths.
1. `postInstall` records the current package's own layout metadata.

This separation keeps build isolation intact: compilers see declared Nix-store
inputs during the build, while produced binaries reference only Ardos runtime
paths.
