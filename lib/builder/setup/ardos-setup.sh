# Run the early-init binary to get the exports and function definitions
eval "$(@ardosEarlyOut@)"

# Define wrapper functions for the other three binaries
ardosGenerateDefaultLayout() {
  "@ardosGenerateDefaultLayoutOut@" generate-layout
}
ardosPopulateMap() {
  if [[ -n "${ARDOS_RUNTIME_MAP_POPULATED:-}" ]]; then
    return 0
  fi
  export ARDOS_RUNTIME_MAP_POPULATED=1
  "@ardosPopulateMapOut@" populate-map
}
ardosTranslateShebangs() {
  "@ardosTranslateShebangsOut@" translate-shebangs
}

# Hook them into the appropriate stages
preFixupHooks+=(ardosGenerateDefaultLayout)
preConfigureHooks+=(ardosPopulateMap)
preBuildHooks+=(ardosPopulateMap)
postFixupHooks+=(ardosTranslateShebangs)
