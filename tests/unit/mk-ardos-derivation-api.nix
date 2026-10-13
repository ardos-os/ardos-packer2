## Checks the legacy attribute-set form and the stdenv-style finalAttrs form.
ctx: let
  legacy = ctx.ap2Instance.mkArdosDerivation {
    pname = "legacy-api-test";
    version = "1";
    runtimeLayout = [
      {
        source = "bin/legacy";
        target = "/legacy";
      }
    ];
  };

  functionForm = ctx.ap2Instance.mkArdosDerivation (finalAttrs: {
    pname = "function-api-test";
    version = finalAttrs.pname;
    runtimeLayout = [
      {
        source = "bin/function";
        target = "/function";
      }
    ];
  });

  legacyLayout = builtins.head legacy.passthru.ardos.runtimeLayout;
  functionLayout = builtins.head functionForm.passthru.ardos.runtimeLayout;
in {
  name = "mk-ardos-derivation-api";

  script = ''
    test "${legacy.pname}" = legacy-api-test
    test "${legacyLayout.source}" = bin/legacy
    test "${legacyLayout.target}" = /legacy

    test "${functionForm.pname}" = function-api-test
    test "${functionForm.version}" = function-api-test
    test "${functionLayout.source}" = bin/function
    test "${functionLayout.target}" = /function

    touch "$out"
  '';
}
