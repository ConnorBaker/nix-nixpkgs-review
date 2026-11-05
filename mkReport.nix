{
  # config
  name,
  # The tree to evaluate: Nixpkgs, or, with `file`, any tree.
  nixpkgs,
  evalSystem,
  withCA,
  withCUDA,
  # Nix file (or directory) whose expression maps { withCA, withCUDA } to the arguments (other than `system`) to import
  # Nixpkgs with; defaults to ./configs and ./overlays.
  nixpkgsArgs ? null,
  # What to evaluate in a tree that isn't Nixpkgs, like nix-eval-jobs' arguments: a Nix file in the tree (relative to
  # its root), which, if it's a function taking an attribute set, is called with the attributes of `args` it takes. With
  # null, the tree is Nixpkgs, imported for `evalSystem` with `nixpkgsArgs`. `args` is passed to the evaluation as JSON,
  # so its values can be anything JSON can hold, or paths (which are passed as store paths).
  file ? null,
  args ? { },
  # An attribute path to select in what `file` (or Nixpkgs) evaluates to, e.g. [ "python3Packages" ].
  attrPath ? [ ],
  # Whether to recurse into every attribute set, not just those with `recurseForDerivations`, e.g. for a Hydra jobset.
  # Not for Nixpkgs, which would never finish (e.g. `pkgs.pkgs` is `pkgs`).
  forceRecurse ? false,
  # "packages" for the derivations of the tree, or "tests" for their `passthru.tests` (see ./testsRoot.nix), which
  # mkDiff.nix compares along with the packages report of the same tree. (Not `kind`, which callPackage would fill with
  # Nixpkgs' `kind`.)
  reportKind ? "packages",
  # What a tests report doesn't walk: an attribute set nested like the tree, with `true` for each attribute path to skip
  # (see ./skip.nix, the default). To add to the default, merge with it recursively, e.g. with
  # `lib.recursiveUpdate (import ./skip.nix) { ... }`.
  skip ? import ./skip.nix,

  # callPackage arguments
  iets,
  jq,
  lib,
  runCommand,
}:
assert lib.assertMsg (builtins.elem reportKind [
  "packages"
  "tests"
]) "mkReport.nix: reportKind must be \"packages\" or \"tests\"";
assert lib.assertMsg (
  !(forceRecurse && file == null)
) "mkReport.nix: forceRecurse is for a `file`: Nixpkgs (e.g. `pkgs.pkgs`) would never finish";
let
  # What the report evaluates (shared with mkJobs.nix, through passthru.root).
  root = import ./rootExpr.nix {
    inherit
      args
      attrPath
      evalSystem
      file
      lib
      nixpkgs
      nixpkgsArgs
      withCA
      withCUDA
      ;
  };

  expr =
    if reportKind == "packages" then
      root
    else
      ''
        import ${./testsRoot.nix} {
          skip = builtins.fromJSON ${lib.strings.escapeNixString (builtins.toJSON skip)};
          forceRecurse = ${builtins.toJSON forceRecurse};
        } (${root})
      '';
in
# The report is the jobs of the tree, as iets' `eval-jobs` walks it (the walk of nix-eval-jobs and Hydra: attribute
# sets with `recurseForDerivations`, and functions called with the arguments they have defaults for), one JSON line per
# attribute path, sorted:
#   {"attrPath": [...], "outputs": {"out": "/nix/store/...", ...}}  for a derivation, or
#   {"attrPath": [...], "error": "<the last error line>"}           for an attribute that failed to evaluate.
# The output paths are real ones, so reports of the same tree are the same whatever iets made them.
#
# eval-jobs evaluates each attribute on its own, so any error (not just what `tryEval` catches) is only that
# attribute's, and a tests report evaluates whatever its tests do. A fatal error (e.g. a stack overflow) makes eval-jobs
# exit 1, which fails the build.
#
# NOTE: iets never frees memory, and the evaluated package set stays reachable until the end anyway; a Nixpkgs packages
# report peaks at ~19 GB (aarch64-linux, without CUDA).
runCommand name
  {
    __structuredAttrs = true;
    strictDeps = true;

    nativeBuildInputs = [ jq ];

    inherit expr;

    passthru = {
      inherit
        args
        attrPath
        evalSystem
        file
        forceRecurse
        nixpkgs
        reportKind
        root
        skip
        withCA
        withCUDA
        ;
    };
  }
  # --impure: the tree and these files are store paths, which pure evaluation may not import.
  # --no-instantiate: compute the derivations' paths without writing them to a store (reports have none).
  # --max-memory-size 0: one process (its workers are threads sharing the evaluation) with no memory limit, rather than
  # worker processes that each evaluate the tree again and restart at the limit.
  # --workers 8: for a Nixpkgs packages report (aarch64-linux, 10 fast and 10 slow cores, a loaded machine), 4 workers
  # took 21-25 s, 8 took 17-18 s, and 20 took 14-17 s for 10-20 % more CPU time and 0.3-0.5 GB more memory. iets' own
  # measurements (docs/explanation/evaluation.md, "Scaling limits") stop improving at about 6.
  # --force-recurse: for a packages report only; testsRoot.nix does its own.
  # env --ignore-environment: Nixpkgs reads the environment (e.g. drbd's `builtins.getEnv "SHELL"`), which in a build is
  # the builder's stdenv's, so without it a report would depend on this flake's nixpkgs, not just on the tree.
  # IETS_PROGRESS=0: no progress lines, so the log doesn't depend on timing.
  # eval-jobs ends its log with the counts of jobs and errors, the time taken and the peak memory.
  ''
    nixLog "running eval-jobs"
    env --ignore-environment HOME="$HOME" TMPDIR="$TMPDIR" IETS_PROGRESS=0 \
      ${iets}/bin/iets eval-jobs \
      --impure \
      --no-instantiate \
      --max-memory-size 0 \
      --workers 8 \
      ${lib.optionalString (forceRecurse && reportKind == "packages") "--force-recurse"} \
      --expr "$expr" \
      > jobs.jsonl

    jq --compact-output '
      if .error then
        { attrPath, error: (.error | split("\n") | map(select(test("^ *error: "))) | last // "?" | sub("^ *error: "; "")) }
      else
        { attrPath, outputs }
      end
    ' jobs.jsonl \
      | LC_ALL=C sort > "$out"
  ''
