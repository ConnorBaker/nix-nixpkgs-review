{
  description = "nix-nixpkgs-review";

  inputs = {
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    # The evaluator the reports use: a Nix evaluator in Rust. A branch of a fork with fixes not yet merged upstream:
    # numtide/iets#354 (call `__functor` sets, as Nix does) and numtide/iets#355 (an intermittent abort at exit, which
    # fails a report). Switch back to numtide/iets once both are in.
    iets.url = "github:ConnorBaker/iets/nix-nixpkgs-review";

    # Just use whatever iets has pinned, which it's tested with.
    nixpkgs.follows = "iets/nixpkgs";
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

      perSystem =
        { config, pkgs, ... }:
        {
          packages = {
            default = config.packages.nnr;

            # What changed between two revisions of a git repository: builds `lib.mkReview`.
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

      # What changed between two trees of a git repository (see review.nix); `packages.nnr` resolves the revisions.
      flake.lib.mkReview = import ./review.nix { inherit (inputs) iets nixpkgs; };

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
