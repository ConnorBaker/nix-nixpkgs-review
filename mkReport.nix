{
  # config
  name,
  nixpkgs,
  evalSystem,
  withCA,
  withCUDA,
  # Nix file (or directory) whose expression maps { withCA, withCUDA } to the arguments (other than `system`) to import
  # Nixpkgs with; defaults to ./configs and ./overlays.
  nixpkgsArgs ? null,
  # Whether `nix` has the `fingerprint-derivations` setting (see ./patches/nix) and should use it: the reports' derivation
  # paths are then fingerprints, which are only good for comparing with reports made the same way.
  fingerprintDerivations ? false,

  # callPackage arguments
  pkgsBuildHost,
  jq,
  lib,
  nix,
  runCommand,
  time,
}:
runCommand name
  {
    __structuredAttrs = true;
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
  # NOTE: Parallel evaluation is GC-bound, and the evaluated package set stays reachable until the end, so collecting
  # buys little: for x86_64-linux with CUDA (~98k derivations, 16 eval cores, Determinate Nix 3.23.0) GC_DONT_GC=1 took
  # 11.4s with a 26G peak and a 16G initial heap 12.5s with a 19G peak, but an 8G initial heap (below the ~14G live set)
  # took 252s. The uncollected garbage is never touched again, so under memory pressure it is swapped out cheaply (e.g.,
  # to zram, which compressed it ~4.5:1).
  ''
    nixLog "running eval"
    ${lib.getExe pkgsBuildHost.time} --verbose \
      env \
      GC_DONT_GC=1 \
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
      --eval-cores 0${lib.optionalString fingerprintDerivations " --option fingerprint-derivations true"} \
      --expr \
        '
        let
          pkgs = import ${nixpkgs.outPath} (
            {
              system = "${evalSystem}";
            }
            // ${
              if nixpkgsArgs != null then
                "import ${nixpkgsArgs}"
              else
                "(args: { config = import ${./configs} args; overlays = import ${./overlays} { inherit (args) withCA; }; })"
            } {
              withCA = ${builtins.toJSON withCA};
              withCUDA = ${builtins.toJSON withCUDA};
            }
          );
        in
        import ${./mkNestedReport.nix} pkgs
        ' | \
    jq --compact-output \
      '. as $in | [paths(type == "string")] | map(. as $p | {key: ($p | join(".")), value: {drvPath: ($in | getpath($p)), attrPath: $p}}) | from_entries' \
      > "$out"

    nixLog "computed $(jq 'length' < "$out") derivations"
  ''
