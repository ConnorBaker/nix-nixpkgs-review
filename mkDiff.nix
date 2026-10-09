{
  # config
  name,
  reportPre,
  reportPost,

  # callPackage arguments
  jq,
  runCommand,
}:
# The attribute paths (e.g. [ "python3Packages" "torch" ]) of the derivations added, changed, or removed between two
# reports (see mkReport.nix), each sorted: { added = [ ... ]; changed = [ ... ]; removed = [ ... ]; }.
runCommand name
  {
    __structuredAttrs = true;
    strictDeps = true;

    nativeBuildInputs = [ jq ];

    passthru = {
      inherit reportPre reportPost;
    };
  }
  ''
    jq \
      --compact-output \
      --null-input \
      --slurpfile pre ${reportPre} \
      --slurpfile post ${reportPost} \
      '
        # The (relative) attribute paths of the derivations in (part of) a report.
        def leaves:
          if type == "string" then
            []
          elif type == "object" then
            to_entries[] | .key as $k | .value | leaves | [$k] + .
          else
            empty
          end;

        # Walks both reports at once, yielding {added: path}, {changed: path} or {removed: path} for each difference.
        def diff($pre; $post; $path):
          if ($pre | type) == "object" and ($post | type) == "object" then
            (($pre | keys_unsorted) + ($post | keys_unsorted) | unique[]) as $k | diff($pre[$k]; $post[$k]; $path + [$k])
          elif ($pre | type) == "string" and ($post | type) == "string" then
            if $pre == $post then empty else {changed: $path} end
          else
            ($pre | leaves | {removed: ($path + .)}), ($post | leaves | {added: ($path + .)})
          end;

        [diff($pre[0]; $post[0]; [])]
        | {
            added: (map(.added // empty) | sort),
            changed: (map(.changed // empty) | sort),
            removed: (map(.removed // empty) | sort)
          }
      ' > $out
  ''
