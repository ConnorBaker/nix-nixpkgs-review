{
  config,
  inputs,
  lib,
  ...
}:
let
  mkNixpkgs =
    system: nixpkgs: withCuda:
    removeAttrs
      (import nixpkgs {
        inherit system;

        config =
          { pkgs }:
          {
            # NOTE: Nixpkgs allows aliases by default which prints a bunch of evaluation warnings.
            allowAliases = false;
            allowBroken = false;
            allowUnfree = true;
            checkMeta = true;
            contentAddressedByDefault = true;
          }
          // lib.optionalAttrs withCuda {
            cudaSupport = true;
            cudaCapabilities = [ "8.9" ];
            # NOTE: Can't use `allowlistedLicenses` because the package set depends on it.
            # NOTE: Need to vendor and write out the licenses because it's not available or working in all Nixpkgs
            # revisions.
            # allowUnfreePredicate = pkgs._cuda.lib.allowUnfreeCudaPredicate;
            allowUnfreePredicate =
              let
                cudaLicenseShortNames = [
                  "CUDA EULA"
                  "cuDNN EULA"
                  "cuSPARSELt EULA"
                  "cuTENSOR EULA"
                  "NVIDIA Math SDK SLA"
                  "TensorRT EULA"
                ];
              in
              package:
              lib.all (license: license.free || lib.elem (license.shortName or null) cudaLicenseShortNames) (
                lib.toList package.meta.license
              );
          };

        overlays = [ (import ./ca-overlay.nix) ];
      })
      # See: https://github.com/NixOS/nixpkgs/pull/447555
      [ "tests" ];
in
{
  flake.lib = import ./lib.nix { inherit lib; };

  # NOTE: Nix eval doesn't cache; only nix build and a few others do.
  flake.eval =
    let
      inherit (lib) genAttrs;
      inherit (inputs.self.lib) mkReports diffReports;
    in
    genAttrs config.systems (system: {
      # TODO: Diff in-place as well -- i.e., what changes in Nixpkgs when we enable CUDA support?

      # nix eval .#eval.x86_64-linux.pkgs --json > pkgs.json
      # jq -r '(.diff.added + .diff.changed)[] as $name | .post[$name].drvPath + "^*"' < pkgs.json | nix build --keep-going --stdin
      pkgs =
        let
          pre = mkReports (mkNixpkgs system inputs.nixpkgs-pre false);
          post = mkReports (mkNixpkgs system inputs.nixpkgs false);
          diff = diffReports pre post;
        in
        {
          inherit diff pre post;
        };

      # nix eval .#eval.x86_64-linux.cuda --json > cuda.json
      # jq -r '(.diff.added + .diff.changed)[] as $name | .post[$name].drvPath + "^*"' < cuda.json | nix build --keep-going --stdin
      cuda =
        let
          pre = mkReports (mkNixpkgs system inputs.nixpkgs-pre true);
          post = mkReports (mkNixpkgs system inputs.nixpkgs true);
          diff = diffReports pre post;
        in
        {
          inherit diff pre post;
        };
    });
}
