{
  # config
  name,
  nixpkgs,
  withCA,
  withCUDA,

  # callPackage arguments
  lib,
  nix,
  runCommandNoCC,
  stdenv,
  time,
}:
runCommandNoCC name
  {
    __structuredAttr = true;
    strictDeps = true;

    nativeBuildInputs = [
      time
      nix
    ];

    passthru = {
      inherit nixpkgs withCA withCUDA;
    };
  }
  # TODO: Really we want ALL the inputs required to eval nixpkgs, not just the nixpkgs repo
  # error: operation 'addToStore' is not supported by store 'dummy://'
  # nixpkgs = builtins.getFlake "path://${nixpkgs.outPath}?narHash=${nixpkgs.narHash}";
  # booooo, impure is required or else we have to use builtins.getFlake and pass in the narHash so it's locked
  # and then that copies it to the local store.
  # TODO: Maybe I should do eval in the ramdisk? So fetch everything using pure mode and builtins.getFlake?
  # FIXME: As my linux builders are configured, /tmp is backed by ZFS.
  # TODO: Soooo much IO.
  # TODO: Lazy trees doesn't help at all.
  ''
    ${lib.getExe time} -v nix eval \
      --show-trace \
      --verbose \
      --store dummy:// \
      --eval-store "$TMPDIR" \
      --json \
      --impure \
      --lazy-trees \
      --extra-experimental-features ca-derivations \
      --extra-experimental-features parallel-eval \
      --eval-cores 0 \
      --expr \
      '
      let
        pkgs = import ${nixpkgs.outPath} {
          system = "${stdenv.buildPlatform.system}";
          config = import ${./mkConfig.nix} ${builtins.toJSON withCUDA};
          overlays = [ ${lib.optionalString withCA "(import ${./ca-overlay.nix})"} ];
        };
        inherit (import ${./lib.nix} { inherit (pkgs) lib; }) mkReport;
      in
      mkReport pkgs
      ' > $out
  ''
