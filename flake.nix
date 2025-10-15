{
  description = "nix-nixpkgs-review";

  inputs = {
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    nix = {
      url = "github:DeterminateSystems/nix-src";
      inputs = {
        nixpkgs-regression.follows = "";
        nixpkgs-23-11.follows = "";
        flake-parts.follows = "";
        git-hooks-nix.follows = "";
      };
    };

    # Just use whatever Nix has pinned.
    nixpkgs.follows = "nix/nixpkgs";

    # Commit prior to PR -- no easy way to get this commit using flake URI since the caret character (^) is treated
    # as "extra".
    nixpkgs-pre.url = "github:NixOS/nixpkgs/16a0bed90bd882834bf3fc1dea26ed22b67b962f";

    # HEAD of PR
    nixpkgs-post.url = "github:NixOS/nixpkgs/pull/437723/head";
  };

  outputs =
    inputs:
    let
      inherit (inputs.nixpkgs) lib;

      configurations = {
        evalSystem = [
          "aarch64-linux"
          "x86_64-linux"
        ];
        when = [
          "pre"
          "post"
        ];
        withCA = [
          false
          true
        ];
        withCUDA = [
          false
          true
        ];
      };

      mkName =
        {
          evalSystem,
          when,
          withCA,
          withCUDA,
        }:
        "pkgs-${evalSystem}"
        + lib.optionalString withCA "-ca"
        + lib.optionalString withCUDA "-cuda"
        + "-${when}";

      mapCartesianProductToAttrs =
        f:
        lib.flip lib.pipe [
          (lib.mapCartesianProduct f)
          lib.listToAttrs
        ];

      concatMapCartesianProductToAttrs =
        f:
        lib.flip lib.pipe [
          (lib.mapCartesianProduct f)
          lib.concatLists
          lib.listToAttrs
        ];
    in
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.flake-parts.flakeModules.partitions
      ];

      systems = configurations.evalSystem;

      transposition = {
        packageSets.adHoc = true;
        reports.adHoc = true;
        diffs.adHoc = true;
      };

      perSystem =
        {
          config,
          pkgs,
          system,
          ...
        }:
        {
          # To be used for introspection only; these are instantiated within a derivation, so
          # don't use or instantiate these because they'll hang around instead of being GC'd.
          packageSets =
            let
              mkPackageSet = cfg: {
                name = mkName cfg;
                value = import inputs."nixpkgs-${cfg.when}" {
                  # NOTE: We use the evalSystem from cfg as the system to instantiate Nixpkgs with.
                  # This simplifies the reviews packages because we can avoid indexing into systems in
                  # the packageSets attribute set, instead using the current system.
                  system = cfg.evalSystem;
                  config = import ./configs { inherit (cfg) withCA withCUDA; };
                  overlays = import ./overlays { inherit (cfg) withCA; };
                };
              };
            in
            mapCartesianProductToAttrs mkPackageSet configurations;

          # TODO: Generalize reports so we can generate them for systems other than the current one.
          reports =
            let
              mkReport =
                cfg:
                let
                  name = mkName cfg;
                in
                {
                  inherit name;
                  value = pkgs.callPackage ./mkReport.nix {
                    inherit (cfg) evalSystem withCA withCUDA;
                    name = "report-${name}";
                    nixpkgs = inputs."nixpkgs-${cfg.when}";
                    # We don't need the doc or dev outputs.
                    nix = inputs.nix.packages.${system}.default.out;
                  };
                };
            in
            mapCartesianProductToAttrs mkReport configurations;

          diffs =
            let
              mkDiff =
                { reportPreName, reportPostName }:
                let
                  name = reportPreName + "-" + reportPostName;
                  reportPre = config.reports.${reportPreName};
                  reportPost = config.reports.${reportPostName};
                in
                lib.optionals
                  (
                    # It doesn't make sense to compare across systems.
                    reportPre.evalSystem == reportPost.evalSystem
                    # It doesn't make sense to compare with and without CA derivations.
                    && reportPre.withCA == reportPost.withCA
                  )
                  [
                    {
                      inherit name;
                      value = pkgs.callPackage ./mkDiff.nix {
                        name = "diff-${name}";
                        inherit reportPre reportPost;
                      };
                    }
                  ];

              reportNames = lib.attrNames config.reports;
            in
            concatMapCartesianProductToAttrs mkDiff {
              reportPreName = reportNames;
              reportPostName = reportNames;
            };

          # TODO: Create a review shell or something so that with failing derivations I can do `nix why-depends` with
          # the derivation and the review shell and see how the dependency is being brought in (e.g., directly or
          # transitively).
          packages = lib.mapAttrs' (
            name: diff:
            let
              name' = "review-${name}";
              packageSetAttrPath = "packageSets.${system}.${lib.removePrefix "report-" diff.reportPost.name}";
            in
            {
              name = name';
              # NOTE: These scripts won't capture being run with --override-input since it doesn't change the committed lockfile.
              # TODO: What if we forwarded all arguments the script received and used them to build diff and everything else
              # with those arguments?
              # Ideally having the reference through inputs.self.outPath and inputs.self.narHash would be enough if, when
              # --override-input is used, a new store path entry with a new flake lockfile is created; if that's not the case,
              # need to think of something else.
              # Unfortunately, that doesn't seem to be the case.
              # Consider the case where we do forward the arguments and do override-input in the script --
              # what if the inputs are unlocked? If evaluation of the diff takes long enough, by the time
              # we're running `nix build`, the unlocked inputs could have changed and been fetched again.
              # TODO: Sometimes I get errors about the nix store path in flakeRef not existing and being incapable of being built.
              # Maybe something to do with lazy-trees?
              value = pkgs.writeShellScriptBin name' ''
                echo "added derivations: $(${lib.getExe pkgs.jq} < ${diff} '.added | length')"
                ${lib.getExe pkgs.jq} --raw-output '.added | sort[]' < ${diff}
                echo

                echo "changed derivations: $(${lib.getExe pkgs.jq} < ${diff} '.changed | length')"
                ${lib.getExe pkgs.jq} --raw-output '.changed | sort[]' < ${diff}
                echo

                echo "building added and changed derivations"
                ${lib.getExe pkgs.jq} \
                  --raw-output \
                  '(.added + .changed) | sort[] | ".#${packageSetAttrPath}." + . ' \
                  < ${diff} | \
                nix build \
                  --keep-going \
                  --no-link \
                  --stdin
              '';
            }
          ) config.diffs;
        };

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
