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

    nixpkgs-pre.url = "github:ConnorBaker/nixpkgs/0ad7a9f5a5629b51e19d96ff5c4663b66caa4d55";
    nixpkgs-post.url = "github:ConnorBaker/nixpkgs/07198d07e7fb692191dd4fa1f284f7ceb9ba5c62";
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
        summaries.adHoc = true;
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
          inherit (lib) optionalString;
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
            "pkgs" + optionalString withCA "-ca" + optionalString withCUDA "-cuda" + "-${when}";
        in
        {
          # NOTE: Building the reports is super IO heavy due to all the drv creation; make sure build-dir is backed by TMPFS:
          # nix build -L .#review-pkgs-pre-pkgs-post --build-dir /run/temp-ramdisk --builders ''
          # TODO: switch to using tmpfs-backed build dir for builders.
          packages = lib.mapAttrs' (
            name: summary:
            let
              inherit (summary.diff) reportPre reportPost;
              name' = "review-${name}";
            in
            {
              name = name';
              # NOTE: Must use the read-only-local-store feature because the store is... well, read-only and inside a Nix store path.
              value = pkgs.writeShellScriptBin name' ''
                echo "copying derivations from ${reportPre.name}"
                nix copy \
                  --extra-experimental-features read-only-local-store \
                  --all \
                  --from "${reportPre.evalStore.outPath}?read-only=true"

                echo "copying derivations from ${reportPost.name}"
                nix copy \
                  --extra-experimental-features read-only-local-store \
                  --all \
                  --from "${reportPost.evalStore.outPath}?read-only=true"

                echo "building added and changed derivations"
                ${lib.getExe pkgs.jq} \
                  --raw-output \
                  '(.diff.added + .diff.changed)[] as $name | .post[$name].drvPath + "^*"' \
                  < ${summary} | \
                nix build --keep-going --stdin
              '';
            }

          ) config.summaries;

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
                  config = import ./mkConfig.nix withCUDA;
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

          summaries = lib.mapAttrs (
            _: diff:
            pkgs.callPackage ./mkSummary.nix {
              name = "summary-" + lib.removePrefix "diff-" diff.name;
              inherit diff;
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
