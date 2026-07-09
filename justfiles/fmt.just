# justfiles/fmt.just — Format recipes
root := justfile_directory()
# Format all Nix files in the repository using alejandra
nix:
    alejandra "{{root}}"
default:
    alejandra "{{root}}"
