# The Nix expression (as a string) for what a report evaluates in a tree (see mkReport.nix for the arguments): Nixpkgs,
# imported for `evalSystem` with `nixpkgsArgs`, or a `file` in the tree, called with `args`; then `attrPath` selected.
# mkReport.nix walks it to make a report, and mkJobs.nix selects what changed from it, so they evaluate the same thing.
{
  lib,
  nixpkgs,
  evalSystem,
  withCA,
  withCUDA,
  nixpkgsArgs ? null,
  file ? null,
  args ? { },
  attrPath ? [ ],
}:
''
  let
    root = ${
      if file == null then
        ''
          import ${nixpkgs} (
            {
              system = "${evalSystem}";
            }
            // ${
              # Each of these is copied to the store on its own, so it can't refer to files outside it.
              if nixpkgsArgs != null then
                "import ${nixpkgsArgs}"
              else
                "(args: { config = import ${./configs} args; overlays = import ${./overlays}; })"
            } {
              withCA = ${builtins.toJSON withCA};
              withCUDA = ${builtins.toJSON withCUDA};
            }
          )''
      else
        "autoCall (import ${nixpkgs}/${file})"
    };

    autoArgs = builtins.fromJSON ${lib.strings.escapeNixString (builtins.toJSON args)};

    # As `nix-build` and nix-eval-jobs call a file's function: with the arguments it takes.
    autoCall =
      f:
      if builtins.isFunction f && builtins.functionArgs f != { } then
        f (builtins.intersectAttrs (builtins.functionArgs f) autoArgs)
      else
        f;

    attrPath = builtins.fromJSON ${lib.strings.escapeNixString (builtins.toJSON attrPath)};
  in
  autoCall (builtins.foldl' (value: name: (autoCall value).''${name}) root attrPath)
''
