{
  description = "nix-nixpkgs-review";

  inputs = {
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    # Determinate Nix's main branch (locked in flake.lock); ./patches/nix are rebased onto the locked commit.
    nix = {
      url = "github:DeterminateSystems/nix-src";
      inputs = {
        nixpkgs-regression.follows = "";
        nixpkgs-23-11.follows = "";
        flake-parts.follows = "";
        git-hooks-nix.follows = "";
      };
    };

    # Builds the patched `nix` with CSPGO and BOLT; see `hydraJobs.determinate-nix`.
    nix-optimization = {
      url = "github:ConnorBaker/nix-optimization";
      inputs = {
        nix.follows = "nix";
        flake-parts.follows = "flake-parts";
      };
    };

    # Just use whatever Nix has pinned.
    nixpkgs.follows = "nix/nixpkgs";
  };

  outputs =
    inputs:
    let
      inherit (inputs.nixpkgs) lib;

      # The patched Nix (see `hydraJobs.determinate-nix`), in each of nix-optimization's variants.
      patchedNixVariants =
        system:
        inputs.nix-optimization.lib.mkOptimizedVariants {
          inherit system;
          profileWorkloads = [
            [
              "nixpkgs"
              "parallel"
            ]
          ];
          patches = lib.pipe (builtins.readDir ./patches/nix) [
            lib.attrNames
            (lib.filter (lib.hasSuffix ".patch"))
            (map (name: ./patches/nix + "/${name}"))
          ];
          extraProfileEvalArgs = [
            "--option"
            "fingerprint-derivations"
            "true"
          ];
          enableGC = false;
        };
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
        The diff (see mkDiff.nix) between two trees of a git repository, each evaluated by mkReport.nix with the patched
        Nix (`patchedNixVariants`' cs-pgo-bolt, as `hydraJobs.determinate-nix`). Used by `packages.nnr`, which resolves
        the revisions.

        - `repo`: the repository (a path);
        - `base`, `head`: the commits to compare; `head = null` is the working tree (as `builtins.fetchGit` sees it:
          tracked files as they are, and staged new files);
        - `tests`: whether to compare `passthru.tests` too; the diff fails if a tests report doesn't evaluate;
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
                  nix = (patchedNixVariants system).cs-pgo-bolt.nix-cli;
                  fingerprintDerivations = true;
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
        pkgs.callPackage ./mkDiff.nix {
          name = "diff-${pre.label}-${post.label}";
          reportPre = pre.packages;
          reportPost = post.packages;
          testsPre = pre.tests;
          testsPost = post.tests;
          requireTests = tests;
        };

      # The Nix used by mkReport.nix; Hydra jobsets consume it as a `build` input so they never need to fetch or build
      # it during evaluation.
      # It is built with CSPGO and then BOLT (both profiled on a parallel evaluation of Nixpkgs) and with the patches in
      # ./patches/nix
      # (`git format-patch` output, applied in order), notably:
      # - the `fingerprint-derivations` setting, which computes derivation and output paths that are only good for
      #   telling whether derivations changed, but much more cheaply;
      # - `maybeParseStorePath()` not throwing (~1.8M exceptions per report) for paths that obviously aren't store
      #   paths, such as the files of Nixpkgs;
      # - evaluator hot path fixes (~20% fewer instructions per report), which keep the reports identical (apart from
      #   the fingerprints' values, which only need to be comparable with each other).
      # The patches are against the `nix` input, so update them together.
      # It is built without Boehm GC: reports never collect anyway (see mkReport.nix), so the evaluator bump-allocates
      # from per-thread chunks instead, which took ~7% fewer cycles and 2.5G less memory (24G peak).
      flake.hydraJobs.determinate-nix = lib.genAttrs [ "x86_64-linux" ] (
        system: (patchedNixVariants system).cs-pgo-bolt.nix-cli
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
