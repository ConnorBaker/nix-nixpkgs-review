# What changed between two trees of a git repository: each tree's report, made by iets' eval-jobs, and the jobs, which
# are what changed in the second (see ./lib.nix).
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
  # What to evaluate (see lib.nix's mkReport). `attr` is dot-separated.
  file ? null,
  attr ? null,
  args ? { },
  forceRecurse ? false,
}:
let
  pkgs = nixpkgs.legacyPackages.${system};
  inherit (pkgs) lib;
  nnr = pkgs.callPackage ./lib.nix { iets = iets.packages.${system}.default; };

  mkReport =
    rev:
    nnr.mkReport {
      tree = builtins.fetchGit ({ url = repo; } // lib.optionalAttrs (rev != null) { inherit rev; });
      attrPath = if attr == null then [ ] else lib.splitString "." attr;
      inherit
        args
        evalSystem
        file
        forceRecurse
        tests
        withCA
        withCUDA
        ;
    };
in
nnr.mkJobs {
  pre = mkReport base;
  post = mkReport head;
}
