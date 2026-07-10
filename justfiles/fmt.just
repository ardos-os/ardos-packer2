# justfiles/fmt.just — Format recipes
root := justfile_directory()
# Format all Nix files in the repository using alejandra
nix:
    nix run "nixpkgs#alejandra" -- "{{root}}"

md:
    find "{{root}}" -name '*.md' -print0 | tee >(tr '\0' '\n' | wc -l | xargs printf 'Formatting %d files\n' >&2) | xargs -0 -r nix run "nixpkgs#mdformat" --
sh:
    find "{{root}}" \( -name '*.sh' -o -name '*.bash' \) -print0 | tee >(tr '\0' '\n' | wc -l | xargs printf 'Formatting %d files\n' >&2) | xargs -0 -r nix run "nixpkgs#shfmt" -- -w

rs:
    find "{{root}}" -name '*.rs' -print0 | tee >(tr '\0' '\n' | wc -l | xargs printf 'Formatting %d files\n' >&2) | xargs -0 -r nix run "nixpkgs#rustfmt" --

alias rust := rs
alias shell := sh
alias script := sh
alias markdown := md