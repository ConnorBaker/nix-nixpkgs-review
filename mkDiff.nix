{
  # config
  name,
  # The packages reports to compare (see mkReport.nix).
  reportPre,
  reportPost,
  # Optional: the tests reports for the same Nixpkgs (mkReport.nix's `reportKind = "tests"`), both or neither.
  testsPre ? null,
  testsPost ? null,

  # callPackage arguments
  jq,
  lib,
  runCommand,
}:
# The attribute paths (e.g. [ "python3Packages" "torch" ] or [ "hello" "passthru" "tests" "version" ]) of the derivations
# added, changed, or removed between two reports (see mkReport.nix), each sorted, and whether tests were compared:
# { added = [ ... ]; changed = [ ... ]; removed = [ ... ]; testsCompared = <bool>; }.
#
# With tests reports, each is unioned with its packages report first: each derivation in the packages report gets its
# `passthru.tests` from the tests report, so tests are diffed like any other derivation. (Tests of derivations the
# packages report doesn't have, e.g. because they failed to evaluate, are left out, as they'd be if the reports were
# one.) Tests are compared only if both tests reports evaluated (see mkReport.nix's `error` output); otherwise, only
# packages are, since a missing tests report isn't evidence the tests were removed.
assert lib.assertMsg (
  (testsPre == null) == (testsPost == null)
) "mkDiff.nix: give both testsPre and testsPost, or neither";
runCommand name
  {
    __structuredAttrs = true;
    strictDeps = true;

    nativeBuildInputs = [ jq ];

    tests = lib.optionals (testsPre != null) [
      "${testsPre}"
      "${testsPost}"
    ];

    passthru = {
      inherit
        reportPre
        reportPost
        testsPre
        testsPost
        ;
    };
  }
  ''
    # Tests are compared if both tests reports evaluated; a tests report that didn't is just `null`.
    compared=false
    testsPre=null.json
    testsPost=null.json
    echo null > null.json
    if (( ''${#tests[@]} > 0 )); then
      if [[ "$(head -c 4 "''${tests[0]}")" == null || "$(head -c 4 "''${tests[1]}")" == null ]]; then
        nixLog "a tests report didn't evaluate (see its error output), so only packages are compared"
      else
        compared=true
        testsPre=''${tests[0]}
        testsPost=''${tests[1]}
      fi
    fi

    jq \
      --compact-output \
      --null-input \
      --slurpfile pre ${reportPre} \
      --slurpfile post ${reportPost} \
      --slurpfile testsPre "$testsPre" \
      --slurpfile testsPost "$testsPost" \
      --argjson testsCompared "$compared" \
      '
        # A derivation is an object with a string fingerprint (its output path, or a fingerprint of it); its other
        # attributes (e.g. passthru.tests) are its children.
        def isDrv: type == "object" and (.fingerprint | type) == "string";

        # Reports from before derivations were objects recorded them as strings; diffing those would silently find
        # nothing.
        def checkFormat:
          if type == "string" then
            error("expected a derivation to be an object with a fingerprint, found a string: was this report made by an older mkNestedReport.nix?")
          else
            .
          end;

        # The (relative) attribute paths of the derivations in (part of) a report.
        def leaves:
          checkFormat
          | if isDrv then
              [], (del(.fingerprint) | leaves)
            elif type == "object" then
              to_entries[] | .key as $k | .value | leaves | [$k] + .
            else
              empty
            end;

        # Walks both reports at once, yielding {added: path}, {changed: path} or {removed: path} for each difference.
        # Two derivations are compared by fingerprint, and then their children are walked like attribute sets.
        def diff($pre; $post; $path):
          ($pre | checkFormat) as $pre
          | ($post | checkFormat) as $post
          | if ($pre | isDrv) and ($post | isDrv) then
              (if $pre.fingerprint == $post.fingerprint then empty else {changed: $path} end),
              diff($pre | del(.fingerprint); $post | del(.fingerprint); $path)
            elif ($pre | type) == "object" and ($post | type) == "object" and ($pre | isDrv | not) and ($post | isDrv | not) then
              (($pre | keys_unsorted) + ($post | keys_unsorted) | unique[]) as $k | diff($pre[$k]; $post[$k]; $path + [$k])
            else
              ($pre | leaves | {removed: ($path + .)}), ($post | leaves | {added: ($path + .)})
            end;

        # A packages report, with the tests of each of its derivations from a tests report.
        def union($packages; $tests):
          if ($packages | isDrv) then
            if ($tests | type) == "object" then $packages + $tests else $packages end
          elif ($packages | type) == "object" then
            $packages | with_entries(.key as $k | .value = union(.value; ($tests | if type == "object" then .[$k] else null end)))
          else
            $packages
          end;

        (if $testsCompared then union($pre[0]; $testsPre[0]) else $pre[0] end) as $pre
        | (if $testsCompared then union($post[0]; $testsPost[0]) else $post[0] end) as $post
        | [diff($pre; $post; [])]
        | {
            added: (map(.added // empty) | sort),
            changed: (map(.changed // empty) | sort),
            removed: (map(.removed // empty) | sort),
            $testsCompared
          }
      ' > $out
  ''
