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
  # With `apply`, a derivation's line also has "extraValue", the result of `apply`.
  # eval-jobs evaluates each attribute on its own, so an error of any kind is only that attribute's. A fatal error (e.g.
  # a stack overflow) makes it exit 1, which fails the build.
  #
  # A report is a derivation of the tree and its arguments, so a tree's report is built once and reused by every
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
      # `{ withCA, withCUDA }` (default: eval/nixpkgs.nix). The file is copied to the store on its own, so it can't
      # import files next to it.
      evalSystem,
      nixpkgsArgs ? null,
      withCA ? false,
      withCUDA ? false,
      # Whether to evaluate the tests too: `passthru.tests` and GPU checks (see eval/tests.nix).
      tests ? false,
      # With `tests`: the packages whose tests not to walk, nested like the tree, with `true` for each attribute path to
      # skip and everything below it, e.g. `{ dotnetCorePackages = true; }` (added to eval/tests.nix's own `skip`).
      skipTests ? { },
      # Jobs the walk doesn't reach, as a Nix file (copied to the store on its own) whose function takes what is
      # evaluated (after `attrPath`) and returns an attribute set for eval-jobs to walk, with `recurseForDerivations`
      # set on each attribute set to recurse into. A job's attribute path in it must be its path in what is evaluated
      # (e.g. `{ haskell.packages.ghc96 = { inherit (pkgs.haskell.packages.ghc96) haskell-language-server; }; }`), as
      # that is where mkJobs finds it. A job the walk reaches too is in the report once (with `sort --unique`).
      extraJobs ? null,
      # Whether to recurse into every attribute set, not just those with `recurseForDerivations` (not for Nixpkgs,
      # where `pkgs.pkgs` is `pkgs`).
      forceRecurse ? false,
      # A Nix function (as a string) eval-jobs applies to each derivation, whose result (an attribute set) the report
      # keeps as "extraValue", e.g. "drv: { inherit (drv) requiredSystemFeatures; }".
      apply ? null,
      # With 0, eval-jobs evaluates in one process with no memory limit. Otherwise, in 8 processes, each replaced once
      # its memory goes above `maxMemorySize` MB, so that the report's memory stays under about 8 times that. iets can't
      # free what a process has evaluated, so this is the only way to bound it; each process evaluates again what the
      # jobs share, so it takes longer.
      maxMemorySize ? 0,
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
        extraJobs = if extraJobs == null then null else "${extraJobs}";
        inherit
          args
          attrPath
          evalSystem
          forceRecurse
          skipTests
          tests
          withCA
          withCUDA
          ;
      };
    in
    assert lib.assertMsg (
      !(forceRecurse && settings.file == null)
    ) "forceRecurse is for a file: Nixpkgs (e.g. `pkgs.pkgs`) would never finish";
    assert lib.assertMsg (
      settings.file == null || !(withCA || withCUDA || nixpkgsArgs != null)
    ) "withCA, withCUDA and nixpkgsArgs are for Nixpkgs, not ${settings.file}";
    assert lib.assertMsg (skipTests == { } || tests) "skipTests is for a report with tests";
    runCommand "report-${label}"
      {
        __structuredAttrs = true;
        nativeBuildInputs = [ jq ];
        inherit settings;
        passthru = { inherit label settings; };
      }
      # --impure: the tree and eval/ are store paths, which pure evaluation may not import.
      # --no-instantiate: compute the derivations' paths without writing them to a store (there is none).
      # --workers 8: more, smaller processes are faster for the same memory (see README.md, "Cost").
      # env --ignore-environment: Nixpkgs reads the environment (e.g. drbd's `builtins.getEnv "SHELL"`), which in a
      # build is the builder's stdenv's, so without it a report would depend on the caller's Nixpkgs, not just on the
      # tree.
      # IETS_PROGRESS=0: no progress lines, so the log doesn't depend on timing. eval-jobs' last line has the counts
      # of jobs and errors, the time taken and the peak memory.
      # jq: each job's attribute path is its path in the tree (see eval/root.nix's `jobs`), and an error is its last
      # `error:` line (or all of it, without one).
      ''
        env --ignore-environment HOME="$HOME" TMPDIR="$TMPDIR" IETS_PROGRESS=0 \
          ${iets}/bin/iets eval-jobs \
          --impure \
          --no-instantiate \
          --max-memory-size ${toString maxMemorySize} \
          --workers 8 \
          ${lib.optionalString forceRecurse "--force-recurse"} \
          ${lib.optionalString (apply != null) "--apply ${lib.escapeShellArg apply}"} \
          --expr "(import ${./eval}/root.nix (builtins.fromJSON (builtins.readFile \"$NIX_ATTRS_JSON_FILE\")).settings).jobs" \
          > jobs.jsonl

        jq --compact-output '
          { attrPath: .attrPath[1:] }
          + (
            if .error then
              { error: (.error | (split("\n") | map(select(test("^ *error: "))) | last | values | sub("^ *error: "; "")) // .) }
            else
              { outputs } + (if has("extraValue") then { extraValue } else {} end)
            end
          )
        ' jobs.jsonl \
          | LC_ALL=C sort --unique > "$out"
      '';

  # The jobs: what changed from one report (`pre`) to another (`post`), as a directory with
  # - default.nix (see eval/jobs.nix), for nix-eval-jobs (`--expr "import $out"`) or a Hydra jobset: the derivations
  #   added, changed or fixed in `post`'s tree, selected from it as its report evaluated it (eval/root.nix and
  #   settings.json);
  # - changed.json, their attribute paths;
  # - diff.json, the diff of the reports (see ./diff.jq).
  mkJobs =
    { pre, post }:
    runCommand "jobs-${pre.label}-${post.label}"
      {
        __structuredAttrs = true;
        nativeBuildInputs = [ jq ];
        inherit pre post;
        inherit (post) settings;
      }
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
