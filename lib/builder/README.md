# Stage 2: Ardos package builder

`lib/builder` contains the per-package build abstraction used after the Ardos
cross toolchain exists.

## Public API

`default.nix` exposes:

- `rustScript`: compiles small Rust helper programs into host executables.
- `mkArdosDerivation`: wraps `crossPkgs.stdenv.mkDerivation` for packages that
  must install into the Ardos runtime layout.
- `mkArdosRustPackage`: wraps `crossPkgs.rustPlatform.buildRustPackage` for
  Cargo packages and workspaces while preserving nixpkgs Rust build behavior.
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

## Rust workspaces

`mkArdosRustPackage` is the Rust equivalent of `mkArdosDerivation`. It delegates
compilation to `crossPkgs.rustPlatform.buildRustPackage` unchanged, so large
Cargo workspaces keep nixpkgs' normal crate-vendor, dependency-cache, feature,
and multi-binary behavior. The only Ardos-specific layer is the runtime layout
metadata recorded after install.

For Rust packages, `runtimeLayout` can be a declarative attrset instead of a
script:

```nix
mkArdosRustPackage {
  pname = "workspace-apps";
  version = "1.0.0";
  src = ./.;
  cargoHash = "sha256-...";

  runtimeLayout = {
    binaries = {
      server = "/apps/server/bin/server";
      worker = "/apps/worker/bin/worker";
    };
    libraries = {
      "libworkspace_plugin.so" = "/apps/server/lib/libworkspace_plugin.so";
    };
  };
}
```

`binaries.<name>` points at `$out/bin/<name>`, `libraries.<name>` and
`sharedLibraries.<name>` point at `$out/lib/<name>`, and `files.<relative-path>`
points at any other `$out`-relative file. A flat attrset is also accepted for
advanced cases, for example `{ "bin/server" = "/apps/server/bin/server"; }`.
All of these forms lower to the same generated `runtimeLayoutScript` used by
non-Rust packages.
