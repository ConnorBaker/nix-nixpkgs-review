# What tests reports don't walk (see mkReport.nix's `skip` and testsRoot.nix): an attribute set nested like the tree,
# with `true` for each attribute path to skip, and so everything below it. Paths that don't exist (e.g. on another
# branch) are ignored. The same tests reachable through several attribute paths need an entry for each.
#
# eval-jobs evaluates each attribute on its own, so tests that fail to evaluate don't need skipping: they're errors in
# the report. This is only for what is too big to walk.
{
  # Each of these ~1,200 packages is a Home Assistant component's tests, and lists all of them in its `passthru.tests`,
  # as does `home-assistant`: walking them made 1.4M test jobs instead of 10.6k (Nixpkgs e58dcdca81f2,
  # aarch64-linux). Each is still a test of `home-assistant`, as `home-assistant.passthru.tests.components.<component>`.
  home-assistant-component-tests = true;
  # The same packages, as `pkgs.tests` has them.
  tests.home-assistant-components = true;
}
