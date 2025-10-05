{
  description = "nixpkgs-review";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";

    nixpkgs-pre.url = "github:ConnorBaker/nixpkgs/0ad7a9f5a5629b51e19d96ff5c4663b66caa4d55";
    nixpkgs.url = "github:ConnorBaker/nixpkgs/07198d07e7fb692191dd4fa1f284f7ceb9ba5c62";
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.flake-parts.flakeModules.partitions
        ./flake-module.nix
      ];

      systems = [
        "aarch64-linux"
        "x86_64-linux"
        "riscv64-linux"

        "x86_64-darwin"
        "aarch64-darwin"
      ];

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
