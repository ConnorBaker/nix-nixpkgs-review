# What reports don't evaluate (see mkNestedReport.nix's `skip`): an attribute set nested like the report, with `true` for
# each attribute path to skip, and so everything below it. Paths that don't exist (e.g. on another branch) are ignored.
# The same test reachable through several attribute paths (e.g. `bashNonInteractive` and `runtimeShellPackage`, or
# `python312Packages` and `python313Packages`) needs an entry for each.
#
# Most entries are tests whose evaluation fails in a way `tryEval` can't catch, which would fail the whole report. To
# find more, run `nix run .#find-skips -- --nix <Determinate Nix> <nixpkgs>` (see README.md). These were found for
# nixpkgs 16a0bed90bd8 (the flake's `nixpkgs-pre`), x86_64-linux, with CUDA.
{
  # Each of these ~1,000 packages is a Home Assistant component's tests, and lists all of them in its `passthru.tests`,
  # as does `home-assistant`: with tests, they made the report 12x larger. Each is still recorded once, as
  # `home-assistant.passthru.tests.components.<component>`.
  home-assistant-component-tests = true;

  # function 'anonymous lambda' called with unexpected argument 'passthru' (pkgs/build-support/fetchurl/boot.nix)
  bashNonInteractive.passthru.tests.withChecks = true;
  runtimeShellPackage.passthru.tests.withChecks = true;

  # attribute 'cassandra_4' missing
  cassandra.passthru.tests.nixos = true;
  cassandra_4.passthru.tests.nixos = true;

  # callPackageWith: Function called without required argument "runCommandNoCC" (aborts)
  doctoc.passthru.tests.generates-valid-markdown = true;
  hare.passthru.tests.crossCompilation = true;
  hare.passthru.tests.mimeModule = true;

  # attribute 'docuseal-postgresql' missing
  docuseal.passthru.tests.docuseal-postgresql = true;

  # function 'anonymous lambda' called with unexpected argument 'libgit2'
  libgit2.passthru.tests.gitstatus = true;

  # callPackageWith: Function called without required argument "invalidateFetcherByDrvHash" (aborts)
  nixpkgs-manual.passthru.tests.manpage-urls = true;

  # attribute 'longDescription' missing
  nuspell.passthru.tests.wrapper = true;

  # undefined variable 'sphinx_rtd_theme'
  open62541.passthru.tests.open62541Full = true;
  open62541.passthru.tests.open62541Full-mbedtls = true;
  open62541.passthru.tests.open62541Full-openssl = true;

  # cannot coerce a set to a string: { }
  pypy.passthru.tests.editable-script = true;
  pypy2.passthru.tests.editable-script = true;
  pypy27.passthru.tests.editable-script = true;

  # path '/nix/store/…-source.drv' is not valid: needs a store, which reports don't have
  python312Packages.pyopengltk.passthru.tests.cube = true;
  python312Packages.raylib-python-cffi.passthru.tests.basic_shapes = true;
  python312Packages.raylib-python-cffi.passthru.tests.cffi_binding = true;
  python313Packages.pyopengltk.passthru.tests.cube = true;
  python313Packages.raylib-python-cffi.passthru.tests.basic_shapes = true;
  python313Packages.raylib-python-cffi.passthru.tests.cffi_binding = true;

  # attribute 'homepage' missing
  python312Packages.textx.passthru.tests.textxTests = true;
  python313Packages.textx.passthru.tests.textxTests = true;

  # attribute 'grammarName' missing
  vimPlugins.nvim-treesitter.passthru.tests.no-queries-for-official-grammars = true;
}
