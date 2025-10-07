{
  # config
  name,
  nixpkgs,
  withCA,
  withCUDA,

  # callPackage arguments
  jq,
  lib,
  nix,
  runCommandNoCC,
  stdenv,
}:
runCommandNoCC name
  {
    __structuredAttr = true;
    strictDeps = true;

    nativeBuildInputs = [
      jq
      nix
    ];

    passthru = {
      inherit nixpkgs withCA withCUDA;
    };
  }
  # TODO: Really we want ALL the inputs required to eval nixpkgs, not just the nixpkgs repo
  # NOTE: Using `--impure` allows us to read in the Nix expressions as bind-mounted in the store, without copying them
  # to a temporary store.
  ''
    nixLog "running eval"
    nix eval \
      --show-trace \
      --verbose \
      --offline \
      --store dummy:// \
      --read-only \
      --json \
      --impure \
      --no-eval-cache \
      --no-allow-import-from-derivation \
      --no-fsync-metadata \
      --lazy-trees \
      --extra-experimental-features ca-derivations \
      --extra-experimental-features parallel-eval \
      --eval-cores 0 \
      --expr \
        '
        let
          pkgs = import ${nixpkgs.outPath} {
            system = "${stdenv.buildPlatform.system}";
            config = import ${./mkConfig.nix} {
              withCA = ${builtins.toJSON withCA};
              withCUDA = ${builtins.toJSON withCUDA};
            };
            overlays = [ ${lib.optionalString withCA "(import ${./ca-overlay.nix})"} ];
          };
          inherit (import ${./lib.nix} { inherit (pkgs) lib; }) mkNestedReport;
        in
        mkNestedReport pkgs
        ' | \
    jq --compact-output '[.. | select(.drvPath?) | {(.attrPath | join(".")): .}] | add' > "$out"
    nixLog "done!"
  ''
