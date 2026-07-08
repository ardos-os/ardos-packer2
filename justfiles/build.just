# justfiles/build.just — Build recipes

nix_flags := "--extra-experimental-features 'nix-command flakes'"

# Build the Ardos x86_64 stdenv (cross-compilation toolchain) using nom
stdenv:
    nom build .#packages.x86_64-linux.ardos-bash-x86_64-linux-ardos {{nix_flags}}
