{
  config,
  inputs,
  lib,
  ...
}:
let
  inherit (builtins)
    attrNames
    attrValues
    deepSeq
    elemAt
    filter
    genList
    intersectAttrs
    isAttrs
    length
    parallel
    tryEval
    ;

  inherit (lib)
    genAttrs
    isDerivation
    mergeAttrsList
    min
    showAttrPath
    zipListsWith
    ;

  withDup = f: a: f a a;

  zipListsWith3 =
    f: fst: snd: trd:
    genList (n: f (elemAt fst n) (elemAt snd n) (elemAt trd n)) (
      min (length fst) (min (length snd) (length trd))
    );

  /**
    Creates a report from a derivation given the attribute path prefix, attribute name, and derivation.

    NOTE: Return value is designed to be the same whether evaluated directory or via `(tryEval (deepSeq ...)).value`.
  */
  unsafeMkReport =
    let
      mkReport = prefix: name: drv: {
        inherit (drv)
          drvPath
          name
          system
          # meta
          ;

        attrPath = prefix ++ [ name ];

        ${if drv ? pname then "pname" else null} = drv.pname;
        ${if drv ? version then "version" else null} = drv.version;

        outputName = drv.outputName or "out";
        outputs = genAttrs (drv.outputs or [ "out" ]) (output: drv.${output}.outPath);
      };
    in
    prefix: name: value:
    # 1. value is an attribute set
    if isAttrs value then
      # 1a. value is a derivation, we want to return the report
      if isDerivation value then
        mkReport prefix name value
      # 1b. value is an attribute set but not a derivation, so either we want to recurse into it or we don't
      else
        value.recurseForDerivations or false
    # 2. value is not an attribute set, we want to ignore it, return false
    else
      false;

  mkReports =
    let
      go =
        prefix: cursor:
        let
          # All of these are arrays
          names = attrNames cursor;
          values = attrValues cursor;
          maybeReports = zipListsWith (
            name: value: (tryEval (withDup deepSeq (unsafeMkReport prefix name value))).value
          ) names values;
        in
        # NOTE: We cannot have parallel inside the go function because something deadlocks and the evaluator drops to 0% CPU usage.
        mergeAttrsList (
          parallel maybeReports (
            zipListsWith3 (
              name: value: maybeReport:
              # Case where maybeReport is a report
              if isAttrs maybeReport then
                { ${showAttrPath maybeReport.attrPath} = maybeReport; }
              # Case where maybeReport is true, recurse
              else if maybeReport then
                go (prefix ++ [ name ]) value
              # Case where maybeReport is false, ignore
              else
                { }
            ) names values maybeReports
          )
        );
    in
    go [ ];

  diffReports =
    old: new:
    let
      commonNames = attrNames (intersectAttrs old new);
      reports = {
        added = attrNames (removeAttrs new commonNames);
        removed = attrNames (removeAttrs old commonNames);
        changed = filter (name: old.${name}.drvPath != new.${name}.drvPath) commonNames;
      };
    in
    reports;
in
{
  # NOTE: Nix eval doesn't cache; only nix build and a few others do.
  flake.eval = genAttrs config.systems (
    system:
    let
      pkgs =
        import inputs.nixpkgs {
          inherit system;
          # NOTE: Nixpkgs allows aliases by default which prints a bunch of evaluation warnings.
          config.allowAliases = false;
        }
        # See: https://github.com/NixOS/nixpkgs/pull/447555
        // {
          tests = { };
        };
      pkgsReport = mkReports pkgs;
      pkgsUnfreeCuda =
        import inputs.nixpkgs {
          inherit system;
          config =
            # { pkgs }:
            # {
            #   # NOTE: Nixpkgs allows aliases by default which prints a bunch of evaluation warnings.
            #   allowAliases = false;
            #   # TODO: Doesn't work when `allowlistedLicenses`; but does work with `whitelistedLicenses`...
            #   whitelistedLicenses = [
            #     pkgs.lib.licenses.nvidiaCuda
            #     pkgs.lib.licenses.nvidiaCudaRedist
            #   ]
            #   ++ attrValues pkgs._cuda.lib.licenses;
            #   cudaSupport = true;
            # };
            {
              # NOTE: Nixpkgs allows aliases by default which prints a bunch of evaluation warnings.
              allowAliases = false;
              # TODO: Doesn't work when `allowlistedLicenses`; but does work with `whitelistedLicenses`...
              allowlistedLicenses = [
                pkgs.lib.licenses.nvidiaCuda
                pkgs.lib.licenses.nvidiaCudaRedist
              ]
              ++ attrValues pkgs._cuda.lib.licenses;
              cudaSupport = true;
            };
        }
        # See: https://github.com/NixOS/nixpkgs/pull/447555
        // {
          tests = { };
        };
      pkgsUnfreeCudaReport = mkReports pkgsUnfreeCuda;
    in
    {
      cudaPackagesReport = mkReports {
        inherit (pkgsUnfreeCuda) cudaPackages;
        recurseForDerivations = true;
      };
      inherit pkgsReport pkgsUnfreeCudaReport;
      cudaDiff = diffReports (lib.importJSON ./pkgsReport.json) (lib.importJSON ./pkgsUnfreeCudaReport.json);
    }
  );
}
