{
  description = "nix-nixpkgs-review";

  inputs = {
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    # The evaluator mkReport.nix uses (see `hydraJobs.iets`): a Nix evaluator in Rust. A branch of a fork with fixes not
    # yet merged upstream: numtide/iets#354 (call `__functor` sets, as Nix does) and numtide/iets#355 (an intermittent
    # abort at exit, which fails a report). Switch back to numtide/iets once both are in.
    iets.url = "github:ConnorBaker/iets/nix-nixpkgs-review";

    # Just use whatever iets has pinned, which it's tested with.
    nixpkgs.follows = "iets/nixpkgs";
  };

  outputs =
    inputs:
    let
      inherit (inputs.nixpkgs) lib;
    in
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.flake-parts.flakeModules.partitions
      ];

      systems = [
        "aarch64-linux"
        "x86_64-linux"
      ];

      perSystem =
        { config, pkgs, ... }:
        {
          packages = {
            default = config.packages.nnr;

            # What changed between two revisions of a git repository: builds `lib.mkReview` (see README.md).
            nnr = pkgs.writeShellApplication {
              name = "nnr";
              runtimeInputs = [
                pkgs.git
                pkgs.jq
              ];
              text = builtins.replaceStrings [ "@flake@" ] [ "path:${inputs.self}" ] (builtins.readFile ./nnr.sh);
            };
          };
        };

      /**
        The jobs (see mkJobs.nix) for what changed between two trees of a git repository: a Nix expression for the
        derivations added, changed or fixed in `head`, for nix-eval-jobs or a Hydra jobset. Each tree is evaluated by
        mkReport.nix (with iets, as `hydraJobs.iets`), and the reports are compared by mkDiff.nix (in `passthru.diff`).
        Used by `packages.nnr`, which resolves the revisions.

        - `repo`: the repository (a path);
        - `base`, `head`: the commits to compare; `head = null` is the working tree (as `builtins.fetchGit` sees it:
          tracked files as they are, and staged new files);
        - `tests`: whether to compare `passthru.tests` too;
        - `system`: the system to build the reports on; it defaults to the current one, which needs `--impure`;
        - `evalSystem`, `withCUDA`, `withCA`: as mkReport.nix's (for Nixpkgs);
        - `file`, `attr` (dot-separated), `args`, `forceRecurse`: mkReport.nix's entry point. Without `file`, a tree
          with pkgs/top-level/all-packages.nix is evaluated as Nixpkgs, and any other tree's default.nix.

        Each tree's reports depend only on the tree and the settings, so a commit's reports are built once and reused by
        every diff with it.
      */
      flake.lib.mkReview =
        {
          repo,
          base,
          head ? null,
          system ? builtins.currentSystem,
          evalSystem ? system,
          withCUDA ? false,
          withCA ? false,
          tests ? false,
          file ? null,
          attr ? null,
          args ? { },
          forceRecurse ? false,
        }:
        let
          pkgs = inputs.nixpkgs.legacyPackages.${system};

          mkReports =
            rev:
            let
              tree = builtins.fetchGit ({ url = repo; } // lib.optionalAttrs (rev != null) { inherit rev; });
              label = if rev == null then "working-tree" else builtins.substring 0 12 rev;
              mkReport =
                reportKind:
                pkgs.callPackage ./mkReport.nix {
                  name = "report-${reportKind}-${label}";
                  nixpkgs = tree;
                  inherit
                    args
                    evalSystem
                    forceRecurse
                    reportKind
                    withCA
                    withCUDA
                    ;
                  iets = inputs.iets.packages.${system}.default;
                  file =
                    if file != null then
                      file
                    else if builtins.pathExists "${tree}/pkgs/top-level/all-packages.nix" then
                      null
                    else
                      "default.nix";
                  attrPath = if attr == null then [ ] else lib.splitString "." attr;
                };
            in
            {
              inherit label;
              packages = mkReport "packages";
              tests = if tests then mkReport "tests" else null;
            };

          pre = mkReports base;
          post = mkReports head;
        in
        pkgs.callPackage ./mkJobs.nix {
          name = "jobs-${pre.label}-${post.label}";
          report = post.packages;
          diff = pkgs.callPackage ./mkDiff.nix {
            name = "diff-${pre.label}-${post.label}";
            reportPre = pre.packages;
            reportPost = post.packages;
            testsPre = pre.tests;
            testsPost = post.tests;
          };
        };

      # The iets used by mkReport.nix; Hydra jobsets consume it as a `build` input so they never need to fetch or build
      # it during evaluation.
      flake.hydraJobs.iets = lib.genAttrs [ "x86_64-linux" ] (
        system: inputs.iets.packages.${system}.default
      );

      partitionedAttrs = {
        checks = "dev";
        devShells = "dev";
        formatter = "dev";
      };

      partitions.dev = {
        extraInputsFlake = ./dev;
        module = ./dev/flake-module.nix;
      };
    };
}
