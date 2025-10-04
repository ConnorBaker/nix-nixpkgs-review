{ inputs, ... }:
{
  imports = [
    inputs.treefmt-nix.flakeModule
    inputs.git-hooks-nix.flakeModule
  ];

  perSystem =
    {
      config,
      pkgs,
      ...
    }:
    {
      pre-commit.settings.hooks = {
        # Formatter checks
        treefmt = {
          enable = true;
          package = config.treefmt.build.wrapper;
        };

        # Nix checks
        deadnix.enable = true;
        nil.enable = true;
        statix.enable = true;
      };

      treefmt = {
        projectRootFile = "flake.nix";
        programs = {
          # Markdown
          mdformat.enable = true;

          # Nix
          nixfmt = {
            enable = true;
            package = pkgs.nixfmt-rfc-style;
          };

          # Shell
          shellcheck.enable = true;
          shfmt.enable = true;
        };
      };
    };
}
