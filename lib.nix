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
  # A derivation with `requiredSystemFeatures` (e.g. a GPU check's [ "cuda" ]) has them too, as "requiredSystemFeatures",
  # and one whose `meta.hydraPlatforms` (the systems Hydra builds it for, e.g. [ ] for a package too big to cache) is a
  # list of systems has it as "hydraPlatforms".
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
      # Whether to evaluate the tests too: `passthru.tests` and GPU checks (see eval/tests.nix).
      tests ? false,
      # With `tests`: the packages whose tests not to walk, nested like the tree, with `true` for each attribute path to
      # skip and everything below it, e.g. `{ dotnetCorePackages = true; }` (added to eval/tests.nix's own `skip`).
      skipTests ? { },
      # Whether to recurse into every attribute set, not just those with `recurseForDerivations` (not for Nixpkgs,
      # where `pkgs.pkgs` is `pkgs`).
      forceRecurse ? false,
      # How eval-jobs evaluates: `workers` threads of one process with no memory limit (`maxMemorySize` 0), or
      # `workers` processes, each replaced once its memory goes above `maxMemorySize` MB. iets can't free what a process
      # has evaluated, so a limit is the only way to bound a report's memory; its peak is then about `workers` times
      # `maxMemorySize`, and each process evaluates what the jobs share again, so it takes longer. For a Nixpkgs report
      # with tests (evalSystem x86_64-linux, with CUDA, on 20 aarch64-linux cores): 8 threads took 25.5 s with a peak of
      # 31.1 GB; 4 processes of 4096 MB 39.9 s and 16.4 GB; 2 of 4096 MB 66.3 s and 8.2 GB. With fewer tests (two test
      # sets skipped): 8 threads 20.8 s and 22.7 GB; 8 processes of 2048 MB 25.8 s and 15.2 GB; 4 of 4096 MB 33.0 s and
      # 15.8 GB. So more, smaller processes are faster for the same memory.
      workers ? 8,
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
        inherit
          args
          attrPath
          evalSystem
          forceRecurse
          tests
          withCA
          withCUDA
          ;
      }
      # Only when given, so that reports without it are the same derivations as before it existed.
      // lib.optionalAttrs (skipTests != { }) { inherit skipTests; };
    in
    assert lib.assertMsg (
      !(forceRecurse && settings.file == null)
    ) "forceRecurse is for a file: Nixpkgs (e.g. `pkgs.pkgs`) would never finish";
    assert lib.assertMsg (skipTests == { } || tests) "skipTests is for a report with tests";
    runCommand "report-${label}"
      {
        __structuredAttrs = true;
        strictDeps = true;
        nativeBuildInputs = [ jq ];
        inherit settings;
        passthru = { inherit label settings; };
      }
      # --impure: the tree and eval/ are store paths, which pure evaluation may not import.
      # --no-instantiate: compute the derivations' paths without writing them to a store (there is none).
      # --max-memory-size 0 (the default `maxMemorySize`): one process, whose workers are threads sharing the
      # evaluation, with no memory limit, rather than worker processes that each evaluate the tree again and restart at
      # the limit.
      # --workers 8 (the default `workers`): for a Nixpkgs packages report (aarch64-linux, 10 fast and 10 slow cores, a
      # loaded machine), 4 workers took 21-25 s, 8 took 17-18 s, and 20 took 14-17 s for 10-20 % more CPU time and
      # 0.3-0.5 GB more memory. iets' own measurements (docs/explanation/evaluation.md, "Scaling limits") stop
      # improving at about 6.
      # env --ignore-environment: Nixpkgs reads the environment (e.g. drbd's `builtins.getEnv "SHELL"`), which in a
      # build is the builder's stdenv's, so without it a report would depend on the caller's Nixpkgs, not just on the
      # tree.
      # IETS_PROGRESS=0: no progress lines, so the log doesn't depend on timing. eval-jobs' last line has the counts
      # of jobs and errors, the time taken and the peak memory.
      # --apply: each job's `requiredSystemFeatures` and `meta.hydraPlatforms`, as its `extraValue`. hydraPlatforms is
      # null unless it's a list of systems: platform patterns (attribute sets) can hold functions, which JSON can't.
      # jq: each job's attribute path is its path in the tree (see eval/root.nix's `jobs`), and an error is its last
      # line.
      ''
        env --ignore-environment HOME="$HOME" TMPDIR="$TMPDIR" IETS_PROGRESS=0 \
          ${iets}/bin/iets eval-jobs \
          --impure \
          --no-instantiate \
          --max-memory-size ${toString maxMemorySize} \
          --workers ${toString workers} \
          ${lib.optionalString forceRecurse "--force-recurse"} \
          --apply '
            drv: {
              requiredSystemFeatures = drv.requiredSystemFeatures or [ ];
              hydraPlatforms =
                let platforms = drv.meta.hydraPlatforms or null;
                in if builtins.isList platforms && builtins.all builtins.isString platforms then platforms else null;
            }' \
          --expr "(import ${./eval}/root.nix (builtins.fromJSON (builtins.readFile \"$NIX_ATTRS_JSON_FILE\")).settings).jobs" \
          > jobs.jsonl

        jq --compact-output '
          { attrPath: .attrPath[1:] }
          + (
            if .error then
              { error: (.error | split("\n") | map(select(test("^ *error: "))) | last // "?" | sub("^ *error: "; "")) }
            else
              { outputs }
              + (
                (.extraValue.requiredSystemFeatures // []) as $features
                | if $features == [] then {} else { requiredSystemFeatures: $features } end
              )
              + (if .extraValue.hydraPlatforms == null then {} else { hydraPlatforms: .extraValue.hydraPlatforms } end)
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
      # Derivations to build first. For a caller that reads the result during evaluation (import-from-derivation):
      # every report it reads, so that the first diff it reads has them all built at once, in parallel, rather than
      # each read waiting for its own.
      after ? [ ],
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
        // lib.optionalAttrs (after != [ ]) { inherit after; }
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
