{
  jq,
  nestedReport,
  runCommandNoCC,
}:
runCommandNoCC "unnestReport"
  {
    __structuredAttr = true;
    strictDeps = true;
    nativeBuildInputs = [ jq ];
  }
  ''
    jq \
      --compact-output \
      '[.. | select(.drvPath?) | {(.attrPath | join(".")): .}] | add' \
      < ${nestedReport} > $out
  ''
