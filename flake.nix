{
  description = "nixpkgs-review";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nix = {
      url = "github:DeterminateSystems/nix-src";
      inputs = {
        nixpkgs-regression.follows = "";
        nixpkgs-23-11.follows = "";
      };
    };

    nixpkgs.follows = "nix/nixpkgs";

    nixpkgs-pre.url = "github:ConnorBaker/nixpkgs/ea839424d592075b11eadde501fd43f843b1664e";
    nixpkgs-post.url = "github:ConnorBaker/nixpkgs/2095912bf49e7447e3e91d2dbdce48909437e19d";
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.flake-parts.flakeModules.partitions
      ];

      systems = [
        "aarch64-linux"
        "x86_64-linux"
      ];

      transposition = {
        packageSets.adHoc = true;
        reports.adHoc = true;
        diffs.adHoc = true;
      };

      perSystem =
        {
          config,
          lib,
          pkgs,
          system,
          ...
        }:
        let
          configurations = {
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
              when,
              withCA,
              withCUDA,
            }:
            "pkgs" + lib.optionalString withCA "-ca" + lib.optionalString withCUDA "-cuda" + "-${when}";
        in
        {
          packages = lib.mapAttrs' (
            name: diff:
            let
              name' = "review-${name}";
              flakeRef = "${inputs.self.outPath}?narHash=${inputs.self.narHash}";
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
                  '(.added + .changed) | sort[] | "${flakeRef}#${packageSetAttrPath}." + . ' \
                  < ${diff} | \
                nix build \
                  --keep-going \
                  --no-link \
                  --stdin
              '';
            }
          ) config.diffs;

          # To be used for introspection only; these are instantiated within a derivation, so
          # don't use or instantiate these because they'll hang around instead of being GC'd.
          packageSets = lib.listToAttrs (
            lib.mapCartesianProduct (
              {
                when,
                withCA,
                withCUDA,
              }@cfg:
              {
                name = mkName cfg;
                value = import inputs."nixpkgs-${when}" {
                  inherit system;
                  config = import ./mkConfig.nix { inherit withCA withCUDA; };
                  overlays = lib.optionals withCA [ (import ./ca-overlay.nix) ];
                };
              }
            ) configurations
          );

          reports =
            let
              nix = inputs.nix.packages.${system}.default;
            in
            lib.listToAttrs (
              lib.mapCartesianProduct (
                {
                  when,
                  withCA,
                  withCUDA,
                }@cfg:
                let
                  name = mkName cfg;
                in
                {
                  inherit name;
                  value = pkgs.callPackage ./mkReport.nix {
                    name = "report-${name}";
                    nixpkgs = inputs."nixpkgs-${when}";
                    inherit nix withCA withCUDA;
                  };
                }
              ) configurations
            );

          diffs =
            let
              reportNames = lib.attrNames config.reports;
            in
            lib.listToAttrs (
              # It doesn't make sense to compare with and without CA derivations.
              lib.filter ({ value, ... }: value.reportPre.withCA == value.reportPost.withCA) (
                lib.mapCartesianProduct
                  (
                    { reportPreName, reportPostName }:
                    let
                      name = reportPreName + "-" + reportPostName;
                    in
                    {
                      inherit name;
                      value = pkgs.callPackage ./mkDiff.nix {
                        name = "diff-${name}";
                        reportPre = config.reports.${reportPreName};
                        reportPost = config.reports.${reportPostName};
                      };
                    }
                  )
                  {
                    reportPreName = reportNames;
                    reportPostName = reportNames;
                  }
              )
            );
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
