# Stage 2: Ardos package builder

`lib/builder` contains the per-package build abstraction used after the Ardos
cross toolchain exists.

## Public API

`default.nix` exposes:

- `rustScript`: compiles small Rust helper programs into host executables.
- `mkArdosDerivation`: wraps `crossPkgs.stdenv.mkDerivation` for packages that
  must install into the Ardos runtime layout.
- `wrapDerivation`: turns an existing derivation into an Ardos derivation by
  attaching runtime layout metadata.

## Runtime layout model

Every Ardos package declares where its files will live in the final ROM via
`runtimeLayout`: a list of `{ source, target }` entries where `source` is
relative to `$out` and `target` is an absolute Ardos path.

```nix
runtimeLayout = [
  { source = "lib/"; target = "/pkg/lib/"; }       # folder mapping
  { source = "bin/tool"; target = "/pkg/bin/tool"; } # file mapping
];
```

Sources ending with `/` are **folder mappings** — all files inside are
automatically mapped, preserving subdirectory structure. The ld translator
expands folder mappings on-the-fly via longest-prefix matching at link time,
and the sysroot expands them at assembly time.

The layout entries are written directly to `$out/nix-support/ardos-layout`
without an intermediate symlink tree. This file is the single source of truth
consumed by the linker wrapper, downstream packages, and the ROM generator.

When multiple entries target the same path, the **last entry wins**.

## Build-time flow

1. The target `stdenv` from `lib/toolchain` injects the setup hook from
   `setup/`.
1. Setup tools collect declared layouts from the current package and its visible
   dependencies into `ARDOS_RUNTIME_MAP`. The current package's own layout is
   passed via `ARDOS_CURRENT_PACKAGE_LAYOUT` so folder mappings are available
   before build artifacts exist (enabling self-dependency).
1. The linker hook in `hooks/` translates Nix-store RPATH and dynamic-linker
   arguments to the final Ardos runtime paths using longest-prefix matching.
1. `postInstall` writes the current package's layout metadata directly to
   `ardos-layout`.

This separation keeps build isolation intact: compilers see declared Nix-store
inputs during the build, while produced binaries reference only Ardos runtime
paths.
