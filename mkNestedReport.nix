let
  inherit (builtins)
    deepSeq
    isAttrs
    isString
    mapAttrs
    tryEval
    ;

  tryEval' = expr: (tryEval (deepSeq expr expr)).value;

  /**
    Creates a report from a value: the derivation path for a derivation, `true` if the value should be recursed into,
    and `false` otherwise.

    The derivation path is all we record: whether it changed is enough to know whether the derivation changed, and the
    attribute path is given by where it is in the (nested) result. Keeping the result small keeps printing it cheap.

    NOTE: Return value is designed to be the same whether evaluated directly or via `(tryEval (deepSeq ...)).value`.
  */
  unsafeMkValueReport =
    value:
    # 1. value is an attribute set
    if isAttrs value then
      # 1a. value is a derivation, we want to return the report
      # NOTE: This is an implementation detail; used here to avoid importing `lib`.
      if value.type or null == "derivation" then
        value.drvPath
      # 1b. value is an attribute set but not a derivation, so either we want to recurse into it or we don't
      else
        value.recurseForDerivations or false
    # 2. value is not an attribute set, we want to ignore it, return false
    else
      false;

  mkNestedReport = mapAttrs (
    _: value:
    let
      maybeReport = tryEval' (unsafeMkValueReport value);
    in
    # Case where maybeReport is a report
    if isString maybeReport then
      maybeReport
    # Case where maybeReport is true, recurse
    else if maybeReport then
      mkNestedReport value
    # Case where maybeReport is false, ignore
    else
      null
  );
in
mkNestedReport
