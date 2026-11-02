# The diff of two reports (see mkNestedReport.nix), as mkDiff.nix's output: the attribute paths of the derivations
# added, changed and removed, each sorted, and whether tests were compared. Used by mkDiff.nix.
#
# Run with --null-input and:
#   --slurpfile pre / --slurpfile post: the packages reports;
#   --slurpfile testsPre / --slurpfile testsPost: the tests reports (files containing null when not compared);
#   --argjson testsCompared: whether to union the tests reports with the packages reports.

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
