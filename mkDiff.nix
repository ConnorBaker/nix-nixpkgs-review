{
  # config
  name,
  reportPre,
  reportPost,

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
      inherit reportPre reportPost;
    };
  }
  ''
    jq \
      --sort-keys \
      --compact-output \
      --null-input \
      --slurpfile pre ${reportPre} \
      --slurpfile post ${reportPost} \
      '
        $pre[0] as $pre |
        $post[0] as $post |
        reduce (($pre | keys_unsorted) + ($post | keys_unsorted) | unique)[] as $key (
          {added: [], changed: [], removed: []};
          if ($pre | has($key)) then
            if ($post | has($key)) then
              if $pre[$key].drvPath != $post[$key].drvPath then
                .changed += [$key]
              else . end
            else
              .removed += [$key]
            end
          else
            .added += [$key]
          end
        ) | {
          added: (.added | sort),
          changed: (.changed | sort),
          removed: (.removed | sort)
        }
      ' > $out
  ''
