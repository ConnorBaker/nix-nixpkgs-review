# shellcheck shell=bash
# nnr: what changed between two trees of a git repository. Resolves the revisions, then builds the flake's
# `lib.mkReview` (mkDiff.nix over mkReport.nix's reports) and prints the diff. See README.md.

usage() {
  cat >&2 <<'EOF'
usage: nnr [REPO] [options]

Prints the attribute paths of the derivations added, changed and removed between two trees of the git repository
REPO (default: .): HEAD^ and HEAD, or --base and --head, or with --uncommitted, HEAD (or --base) and the working tree.

  --base REV            the revision to compare against (default: HEAD^, or HEAD with --uncommitted)
  --head REV            the revision to compare (default: HEAD)
  -u, --uncommitted     compare the working tree instead of --head (tracked files as they are, and staged new files)
  -t, --tests           also compare passthru.tests; fails if they don't evaluate
  --json                print the diff as JSON (mkDiff.nix's output)

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

repo=.
base=
head=
uncommitted=false
json=false
reviewArgs=()
argstrs='{}'
argExprs=
while (($# > 0)); do
  case "$1" in
  --base) base=$2 && shift ;;
  --head) head=$2 && shift ;;
  -u | --uncommitted) uncommitted=true ;;
  -t | --tests) reviewArgs+=(--arg tests true) ;;
  --json) json=true ;;
  -f | --file) reviewArgs+=(--argstr file "$2") && shift ;;
  -A | --attr) reviewArgs+=(--argstr attr "$2") && shift ;;
  --arg) argExprs+=" $(jq --null-input --raw-output --arg name "$2" '$name | tojson') = ($3);" && shift 2 ;;
  --argstr) argstrs=$(jq --compact-output --arg name "$2" --arg value "$3" '.[$name] = $value' <<<"$argstrs") && shift 2 ;;
  --force-recurse) reviewArgs+=(--arg forceRecurse true) ;;
  --system) reviewArgs+=(--argstr evalSystem "$2") && shift ;;
  --cuda) reviewArgs+=(--arg withCUDA true) ;;
  --ca) reviewArgs+=(--arg withCA true) ;;
  -*) usage ;;
  *) repo=$1 ;;
  esac
  shift
done

if [[ $uncommitted == true && -n $head ]]; then
  echo "nnr: --uncommitted and --head are mutually exclusive" >&2
  exit 2
fi

repo=$(git -C "$repo" rev-parse --show-toplevel)
commit() {
  git -C "$repo" rev-parse --verify --end-of-options "$1^{commit}"
}

if [[ $uncommitted == true ]]; then
  base=$(commit "${base:-HEAD}")
  headLabel="the working tree"
else
  base=$(commit "${base:-HEAD^}")
  head=$(commit "${head:-HEAD}")
  reviewArgs+=(--argstr head "$head")
  headLabel=${head:0:12}
fi
echo "nnr: comparing ${base:0:12} with $headLabel" >&2

# --max-jobs 1: each report evaluates on every core and takes tens of GB of memory, so build them one at a time.
diff=$(
  nix build --impure --no-link --print-out-paths --max-jobs 1 \
    --expr '(builtins.getFlake "@flake@").lib.mkReview' \
    --argstr repo "$repo" \
    --argstr base "$base" \
    --argstr argstrs "$argstrs" \
    --arg argExprs "{$argExprs }" \
    "${reviewArgs[@]}"
)

if [[ $json == true ]]; then
  cat "$diff"
  echo
  exit 0
fi

jq --raw-output '
  def nixName:
    if test("^[A-Za-z_][A-Za-z0-9_'"'"'-]*$")
      and (IN("assert", "else", "if", "in", "inherit", "let", "or", "rec", "then", "with") | not)
    then . else tojson end;
  ("added", "changed", "removed") as $kind
  | "\(.[$kind] | length) \($kind):", (.[$kind][] | "  " + (map(nixName) | join(".")))
' "$diff"
