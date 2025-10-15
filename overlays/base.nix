final: prev:
# These are all paths which `nixpkgs-review` blocks:
# https://github.com/Mic92/nixpkgs-review/blob/31380da91b8f6be2b2e30f42047e2a3ebb68e024/nixpkgs_review/nix.py#L206-L219
{
  appimage-run-tests = null;
  darwin = prev.darwin // {
    builder = null;
    linux-builder = null; # NOTE: darwin.builder is just an alias to darwin.linux-builder now
  };
  nixos-install-tools = null;
  tests = final.lib.recursiveUpdate prev.tests {
    nixos-functions.nixos-test = null;
    nixos-functions.nixosTest-test = null;
    php.overrideAttrs-preserves-enabled-extensions = null;
    php.withExtensions-enables-previously-disabled-extensions = null;
    pkg-config.defaultPkgConfigPackages.tests-combined = null;
    # NOTE: pkg-config.defaultPkgConfigPackages is configured with allowUnsupportedSystems, so we should never recurse into it
    pkg-config.recurseForDerivations = false;
    trivial = null;
    writers = null;
  };
}
