# The arguments (other than `system`) Nixpkgs is imported with.
{ withCA, withCUDA }:
{
  config = {
    # Aliases print evaluation warnings.
    allowAliases = false;
    allowBroken = false;
    allowUnfree = false;
    checkMeta = true;
  }
  // (if withCA then { contentAddressedByDefault = true; } else { })
  // (
    if withCUDA then
      {
        cudaSupport = true;
        cudaCapabilities = [ "8.9" ];
        # Written out, rather than `pkgs._cuda.lib.allowUnfreeCudaPredicate`, which not every revision has.
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
            # A compound license (e.g. `lib.licenses.AND [ ... ]`) has no `free` attribute.
            license: license.free or false || builtins.elem (license.shortName or null) cudaLicenseShortNames
          ) (if builtins.isList package.meta.license then package.meta.license else [ package.meta.license ]);
      }
    else
      { }
  );

  overlays = [
    # What nixpkgs-review leaves out:
    # https://github.com/Mic92/nixpkgs-review/blob/31380da91b8f6be2b2e30f42047e2a3ebb68e024/nixpkgs_review/nix.py#L206-L219
    (final: prev: {
      appimage-run-tests = null;
      darwin = prev.darwin // {
        builder = null;
        linux-builder = null;
      };
      nixos-install-tools = null;
      tests = final.lib.recursiveUpdate prev.tests {
        nixos-functions.nixos-test = null;
        nixos-functions.nixosTest-test = null;
        php.overrideAttrs-preserves-enabled-extensions = null;
        php.withExtensions-enables-previously-disabled-extensions = null;
        pkg-config.defaultPkgConfigPackages.tests-combined = null;
        # Configured with allowUnsupportedSystems, so never to be recursed into.
        pkg-config.recurseForDerivations = false;
        trivial = null;
        writers = null;
      };
    })
  ];
}
