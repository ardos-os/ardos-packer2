## The goal of this test is to assess whenever a C program compiled
## using the ardos cross compiler actually runs and links to the right libraries
## even after the build environment and the nix store are gone.

{

  externalMappings = ctx: import ../fixtures/glibcExternalMappings.nix ctx.ap2Instance.crossPkgs;
  build = {lib, ...}@ctx:
  {
    name = "hello";

    includePackages = [
      ctx.pkgs.hello
    ];

    command = "/hello/hello";

    args = [ ];

    expected = {
      stdout = "Hello from hellolibrary!\n2 + 3 = 5\n";

      stderr = "";

      exitCode = 0;
    };
  };
}