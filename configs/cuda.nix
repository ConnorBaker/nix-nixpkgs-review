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
