{
  # config
  name,
  diff,

  # callPackage arguments
  jq,
  runCommandNoCC,
}:
runCommandNoCC name
  {
    __structuredAttr = true;
    strictDeps = true;

    nativeBuildInputs = [ jq ];

    passthru = {
      inherit diff;
    };
  }
  ''
    jq \
      --sort-keys \
      --compact-output \
      --null-input \
      --slurpfile pre ${diff.passthru.reportPre} \
      --slurpfile post ${diff.passthru.reportPost} \
      --slurpfile diff ${diff} \
      '{diff: $diff[0], post: $post[0], pre: $pre[0]}' \
      > $out
  ''
