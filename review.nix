# What changed between two trees of a git repository: each tree's report, made by iets' eval-jobs, and the jobs, which
# are what changed in the second.
{
  # This flake's inputs.
  nixpkgs,
  iets,
}:
{
  # The repository (a path).
  repo,
  # The commits to compare; `head = null` is the working tree, as `builtins.fetchGit` sees it: tracked files as they
  # are, and staged new files.
  base,
  head ? null,
  # The system to build the reports on (the current one needs `--impure`).
  system ? builtins.currentSystem,
  # For Nixpkgs: the system to evaluate it for, and its configuration (see eval/nixpkgs.nix).
  evalSystem ? system,
  withCUDA ? false,
  withCA ? false,
  # Whether to compare `passthru.tests` too (see eval/tests.nix).
  tests ? false,
  # What to evaluate (see eval/root.nix): without `file`, a tree with pkgs/top-level/all-packages.nix is Nixpkgs, and
  # any other tree's is default.nix. `attr` is dot-separated. `args` reach the evaluation as JSON, so their values can
  # be anything JSON can hold, or paths (which are copied to the store).
  file ? null,
  attr ? null,
  args ? { },
  # Whether to recurse into every attribute set, not just those with `recurseForDerivations` (not for Nixpkgs, where
  # `pkgs.pkgs` is `pkgs`).
  forceRecurse ? false,
}:
let
  pkgs = nixpkgs.legacyPackages.${system};
  inherit (pkgs) jq lib runCommand;

  # A tree's report: one JSON line per attribute eval-jobs walks, sorted:
  #   {"attrPath": [...], "outputs": {"out": "/nix/store/...", ...}}  for a derivation, or
  #   {"attrPath": [...], "error": "<the last error line>"}           for an attribute that failed to evaluate.
  # eval-jobs evaluates each attribute on its own, so an error of any kind is only that attribute's. A fatal error (e.g.
  # a stack overflow) makes it exit 1, which fails the build.
  #
  # A report depends only on the tree and the settings, so a commit's report is built once and reused by every
  # comparison with it.
  mkReport =
    rev:
    let
      tree = builtins.fetchGit ({ url = repo; } // lib.optionalAttrs (rev != null) { inherit rev; });
      label = if rev == null then "working-tree" else builtins.substring 0 12 rev;
      settings = {
        tree = "${tree}";
        file =
          if file != null then
            file
          else if builtins.pathExists "${tree}/pkgs/top-level/all-packages.nix" then
            null
          else
            "default.nix";
        attrPath = if attr == null then [ ] else lib.splitString "." attr;
        inherit
          args
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
    {
      inherit label settings;
      report =
        runCommand "report-${label}"
          {
            __structuredAttrs = true;
            strictDeps = true;
            nativeBuildInputs = [ jq ];
            inherit settings;
          }
          # --impure: the tree and eval/ are store paths, which pure evaluation may not import.
          # --no-instantiate: compute the derivations' paths without writing them to a store (there is none).
          # --max-memory-size 0: one process, whose workers are threads sharing the evaluation, with no memory limit,
          # rather than worker processes that each evaluate the tree again and restart at the limit.
          # --workers 8: for a Nixpkgs packages report (aarch64-linux, 10 fast and 10 slow cores, a loaded machine), 4
          # workers took 21-25 s, 8 took 17-18 s, and 20 took 14-17 s for 10-20 % more CPU time and 0.3-0.5 GB more
          # memory. iets' own measurements (docs/explanation/evaluation.md, "Scaling limits") stop improving at about 6.
          # env --ignore-environment: Nixpkgs reads the environment (e.g. drbd's `builtins.getEnv "SHELL"`), which in a
          # build is the builder's stdenv's, so without it a report would depend on this flake's nixpkgs, not just on
          # the tree.
          # IETS_PROGRESS=0: no progress lines, so the log doesn't depend on timing. eval-jobs' last line has the counts
          # of jobs and errors, the time taken and the peak memory.
          # jq: each job's attribute path is its path in the tree (see eval/root.nix's `jobs`), and an error is its last
          # line.
          ''
            env --ignore-environment HOME="$HOME" TMPDIR="$TMPDIR" IETS_PROGRESS=0 \
              ${iets.packages.${system}.default}/bin/iets eval-jobs \
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
    };

  pre = mkReport base;
  post = mkReport head;
in
# The jobs: a directory with
# - default.nix (see eval/jobs.nix), for nix-eval-jobs (`--expr "import $out"`) or a Hydra jobset: the derivations added,
#   changed or fixed in the second tree, selected from it as its report evaluated it (eval/root.nix and settings.json);
# - changed.json, their attribute paths;
# - diff.json, the diff of the reports (see ./diff.jq).
runCommand "jobs-${pre.label}-${post.label}"
  {
    __structuredAttrs = true;
    strictDeps = true;
    nativeBuildInputs = [ jq ];
    pre = pre.report;
    post = post.report;
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
  ''
