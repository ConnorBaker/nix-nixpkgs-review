let
  inherit (builtins)
    deepSeq
    isAttrs
    mapAttrs
    tryEval
    ;

  tryEval' = expr: (tryEval (deepSeq expr expr)).value;

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

        # NOTE: Originally, outputs was declared as:
        # outputs = genAttrs (drv.outputs or [ "out" ]) (output: drv.${output}.outPath);
        # However, that doesn't make sense for content-addressed derivations. Instead, we just record the outputs;
        # it's enough to note whether the derivation path changed.
        outputs = drv.outputs or [ "out" ];
      };
    in
    prefix: name: value:
    # 1. value is an attribute set
    if isAttrs value then
      # 1a. value is a derivation, we want to return the report
      # NOTE: This is an implementation detail; used here to avoid importing `lib`.
      if value.type or null == "derivation" then
        mkReport prefix name value
      # 1b. value is an attribute set but not a derivation, so either we want to recurse into it or we don't
      else
        value.recurseForDerivations or false
    # 2. value is not an attribute set, we want to ignore it, return false
    else
      false;

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
in
mkNestedReport
