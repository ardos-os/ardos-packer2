# Toolchain patches

Patches in this directory are applied by the Ardos overlay in
`lib/toolchain/default.nix`.

- `binutils-add-ardos.patch` adds Ardos target recognition to cross binutils.
- `llvm-add-ardos-environment.patch` teaches LLVM about the Ardos environment.

Use this directory only for changes that the upstream toolchain must know while
it is being built. Prefer setup hooks or wrapper hooks for behaviour that can be
changed after the toolchain exists, because those avoid large rebuilds and give
better cache reuse.
