# Run the early-init binary to get the exports and function definitions
eval "$(@ardosEarlyOut@)"

# Define wrapper functions for the other three binaries
ardosGenerateDefaultLayout() {
  "@ardosGenerateDefaultLayoutOut@" generate-layout
}
ardosPopulateMap() {
  "@ardosPopulateMapOut@" populate-map
}
ardosTranslateShebangs() {
  "@ardosTranslateShebangsOut@" translate-shebangs
}

# Hook them into the appropriate stages
preFixupHooks+=(ardosGenerateDefaultLayout)
preConfigureHooks+=(ardosPopulateMap)
postFixupHooks+=(ardosTranslateShebangs)
