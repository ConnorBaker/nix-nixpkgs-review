{ withCA, withCUDA }:
{
  # NOTE: Nixpkgs allows aliases by default which prints a bunch of evaluation warnings.
  allowAliases = false;
  allowBroken = false;
  allowUnfree = false;
  checkMeta = true;
  contentAddressedByDefault = withCA;
  packageOverrides = pkgs: {
    # Something about bootstrapping requires that we do this here rather than in ca-overlay.nix.
    ${if withCA then "git" else null} = pkgs.git.override { doInstallCheck = false; };

    # TODO: Something about the parallel evaluator dies when it has to process
    # tests.trivial-builders.writeStringReferencesToFile:
    # error: path '/nix/store/38gk6xb0lbyyckqs5lmdmrfdzcsw6mgg-hi.drv' does not exist and cannot be created
    # TODO: `tests.pkg-config` creates insane derivations (tries to build cuda_compat on x86_64-linux) because it
    # sets `allowUnsupportedSystem`.
    tests = { };
  };
}
// (
  if withCUDA then
    {
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
        builtins.all (
          license: license.free || builtins.elem (license.shortName or null) cudaLicenseShortNames
        ) (if builtins.isList package.meta.license then package.meta.license else [ package.meta.license ]);
    }
  else
    { }
)
