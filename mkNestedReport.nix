{
  # What the report records for each derivation:
  # - "packages": its output path, `{ fingerprint = <output path>; }`;
  # - "tests": its `passthru.tests`, `{ passthru.tests = { <name> = { fingerprint = <output path>; }; ... }; }` (null if
  #   it has none). Its own output path isn't computed. mkDiff.nix unions a tests report with the packages report for the
  #   same Nixpkgs, so that the tests are diffed along with the packages.
  # They're separate reports because a report never collects garbage: one with both took ~63% more memory than one with
  # packages only, while each of the two separately took about as much as the latter (see README.md). Also, a test
  # failing to evaluate in a way that can't be caught then only fails the tests report.
  kind ? "packages",
  # How deep to recurse into attribute sets within `passthru.tests`: with 3, `passthru.tests.a.b.c` is recorded, but not
  # anything below `passthru.tests.a.b.c` if it is an attribute set rather than a derivation. Nothing marks which
  # attribute sets in `passthru.tests` are meant to be recursed into (`recurseForDerivations` is rarely set there), and
  # nothing stops one from being a whole package set, so the walk must be bounded.
  testsMaxDepth ? 3,
  # What not to evaluate, nested like the report, with `true` for each attribute path to skip (and so everything below
  # it), e.g. { bashNonInteractive.passthru.tests.withChecks = true; }. Skipped attributes are null in the report. See
  # ./skip.nix.
  skip ? { },
}:
assert builtins.elem kind [
  "packages"
  "tests"
];
let
  inherit (builtins)
    deepSeq
    isAttrs
    isString
    mapAttrs
    tryEval
    ;

  tryEval' = expr: (tryEval (deepSeq expr expr)).value;

  # NOTE: This is an implementation detail; used here to avoid importing `lib`.
  isDerivation = value: value.type or null == "derivation";

  # The part of `skip` below an attribute name; `true` (everything is skipped) stays `true`. The report's walk descends
  # `skip` alongside the values it walks, so checking whether a value is skipped costs one attribute lookup.
  descend = skipTree: name: if skipTree == true then true else skipTree.${name} or { };

  /**
    Creates a report from a value: the output path for a derivation (for a tests report, just "derivation", since its
    output path isn't recorded), `true` if the value should be recursed into, and `false` otherwise.

    The (default) output path is all we record for a derivation: whether it changed is enough to know whether what the
    derivation builds changed, and the attribute path is given by where it is in the (nested) result. Keeping the result
    small keeps printing it cheap.

    It's the output path rather than the derivation path because derivation paths also change when only how a source is
    fetched changes (e.g., a fixed-output derivation's URL or fetcher). Output paths depend on fixed-output derivations
    only through their content hashes, so such a change makes every dependent's derivation path change but none of
    their output paths. The outputs of an input-addressed derivation all change together, so the default one is enough.

    NOTE: Return value is designed to be the same whether evaluated directly or via `(tryEval (deepSeq ...)).value`.
  */
  unsafeMkValueReport =
    value:
    # 1. value is an attribute set
    if isAttrs value then
      # 1a. value is a derivation, we want to return the report
      if isDerivation value then
        (if kind == "packages" then value.outPath else "derivation")
      # 1b. value is an attribute set but not a derivation, so either we want to recurse into it or we don't
      else
        value.recurseForDerivations or false
    # 2. value is not an attribute set, we want to ignore it, return false
    else
      false;

  /**
    Whether a derivation is a NixOS test (e.g. `nixosTests.akkoma`, which is in `akkoma.passthru.tests`), going by the
    attributes nixos/lib/testing gives it.

    NixOS tests are skipped: their output path depends on the system of each of their nodes, so computing it evaluates a
    NixOS system per node (a report took ~3x the memory, before failing), and that evaluation reads from the store
    (e.g. `closure-info`), which a report doesn't have. The error that gives (`path ... is not valid`) isn't one tryEval
    catches, so a single NixOS test would fail the whole report.
  */
  isNixOSTest = value: value ? driver && value ? nodes;

  # Like unsafeMkValueReport, for a value within `passthru.tests` at the given depth (`passthru.tests` itself is at depth
  # 0): any attribute set is recursed into, up to testsMaxDepth.
  unsafeMkTestReport =
    depth: value:
    if isAttrs value then
      if isDerivation value then
        if isNixOSTest value then false else value.outPath
      else
        depth < testsMaxDepth
    else
      false;

  /**
    The report for a value within `passthru.tests`: `{ fingerprint = <output path>; }` for a derivation, an attribute
    set of reports for an attribute set, and null otherwise (including when it fails to evaluate or is skipped).

    A test is only ever recorded by its output path: its own `passthru.tests` (or anything else in its `passthru`) isn't
    looked at. Tests may be overrides of the package itself (e.g., `tinygrad.passthru.tests.withCuda`), whose tests are
    more overrides, and so on.

    Every value is forced within `tryEval`, so a test that throws or fails an assertion costs only itself. Those are the
    only errors `tryEval` catches, though: any other (e.g. calling a function with an argument it doesn't take, infinite
    recursion, a stack overflow) fails the whole report. Nixpkgs' CI evaluates packages, but not their tests, so tests
    with such errors aren't rare; they need to be skipped (see ./skip.nix).
  */
  mkTestReport =
    depth: skipTree: value:
    let
      maybeReport = tryEval' (unsafeMkTestReport depth value);
    in
    if skipTree == true then
      null
    else if isString maybeReport then
      { fingerprint = maybeReport; }
    else if maybeReport then
      mapAttrs (name: mkTestReport (depth + 1) (descend skipTree name)) value
    else
      null;

  # A derivation's report in a tests report: its `passthru.tests`, or null if it has none (or they're all skipped).
  mkPackageTestsReport =
    skipTree: value:
    let
      # `or` only catches missing attributes: should `passthru` or `passthru.tests` throw, it's caught in mkTestReport.
      tests = mkTestReport 0 (descend (descend skipTree "passthru") "tests") (
        value.passthru.tests or null
      );
    in
    if tests == null then null else { passthru.tests = tests; };

  /**
    Creates a report for an attribute set (e.g. Nixpkgs), nested like it. Each derivation is
    `{ fingerprint = <output path>; }` (or, for a tests report, `{ passthru.tests = ...; }`). An attribute set with
    `recurseForDerivations` is recursed into. Anything else, anything that fails to evaluate, and anything in `skip` is
    null.

    Derivations are attribute sets rather than strings so they can have children: the path to a test in the union of a
    packages and a tests report is its attribute path in Nixpkgs (e.g. `hello.passthru.tests.version`). An attribute set
    is a derivation exactly when it has a string `fingerprint`: the attributes of any other attribute set in the report
    are attribute sets or null.

    The value is the output path, which is a fingerprint of what the derivation builds: two are equal exactly when the
    derivations build the same thing. With Nix's `fingerprint-derivations` setting (see ./patches/nix), it is a cheaper
    fingerprint that isn't a real output path, but is equal exactly when the real output paths are. Either way, it's only
    for comparing with reports made the same way. (It can't be called `outPath`: Nix prints an attribute set with an
    `outPath` as just that string.)
  */
  mkNestedReport =
    skipTree:
    mapAttrs (
      name: value:
      let
        skipTree' = descend skipTree name;
        maybeReport = tryEval' (unsafeMkValueReport value);
      in
      # Case where the attribute is skipped (checked first, so its value is never forced)
      if skipTree' == true then
        null
      # Case where maybeReport is a report
      else if isString maybeReport then
        (
          if kind == "packages" then { fingerprint = maybeReport; } else mkPackageTestsReport skipTree' value
        )
      # Case where maybeReport is true, recurse
      else if maybeReport then
        mkNestedReport skipTree' value
      # Case where maybeReport is false, ignore
      else
        null
    );
in
mkNestedReport skip
