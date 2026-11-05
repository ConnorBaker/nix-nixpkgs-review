# The diff of two trees' reports (see review.nix). Run with --null-input and --slurpfile pre / --slurpfile post, each the
# lines of one tree's report.
#
# Yields the attribute paths, each sorted, of the derivations
#   added:   that are jobs in post and weren't there in pre;
#   changed: that are jobs in both, with different outputs;
#   removed: that were jobs in pre and aren't there in post;
#   broken:  that were jobs in pre and fail to evaluate in post;
#   fixed:   that failed to evaluate in pre and are jobs in post.
# An attribute that fails to evaluate in both, or is new and fails, isn't reported: it's not something to build.

def index: map({key: (.attrPath | tojson), value: .}) | from_entries;

($pre | index) as $pre
| ($post | index) as $post
| [($pre + $post) | keys[]] as $keys
| [
    $keys[] as $k
    | $pre[$k] as $a
    | $post[$k] as $b
    | if $a == null then
        (if $b.outputs then {added: $b.attrPath} else empty end)
      elif $b == null then
        (if $a.outputs then {removed: $a.attrPath} else empty end)
      elif $a.outputs and $b.outputs then
        (if $a.outputs == $b.outputs then empty else {changed: $b.attrPath} end)
      elif $a.outputs then
        {broken: $a.attrPath}
      elif $b.outputs then
        {fixed: $b.attrPath}
      else
        empty
      end
  ]
| {
    added: (map(.added // empty) | sort),
    changed: (map(.changed // empty) | sort),
    removed: (map(.removed // empty) | sort),
    broken: (map(.broken // empty) | sort),
    fixed: (map(.fixed // empty) | sort)
  }
