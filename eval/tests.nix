# The tests of a tree, as a tree for eval-jobs: each derivation becomes `{ passthru.tests = <its tests>; }`, so a test's
# attribute path is its path in the tree (e.g. `hello.passthru.tests.version`). Only `passthru.tests` is looked at: the
# rest of `passthru` is full of dependencies and whole package sets. A test's own `passthru.tests` isn't either: tests
# are often overrides of the package, whose tests are more overrides.
{
  # Whether to recurse into every attribute set of the tree, not just those with `recurseForDerivations`.
  forceRecurse,
}:
let
  inherit (builtins) isAttrs mapAttrs;

  # How deep to recurse into attribute sets within `passthru.tests`: with 3, `passthru.tests.a.b.c` is a job, but nothing
  # below it. Nothing marks which attribute sets in `passthru.tests` are meant to be recursed into, and nothing stops one
  # from being a whole package set, so the walk must be bounded.
  maxDepth = 3;

  # What isn't walked, nested like the tree, with `true` for each attribute path to skip and everything below it. The
  # same tests reachable through several attribute paths need an entry for each.
  skip = {
    # Each of these ~1,200 packages is a Home Assistant component's tests, and lists all of them in its
    # `passthru.tests`, as does `home-assistant`: walking them made 1.4M test jobs instead of 10.6k (Nixpkgs
    # e58dcdca81f2, aarch64-linux). Each is still a test of `home-assistant`, as
    # `home-assistant.passthru.tests.components.<component>`.
    home-assistant-component-tests = true;
    # The same packages, as `pkgs.tests` has them.
    tests.home-assistant-components = true;
  };

  isDerivation = value: value.type or null == "derivation";

  # NixOS tests (e.g. `nixosTests.akkoma`, in `akkoma.passthru.tests`) are skipped: their output path depends on the
  # system of each of their nodes, so computing it evaluates a NixOS system per node.
  isNixOSTest = value: value ? driver && value ? nodes;

  recurse = attrs: attrs // { recurseForDerivations = true; };

  # The part of `skip` below an attribute name; `true` (everything is skipped) stays `true`.
  descend = skipTree: name: if skipTree == true then true else skipTree.${name} or { };

  # mapAttrs, with what is skipped below each name.
  mapSkip = skipTree: f: mapAttrs (name: f (descend skipTree name));

  # A value within `passthru.tests` at the given depth (`passthru.tests` itself is at depth 0).
  tests =
    depth: skipTree: value:
    if skipTree == true || !isAttrs value then
      null
    else if isDerivation value then
      (if isNixOSTest value then null else value)
    else if depth < maxDepth then
      recurse (mapSkip skipTree (tests (depth + 1)) value)
    else
      null;

  # A value of the tree: a derivation's tests, or an attribute set's, recursed into.
  packages =
    skipTree: value:
    if skipTree == true || !isAttrs value then
      null
    else if isDerivation value then
      (
        if value ? passthru.tests then
          recurse {
            passthru = recurse {
              tests = tests 0 (descend (descend skipTree "passthru") "tests") value.passthru.tests;
            };
          }
        else
          null
      )
    else if forceRecurse || value.recurseForDerivations or false then
      recurse (mapSkip skipTree packages value)
    else
      null;
in
root: recurse (mapSkip skip packages root)
