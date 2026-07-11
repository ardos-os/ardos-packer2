## Tests that the glibc-test binary can run inside a proot chroot,
## linking against libc and exercising basic libc functions (locale, uid).
##
## Uses --no-nss to skip NSS resolution tests because Nix's sandbox
## bind-mounts /etc/passwd and /etc/group, which proot cannot override.
## NSS correctness is validated by the e2e-nss-plugins test.

{
  externalMappings = ctx: import ../fixtures/glibcExternalMappings.nix ctx.ap2Instance.crossPkgs;

  build = {lib, ...}@ctx: {
    name = "glibc-test-run";

    includePackages = [
      ctx.pkgs.glibcTest
    ];

    command = "/glibc-test/glibc-test";

    args = [ "--no-nss" ];

    expected = {
      stdout = ''
        getuid OK
        setlocale OK
        localeconv OK

        3/3 tests passed
      '';

      stderr = "";

      exitCode = 0;
    };
  };
}
