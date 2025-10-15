{
  # config
  name,
  nixpkgs,
  evalSystem,
  withCA,
  withCUDA,

  # callPackage arguments
  pkgsBuildHost,
  jq,
  lib,
  nix,
  runCommandNoCC,
  time,
}:
runCommandNoCC name
  {
    __structuredAttr = true;
    strictDeps = true;

    nativeBuildInputs = [
      jq
      nix
      time
    ];

    passthru = {
      inherit
        evalSystem
        nixpkgs
        withCA
        withCUDA
        ;
    };
  }
  # TODO: Really we want ALL the inputs required to eval nixpkgs, not just the nixpkgs repo
  # NOTE: Using `--impure` allows us to read in the Nix expressions as bind-mounted in the store, without copying them
  # to a temporary store.
  # Because of Nix's path semantics, ./configs and ./overlays create top-level store path entries with the contents
  # of those directories. As such, references within the directory are fine, but references which escape the directory
  # are not going to work.
  ''
    nixLog "running eval"
    ${lib.getExe pkgsBuildHost.time} --verbose \
      env \
      GC_INITIAL_HEAP_SIZE=32G \
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
            system = "${evalSystem}";
            config = import ${./configs} {
              withCA = ${builtins.toJSON withCA};
              withCUDA = ${builtins.toJSON withCUDA};
            };
            overlays = import ${./overlays} {
              withCA = ${builtins.toJSON withCA};
            };
          };
        in
        import ${./mkNestedReport.nix} pkgs
        ' | \
    jq --compact-output '[.. | select(.drvPath?) | {(.attrPath | join(".")): .}] | add' > "$out"

    nixLog "computed $(jq 'length' < "$out") derivations"
  ''
