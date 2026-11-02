{
  # config
  name,
  # The packages reports to compare (see mkReport.nix).
  reportPre,
  reportPost,
  # Optional: the tests reports for the same Nixpkgs (mkReport.nix's `reportKind = "tests"`), both or neither.
  testsPre ? null,
  testsPost ? null,
  # Whether to fail, with the tests reports' errors, if a tests report didn't evaluate, rather than compare only packages.
  requireTests ? false,

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
assert lib.assertMsg (
  requireTests -> testsPre != null
) "mkDiff.nix: requireTests needs testsPre and testsPost";
runCommand name
  {
    __structuredAttrs = true;
    strictDeps = true;

    nativeBuildInputs = [ jq ];

    tests = lib.optionals (testsPre != null) [
      "${testsPre}"
      "${testsPost}"
    ];

    testsErrors = lib.optionals requireTests [
      "${testsPre.error}"
      "${testsPost.error}"
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
        if (( ''${#testsErrors[@]} > 0 )); then
          # The full errors first, then a summary (the attribute path and the last error line of each), which is what
          # the end of the log, as Nix shows it, has room for.
          jq --raw-output 'select(. != null) | .error' "''${testsErrors[@]}" >&2
          nixErrorLog "a tests report didn't evaluate (to skip a test, add its attribute path to skip.nix):"
          jq --raw-output '
            select(. != null)
            | "  \(.attrPath // ["?"] | join(".")): \(.error | split("\n") | map(select(test("^ *error: "))) | last // "?" | sub("^ +"; ""))"
          ' "''${testsErrors[@]}" >&2
          exit 1
        fi
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
      --from-file ${./diff.jq} \
      > $out
  ''
