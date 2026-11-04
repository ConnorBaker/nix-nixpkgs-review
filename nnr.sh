# shellcheck shell=bash
# nnr: what changed between two trees of a git repository. Resolves the revisions, then builds the flake's
# `lib.mkReview` (mkJobs.nix for mkDiff.nix over mkReport.nix's reports) and prints the jobs' store path. See README.md.

usage() {
  cat >&2 <<'EOF'
usage: nnr [REPO] [options]

Prints the store path of a Nix expression for the derivations added or changed between two trees of the git
repository REPO (default: .): HEAD^ and HEAD, or --base and --head, or with --uncommitted, HEAD (or --base) and the
working tree. Evaluate it with e.g. nix-eval-jobs --expr "import $(nnr)". The path also has changed.json, the
attribute paths as a JSON list of lists.

  --base REV            the revision to compare against (default: HEAD^, or HEAD with --uncommitted)
  --head REV            the revision to compare (default: HEAD)
  -u, --uncommitted     compare the working tree instead of --head (tracked files as they are, and staged new files)
  -t, --tests           also compare passthru.tests

Entry point (default: Nixpkgs, if the tree has pkgs/top-level/all-packages.nix, and otherwise default.nix):
  -f, --file FILE       a Nix file in the tree (relative to its root)
  -A, --attr PATH       an attribute path to select (dot-separated)
  --arg NAME EXPR       pass a value to the file's function (JSON-like values and paths only)
  --argstr NAME STRING  pass a string to the file's function
  --force-recurse       recurse into every attribute set, not just those with recurseForDerivations
  --system SYSTEM       for Nixpkgs: the system to evaluate for (default: this one)
  --cuda, --ca          for Nixpkgs: with cudaSupport or contentAddressedByDefault (see configs/)
EOF
  exit 2
}

repo=
base=
head=
uncommitted=false
# mkReview's arguments, as JSON (all but `args`' --arg values, which are Nix expressions).
request='{"args": {}}'
argExprs=
set_request() { # PATH VALUE (JSON)
  request=$(jq --compact-output --argjson value "$2" "$1 = \$value" <<<"$request")
}
# need N "$@": prints the usage unless the option being parsed and its values are N arguments (or more).
need() {
  (($# > $1)) || usage
}
jsonString() {
  jq --null-input --arg v "$1" '$v'
}

while (($# > 0)); do
  case "$1" in
  --base) need 2 "$@" && base=$2 && shift ;;
  --head) need 2 "$@" && head=$2 && shift ;;
  -u | --uncommitted) uncommitted=true ;;
  -t | --tests) set_request .tests true ;;
  -f | --file) need 2 "$@" && set_request .file "$(jsonString "$2")" && shift ;;
  -A | --attr) need 2 "$@" && set_request .attr "$(jsonString "$2")" && shift ;;
  --arg)
    need 3 "$@"
    argExprs+=" $(jq --null-input --raw-output --arg name "$2" '$name | tojson') = ($3);"
    shift 2
    ;;
  --argstr)
    need 3 "$@"
    request=$(jq --compact-output --arg name "$2" --arg value "$3" '.args[$name] = $value' <<<"$request")
    shift 2
    ;;
  --force-recurse) set_request .forceRecurse true ;;
  --system) need 2 "$@" && set_request .evalSystem "$(jsonString "$2")" && shift ;;
  --cuda) set_request .withCUDA true ;;
  --ca) set_request .withCA true ;;
  -*) usage ;;
  *)
    [[ -z $repo ]] || usage
    repo=$1
    ;;
  esac
  shift
done

if [[ $uncommitted == true && -n $head ]]; then
  echo "nnr: --uncommitted and --head are mutually exclusive" >&2
  exit 2
fi

repo=$(git -C "${repo:-.}" rev-parse --show-toplevel)
commit() {
  git -C "$repo" rev-parse --verify --end-of-options "$1^{commit}"
}

if [[ $uncommitted == true ]]; then
  base=$(commit "${base:-HEAD}")
  headLabel="the working tree"
else
  base=$(commit "${base:-HEAD^}")
  head=$(commit "${head:-HEAD}")
  set_request .head "$(jsonString "$head")"
  headLabel=${head:0:12}
fi
set_request .repo "$(jsonString "$repo")"
set_request .base "$(jsonString "$base")"
echo "nnr: comparing ${base:0:12} with $headLabel" >&2

# --max-jobs 1: each report evaluates on every core and takes tens of GB of memory, so build them one at a time.
jobs=$(
  nix build --impure --no-link --print-out-paths --max-jobs 1 \
    --expr '
      { request, argExprs }:
      let
        r = builtins.fromJSON request;
      in
      (builtins.getFlake "@flake@").lib.mkReview (r // { args = r.args // argExprs; })
    ' \
    --argstr request "$request" \
    --arg argExprs "{$argExprs }"
)

jq --raw-output '
  "nnr: \(.added + .changed + (.fixed // []) | length) added or changed"
  + (if (.broken // []) != [] then ", \(.broken | length) broken (no longer evaluate): \(.broken | map(join(".")) | .[:10] | join(" "))\(if (.broken | length) > 10 then " ..." else "" end)" else "" end)
' "$jobs/diff.json" >&2
echo "$jobs"
