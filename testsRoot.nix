# The tests of a tree, as a tree for eval-jobs (see mkReport.nix): each derivation becomes
# `{ passthru.tests = <its tests>; }`, and the attribute sets in its tests are recursed into up to testsMaxDepth, so the
# attribute path of each test is its path in the tree (e.g. `hello.passthru.tests.version`). Only `passthru.tests` is
# looked at: the rest of `passthru` is full of dependencies and whole package sets. A test's own `passthru.tests` isn't
# looked at either: tests are often overrides of the package, whose tests are more overrides. eval-jobs evaluates each
# node on its own, so any error, not just those `tryEval` catches, costs only that node.
{
  # How deep to recurse into attribute sets within `passthru.tests`: with 3, `passthru.tests.a.b.c` is a job, but not
  # anything below `passthru.tests.a.b.c` if it is an attribute set rather than a derivation. Nothing marks which
  # attribute sets in `passthru.tests` are meant to be recursed into (`recurseForDerivations` is rarely set there), and
  # nothing stops one from being a whole package set, so the walk must be bounded.
  testsMaxDepth ? 3,
  # What not to walk, nested like the tree, with `true` for each attribute path to skip (see ./skip.nix).
  skip ? { },
  # Whether to recurse into every attribute set of the tree, not just those with `recurseForDerivations`.
  forceRecurse ? false,
}:
let
  inherit (builtins) isAttrs mapAttrs;

  # NOTE: This is an implementation detail; used here to avoid importing `lib`.
  isDerivation = value: value.type or null == "derivation";

  # Whether a derivation is a NixOS test (e.g. `nixosTests.akkoma`, which is in `akkoma.passthru.tests`), going by the
  # attributes nixos/lib/testing gives it. NixOS tests are skipped: their output path depends on the system of each of
  # their nodes, so computing it evaluates a NixOS system per node, which takes several times the memory of a report.
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
    else if depth < testsMaxDepth then
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
