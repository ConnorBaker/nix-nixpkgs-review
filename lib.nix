# The derivations nnr is made of, for a caller that has the trees as paths (e.g. a Hydra jobset, whose inputs they
# are) rather than a git repository (see ./review.nix). Call it with `callPackage`, and `iets`: a build of iets (or
# anything whose string is a store path with bin/iets).
{
  lib,
  runCommand,
  jq,
  iets,
}:
let
  # A tree's report: one JSON line per attribute eval-jobs walks, sorted:
  #   {"attrPath": [...], "outputs": {"out": "/nix/store/...", ...}}  for a derivation, or
  #   {"attrPath": [...], "error": "<the last error line>"}           for an attribute that failed to evaluate.
  # eval-jobs evaluates each attribute on its own, so an error of any kind is only that attribute's. A fatal error (e.g.
  # a stack overflow) makes it exit 1, which fails the build.
  #
  # A report depends only on its name, the tree and the settings, so a tree's report is built once and reused by every
  # comparison with it.
  mkReport =
    {
      # The derivation's name is "report-${label}".
      label,
      # The tree (a path or store path).
      tree,
      # What to evaluate (see eval/root.nix): without `file`, a tree with pkgs/top-level/all-packages.nix is Nixpkgs,
      # and any other tree's is default.nix. `args` reach the evaluation as JSON, so their values can be anything JSON
      # can hold, or paths (which are copied to the store).
      file ? null,
      attrPath ? [ ],
      args ? { },
      # For Nixpkgs: the system to evaluate it for, and its arguments, as a Nix file whose function takes
      # `{ withCA, withCUDA }` (default: eval/nixpkgs.nix).
      evalSystem,
      nixpkgsArgs ? null,
      withCA ? false,
      withCUDA ? false,
      # Whether to evaluate `passthru.tests` too (see eval/tests.nix).
      tests ? false,
      # Whether to recurse into every attribute set, not just those with `recurseForDerivations` (not for Nixpkgs,
      # where `pkgs.pkgs` is `pkgs`).
      forceRecurse ? false,
      # A derivation to build first (e.g. the previous report, so that reports are built one at a time).
      after ? null,
    }:
    let
      settings = {
        tree = "${tree}";
        file =
          if file != null then
            file
          else if builtins.pathExists "${tree}/pkgs/top-level/all-packages.nix" then
            null
          else
            "default.nix";
        nixpkgsArgs = if nixpkgsArgs == null then null else "${nixpkgsArgs}";
        inherit
          args
          attrPath
          evalSystem
          forceRecurse
          tests
          withCA
          withCUDA
          ;
      };
    in
    assert lib.assertMsg (
      !(forceRecurse && settings.file == null)
    ) "forceRecurse is for a file: Nixpkgs (e.g. `pkgs.pkgs`) would never finish";
    runCommand "report-${label}"
      (
        {
          __structuredAttrs = true;
          strictDeps = true;
          nativeBuildInputs = [ jq ];
          inherit settings;
          passthru = { inherit label settings; };
        }
        // lib.optionalAttrs (after != null) { inherit after; }
      )
      # --impure: the tree and eval/ are store paths, which pure evaluation may not import.
      # --no-instantiate: compute the derivations' paths without writing them to a store (there is none).
      # --max-memory-size 0: one process, whose workers are threads sharing the evaluation, with no memory limit,
      # rather than worker processes that each evaluate the tree again and restart at the limit.
      # --workers 8: for a Nixpkgs packages report (aarch64-linux, 10 fast and 10 slow cores, a loaded machine), 4
      # workers took 21-25 s, 8 took 17-18 s, and 20 took 14-17 s for 10-20 % more CPU time and 0.3-0.5 GB more
      # memory. iets' own measurements (docs/explanation/evaluation.md, "Scaling limits") stop improving at about 6.
      # env --ignore-environment: Nixpkgs reads the environment (e.g. drbd's `builtins.getEnv "SHELL"`), which in a
      # build is the builder's stdenv's, so without it a report would depend on the caller's Nixpkgs, not just on the
      # tree.
      # IETS_PROGRESS=0: no progress lines, so the log doesn't depend on timing. eval-jobs' last line has the counts
      # of jobs and errors, the time taken and the peak memory.
      # jq: each job's attribute path is its path in the tree (see eval/root.nix's `jobs`), and an error is its last
      # line.
      ''
        env --ignore-environment HOME="$HOME" TMPDIR="$TMPDIR" IETS_PROGRESS=0 \
          ${iets}/bin/iets eval-jobs \
          --impure \
          --no-instantiate \
          --max-memory-size 0 \
          --workers 8 \
          ${lib.optionalString forceRecurse "--force-recurse"} \
          --expr "(import ${./eval}/root.nix (builtins.fromJSON (builtins.readFile \"$NIX_ATTRS_JSON_FILE\")).settings).jobs" \
          > jobs.jsonl

        jq --compact-output '
          { attrPath: .attrPath[1:] }
          + (
            if .error then
              { error: (.error | split("\n") | map(select(test("^ *error: "))) | last // "?" | sub("^ *error: "; "")) }
            else
              { outputs }
            end
          )
        ' jobs.jsonl \
          | LC_ALL=C sort > "$out"
      '';

  # The jobs: what changed from one report (`pre`) to another (`post`), as a directory with
  # - default.nix (see eval/jobs.nix), for nix-eval-jobs (`--expr "import $out"`) or a Hydra jobset: the derivations
  #   added, changed or fixed in `post`'s tree, selected from it as its report evaluated it (eval/root.nix and
  #   settings.json);
  # - changed.json, their attribute paths;
  # - diff.json, the diff of the reports (see ./diff.jq).
  mkJobs =
    {
      pre,
      post,
      # A derivation to build first (as for mkReport).
      after ? null,
    }:
    runCommand "jobs-${pre.label}-${post.label}"
      (
        {
          __structuredAttrs = true;
          strictDeps = true;
          nativeBuildInputs = [ jq ];
          inherit pre post;
          inherit (post) settings;
        }
        // lib.optionalAttrs (after != null) { inherit after; }
      )
      ''
        mkdir "$out"
        cp ${./eval}/{nixpkgs,root,tests}.nix "$out/"
        cp ${./eval}/jobs.nix "$out/default.nix"
        jq .settings "$NIX_ATTRS_JSON_FILE" > "$out/settings.json"
        jq --compact-output --null-input --slurpfile pre "$pre" --slurpfile post "$post" --from-file ${./diff.jq} \
          > "$out/diff.json"
        jq --compact-output '.added + .changed + .fixed | sort' "$out/diff.json" > "$out/changed.json"
      '';
in
{
  inherit mkJobs mkReport;
}
