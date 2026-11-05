{
  # config
  name,
  # The packages reports to compare (see mkReport.nix).
  reportPre,
  reportPost,
  # Optional: the tests reports of the same trees (mkReport.nix's `reportKind = "tests"`), both or neither.
  testsPre ? null,
  testsPost ? null,

  # callPackage arguments
  jq,
  lib,
  runCommand,
}:
# The attribute paths (e.g. [ "python3Packages" "torch" ] or [ "hello" "passthru" "tests" "version" ]) of the derivations
# added, changed, removed, broken and fixed between two trees (see ./diff.jq), each sorted:
# { added = [ ... ]; changed = [ ... ]; removed = [ ... ]; broken = [ ... ]; fixed = [ ... ]; }.
#
# A tree's tests report is compared along with its packages report: a test's attribute path is its path in the tree,
# so tests are diffed like any other derivation.
assert lib.assertMsg (
  (testsPre == null) == (testsPost == null)
) "mkDiff.nix: give both testsPre and testsPost, or neither";
runCommand name
  {
    __structuredAttrs = true;
    strictDeps = true;

    nativeBuildInputs = [ jq ];

    reportsPre = [ reportPre ] ++ lib.optional (testsPre != null) testsPre;
    reportsPost = [ reportPost ] ++ lib.optional (testsPost != null) testsPost;

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
    jq \
      --compact-output \
      --null-input \
      --slurpfile pre <(cat "''${reportsPre[@]}") \
      --slurpfile post <(cat "''${reportsPost[@]}") \
      --from-file ${./diff.jq} \
      > "$out"
  ''
