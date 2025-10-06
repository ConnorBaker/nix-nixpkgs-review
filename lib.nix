{ lib }:
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
    mapAttrs
    tryEval
    ;

  inherit (lib)
    isDerivation
    mergeAttrsList
    min
    showAttrPath
    zipListsWith
    ;

  tryEval' = expr: (tryEval (deepSeq expr expr)).value;

  zipListsWith3 =
    f: fst: snd: trd:
    genList (n: f (elemAt fst n) (elemAt snd n) (elemAt trd n)) (
      min (length fst) (min (length snd) (length trd))
    );

  /**
    Creates a report from a derivation given the attribute path prefix, attribute name, and derivation.

    NOTE: Return value is designed to be the same whether evaluated directory or via `(tryEval (deepSeq ...)).value`.
  */
  unsafeMkValueReport =
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
        # outputs = genAttrs (drv.outputs or [ "out" ]) (output: drv.${output}.outPath);
        outputs = drv.outputs or [ "out" ];
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

  mkReport =
    let
      go =
        prefix: cursor:
        let
          # All of these are arrays
          names = attrNames cursor;
          values = attrValues cursor;
          # TODO: Try to use parallel, that's why this is factored out and we're not using a let...in with zipListsWith
          maybeReports = zipListsWith (
            name: value: tryEval' (unsafeMkValueReport prefix name value)
          ) names values;
        in
        mergeAttrsList (
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
        );
    in
    go [ ];

  mkNestedReport =
    let
      go =
        prefix:
        mapAttrs (
          name: value:
          let
            maybeReport = tryEval' (unsafeMkValueReport prefix name value);
          in
          # Case where maybeReport is a report
          if isAttrs maybeReport then
            maybeReport
          # Case where maybeReport is true, recurse
          else if maybeReport then
            go (prefix ++ [ name ]) value
          # Case where maybeReport is false, ignore
          else
            null
        );
    in
    go [ ];

  diffReports =
    pre: post:
    let
      commonNames = attrNames (intersectAttrs pre post);
    in
    {
      added = attrNames (removeAttrs post commonNames);
      removed = attrNames (removeAttrs pre commonNames);
      changed = filter (name: pre.${name}.drvPath != post.${name}.drvPath) commonNames;
    };
in
{
  inherit mkReport mkNestedReport diffReports;
}
