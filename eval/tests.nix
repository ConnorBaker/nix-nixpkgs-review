# The tests of a tree, as two trees for eval-jobs, each with a test's attribute path as its path in the tree:
# - `tests`: each derivation's `passthru.tests` (e.g. `hello.passthru.tests.version`). Only `passthru.tests` is looked
#   at: the rest of `passthru` is full of dependencies and whole package sets. A test's own `passthru.tests` isn't
#   either: tests are often overrides of the package, whose tests are more overrides.
# - `gpuChecks`: the GPU checks of Nixpkgs' CUDA testing convention (doc/languages-frameworks/cuda.section.md): a
#   derivation's `passthru.gpuCheck` (e.g. `cudaPackages.saxpy.passthru.gpuCheck`), and the `gpuCheck` of each of its
#   tests (e.g. `blender.passthru.tests.tester-cudaAvailable.gpuCheck`, as `writeGpuTestPython` makes them). A test's
#   `gpuCheck` is in a tree of its own because the test is a job too, and eval-jobs doesn't recurse into derivations.
{
  # Whether to recurse into every attribute set of the tree, not just those with `recurseForDerivations`.
  forceRecurse,
  # More of the tree not to walk, as `skip` below (and added to it), e.g. `{ dotnetCorePackages = true; }`.
  skipTests,
}:
let
  inherit (builtins) isAttrs mapAttrs;

  # How deep to recurse into attribute sets within `passthru.tests`: with 3, `passthru.tests.a.b.c` is a job, but nothing
  # below it. Nothing marks which attribute sets in `passthru.tests` are meant to be recursed into, and nothing stops one
  # from being a whole package set, so the walk must be bounded.
  maxDepth = 3;

  # Two `skip` trees as one: a path either skips is skipped.
  mergeSkip =
    a: b:
    if a == true || b == true then
      true
    else
      a // mapAttrs (name: value: if a ? ${name} then mergeSkip a.${name} value else value) b;

  # What isn't walked, nested like the tree, with `true` for each attribute path to skip and everything below it. The
  # same tests reachable through several attribute paths need an entry for each. `skipTests` is added to it.
  skip = mergeSkip skipTests {
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

  # A derivation that is a test, or null.
  test = value: if isDerivation value && !isNixOSTest value then value else null;

  # An attribute set of the tests (as `test`) that aren't null, or null if there are none.
  testsOf =
    attrs:
    let
      present = builtins.removeAttrs attrs (
        builtins.filter (name: attrs.${name} == null) (builtins.attrNames attrs)
      );
    in
    if present == { } then null else recurse present;

  recurse = attrs: attrs // { recurseForDerivations = true; };

  # The part of `skip` below an attribute name; `true` (everything is skipped) stays `true`.
  descend = skipTree: name: if skipTree == true then true else skipTree.${name} or { };

  # mapAttrs, with what is skipped below each name.
  mapSkip = skipTree: f: mapAttrs (name: f (descend skipTree name));

  # A value within `passthru.tests` at the given depth (`passthru.tests` itself is at depth 0), with `leaf` applied to
  # each test, a derivation.
  testsTree =
    leaf: depth: skipTree: value:
    if skipTree == true || !isAttrs value then
      null
    else if isDerivation value then
      (if isNixOSTest value then null else leaf value)
    else if depth < maxDepth then
      recurse (mapSkip skipTree (testsTree leaf (depth + 1)) value)
    else
      null;

  # A value of the tree: a derivation's `passthru`, with what `ofPassthru` takes from it, or an attribute set's, recursed
  # into. `passthru` is an attribute of its own (not checked for null here), so an error in it is reported at
  # `<package>.passthru`, rather than at the package's own attribute path, where the diff would take the package's job
  # for it.
  packages =
    ofPassthru: skipTree: value:
    if skipTree == true || !isAttrs value then
      null
    else if isDerivation value then
      recurse { passthru = ofPassthru (descend skipTree "passthru") (value.passthru or { }); }
    else if forceRecurse || value.recurseForDerivations or false then
      recurse (mapSkip skipTree (packages ofPassthru) value)
    else
      null;

  testsOfPassthru =
    skipTree: passthru:
    if passthru ? tests then
      recurse { tests = testsTree (value: value) 0 (descend skipTree "tests") passthru.tests; }
    else
      null;

  gpuChecksOfPassthru =
    skipTree: passthru:
    testsOf {
      gpuCheck = if descend skipTree "gpuCheck" == true then null else test (passthru.gpuCheck or null);
      tests =
        if passthru ? tests then
          testsTree (
            value: testsOf { gpuCheck = test (value.gpuCheck or null); }
          ) 0 (descend skipTree "tests") passthru.tests
        else
          null;
    };
in
root: {
  tests = recurse (mapSkip skip (packages testsOfPassthru) root);
  gpuChecks = recurse (mapSkip skip (packages gpuChecksOfPassthru) root);
}
