# justfiles/fmt.just — Format recipes
root := justfile_directory()
# Format all Nix files in the repository using alejandra
nix:
    nix run "nixpkgs#alejandra" -- "{{root}}"

# Format all Markdown and MDX files with remark (via the docs bun project)
md:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{root}}/docs"
    bun run remark ".." --rc-path remark.config.mjs --output --ext md --ext mdx
sh:
    find "{{root}}" \( -name '*.sh' -o -name '*.bash' \) -print0 | tee >(tr '\0' '\n' | wc -l | xargs printf 'Formatting %d files\n' >&2) | xargs -0 -r nix run "nixpkgs#shfmt" -- -w

rs:
    find "{{root}}" -name '*.rs' -print0 | tee >(tr '\0' '\n' | wc -l | xargs printf 'Formatting %d files\n' >&2) | xargs -0 -r nix run "nixpkgs#rustfmt" --

alias rust := rs
alias shell := sh
alias script := sh
alias markdown := md