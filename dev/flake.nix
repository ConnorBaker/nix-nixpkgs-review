{
  description = "Private inputs for development purposes. These are used by the top level flake in the `dev` partition, but do not appear in consumers' lock files.";

  # For more on `inputs.nixpkgs.follows = "";`, see:
  # https://github.com/ursi/get-flake/issues/4
  inputs = {
    # NOTE: Specifying no nixpkgs here means we use whatever is defined at the top level.

    git-hooks-nix = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "";
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "";
    };
  };

  # This flake is only used for its inputs.
  outputs = _: { };
}
