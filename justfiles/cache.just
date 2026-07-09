# justfiles/cache.just — Cachix push recipes

nix_flags := "--extra-experimental-features 'nix-command flakes'"
cachix_cache := "ardos-os"

# Build the Ardos x86_64 stdenv and push Ardos-specific paths to Cachix
# (standard Nixpkgs paths are skipped — they are already on cache.nixos.org)
stdenv:
    just build stdenv
    nix path-info {{nix_flags}} --recursive \
        .#packages.x86_64-linux.stdenv-x86_64-linux-ardos \
        | grep "ardos" \
        | cachix push {{cachix_cache}}
