"""nnr: what changed between two trees of a git repository, as attribute paths of derivations.

Evaluates an entry point (by default, Nixpkgs, or a tree's default.nix) at two revisions of a git repository, or at a
revision and the working tree, and prints the attribute paths of the derivations added, changed and removed between
them, like nixpkgs-review, for any tree and entry point, like nix-eval-jobs. See README.md.

Run through the flake's `nnr` package, which sets NNR_SRC (this repository's Nix files) and NNR_NIX (the Nix to
evaluate with).
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

NNR_SRC = os.environ.get("NNR_SRC") or str(Path(__file__).resolve().parent)
NNR_NIX = os.environ.get("NNR_NIX")

# Bumped when the expression below changes in a way that changes reports, so cached reports aren't reused.
CACHE_VERSION = 1

# The expression a report is the JSON of. Its parameters come from a JSON file (so they needn't be escaped as Nix);
# only the user's Nix code (--expr, --arg) is spliced in, as `@expr@` and `@args@`.
EXPR = r"""
let
  params = builtins.fromJSON (builtins.readFile @params@);
  nnr = /. + params.nnrSrc;

  tree = builtins.fetchGit (
    { url = params.url; submodules = params.submodules; }
    // (if params.rev == null then { } else { rev = params.rev; allRefs = true; })
  );

  autoArgs = builtins.mapAttrs (_: builtins.toString) params.argstrs // @args@;

  # Like Nix's --file and nix-eval-jobs: a function taking an attribute set is called with the --arg and --argstr
  # arguments it takes.
  autoCall = f:
    if builtins.isFunction f && builtins.functionArgs f != { } then
      f (builtins.intersectAttrs (builtins.functionArgs f) autoArgs)
    else
      f;

  root =
    if params.entry == "nixpkgs" then
      import tree (
        { system = params.system; }
        // {
          config = import (nnr + "/configs") { inherit (params) withCA withCUDA; };
          overlays = import (nnr + "/overlays") { inherit (params) withCA; };
        }
      )
    else if params.entry == "file" then
      autoCall (import (tree + "/${params.file}"))
    else
      autoCall ((@expr@) tree);

  value = autoCall (builtins.foldl' (v: name: (autoCall v).${name}) root params.attrPath);

  # Adds an attribute path (found while evaluating; see nnr.py) to a skip tree.
  addSkip = set: path:
    if set == true || path == [ ] then
      true
    else
      set // { ${builtins.head path} = addSkip (set.${builtins.head path} or { }) (builtins.tail path); };
in
import (nnr + "/mkNestedReport.nix") {
  kind = params.kind;
  skip = builtins.foldl' addSkip (if params.skip == null then { } else import (/. + params.skip)) params.extraSkips;
  forceRecurse = params.forceRecurse;
} value
"""


def log(msg):
    print(f"nnr: {msg}", file=sys.stderr, flush=True)


def die(msg):
    log(f"error: {msg}")
    sys.exit(1)


def git(repo, *args, env=None, check=True):
    result = subprocess.run(
        ["git", "-C", repo, *args],
        capture_output=True,
        text=True,
        env=env,
    )
    if check and result.returncode != 0:
        die(f"git {' '.join(args)}: {result.stderr.strip()}")
    return result.stdout.strip()


class Tree:
    """A revision of the repository, or its working tree (rev None)."""

    def __init__(self, repo, spec):
        self.repo = repo
        self.spec = spec
        if spec is None:
            self.rev = None
            self.id = working_tree_id(repo)
            self.label = "the working tree"
        else:
            self.rev = git(repo, "rev-parse", "--verify", "--end-of-options", f"{spec}^{{commit}}")
            self.id = self.rev
            self.label = f"{spec} ({self.rev[:12]})"


def working_tree_id(repo):
    """An ID for the working tree as fetchGit sees it (tracked files as they are on disk, and staged new files): the
    git tree it would be, built in a temporary index so the real one isn't touched."""
    git_dir = git(repo, "rev-parse", "--absolute-git-dir")
    with tempfile.TemporaryDirectory() as tmp:
        index = Path(tmp) / "index"
        real_index = Path(git_dir) / "index"
        if real_index.exists():
            shutil.copyfile(real_index, index)
        env = {**os.environ, "GIT_INDEX_FILE": str(index)}
        git(repo, "add", "--update", env=env)
        tree = git(repo, "write-tree", env=env)
    head = git(repo, "rev-parse", "--verify", "HEAD", check=False) or "none"
    return f"{head}+{tree}"


def nix_has_fingerprints(nix):
    result = subprocess.run(
        [nix, "config", "show", "fingerprint-derivations"],
        capture_output=True,
        text=True,
        env=nix_env(),
    )
    return result.returncode == 0


_nix_conf_dir = None


def nix_env():
    """The environment to run Nix in: without the user's or the system's nix.conf, so that their stores (e.g. an
    eval-store) and plugins (built for another Nix) aren't used. Everything needed is passed as options."""
    global _nix_conf_dir
    if _nix_conf_dir is None:
        _nix_conf_dir = tempfile.mkdtemp(prefix="nnr-nix-conf-")
        (Path(_nix_conf_dir) / "nix.conf").write_text("")
    env = {k: v for k, v in os.environ.items() if k != "NIX_CONFIG"}
    env["NIX_CONF_DIR"] = _nix_conf_dir
    env["NIX_USER_CONF_FILES"] = str(Path(_nix_conf_dir) / "nix.conf")
    # Reports never collect garbage (see mkReport.nix).
    env["GC_DONT_GC"] = "1"
    return env


def trace_attr_path(log_text):
    """The attribute path at the start of the trace (outermost first), as mkReport.nix's traceAttrPath: the
    attributes of the report Nix was printing when the error happened. None if there is none."""
    lines = log_text.splitlines()
    for start, line in enumerate(lines):
        if line.startswith("error:"):
            break
    else:
        return None
    path = []
    for line in lines[start:]:
        if re.match(r"^ *… ", line):
            m = re.match(r"^ *… while evaluating attribute '([^']*)'$", line)
            if not m:
                break
            path.append(m.group(1))
    return path or None


class EvalFailure(Exception):
    """A tests report failed to evaluate: the attribute path it was evaluating (None if unknown) and the error."""

    def __init__(self, attr_path, error, log_text):
        super().__init__(error)
        self.attr_path = attr_path
        self.error = error
        self.log_text = log_text


def evaluate(args, tree, kind, nix, fingerprints, cache_dir, extra_skips=()):
    """The report (a path to its JSON) for a tree, from the cache if it's there. A tests report that fails to evaluate
    raises EvalFailure; a packages report that does exits."""
    params = {
        "nnrSrc": NNR_SRC,
        "url": "file://" + args.repo,
        "submodules": args.submodules,
        "rev": tree.rev,
        "entry": args.entry,
        "file": args.file,
        "attrPath": args.attr.split(".") if args.attr else [],
        "argstrs": dict(args.argstr),
        "system": args.system,
        "withCA": args.ca,
        "withCUDA": args.cuda,
        "kind": kind,
        "skip": skip_file(args, kind),
        "extraSkips": sorted(list(p) for p in extra_skips),
        "forceRecurse": args.force_recurse,
    }
    nix_args = "{ " + " ".join(f"{json.dumps(name)} = ({value});" for name, value in args.arg) + " }"
    user_expr = args.expr or "null"

    key_material = {
        "version": CACHE_VERSION,
        "tree": tree.id,
        "params": {k: v for k, v in params.items() if k not in ("url", "rev")},
        "args": nix_args,
        "expr": user_expr,
        "skipContents": file_digest(params["skip"]),
        "nix": nix,
        "fingerprints": fingerprints,
    }
    key = hashlib.sha256(json.dumps(key_material, sort_keys=True).encode()).hexdigest()
    cached = cache_dir / f"{key}.json" if cache_dir else None
    failure = cached.with_suffix(".failure.json") if cached else None
    if cached and cached.exists():
        log(f"{kind} report for {tree.label}: cached ({cached})")
        return cached
    if failure and failure.exists():
        f = json.loads(failure.read_text())
        raise EvalFailure(f["attrPath"], f["error"], f["log"])

    work = Path(tempfile.mkdtemp(prefix="nnr-"))
    params_file = work / "params.json"
    params_file.write_text(json.dumps(params))
    expr = EXPR.replace("@params@", str(params_file)).replace("@args@", nix_args).replace("@expr@", user_expr)

    cmd = [
        nix,
        "eval",
        "--json",
        "--impure",
        "--store",
        "dummy://",
        "--eval-store",
        "dummy://",
        "--read-only",
        "--no-eval-cache",
        "--no-allow-import-from-derivation",
        "--no-fsync-metadata",
        "--lazy-trees",
        "--show-trace",
        "--extra-experimental-features",
        "nix-command flakes fetch-tree ca-derivations parallel-eval",
        "--eval-cores",
        str(args.eval_cores),
    ]
    if fingerprints:
        cmd += ["--option", "fingerprint-derivations", "true"]
    cmd += ["--expr", expr]

    log(f"evaluating the {kind} report for {tree.label}")
    started = time.monotonic()
    out_file = work / "report.json"
    with open(out_file, "w") as out:
        result = subprocess.run(cmd, stdout=out, stderr=subprocess.PIPE, text=True, env=nix_env())
    elapsed = time.monotonic() - started

    if result.returncode != 0:
        if kind != "tests":
            sys.stderr.write(result.stderr)
            die(f"evaluating the {kind} report for {tree.label} failed")
        errors = [line.strip() for line in result.stderr.splitlines() if re.match(r"^ *error: ", line)]
        attr_path = trace_attr_path(result.stderr)
        error = errors[-1] if errors else "?"
        if failure:
            cache_dir.mkdir(parents=True, exist_ok=True)
            failure.write_text(json.dumps({"attrPath": attr_path, "error": error, "log": result.stderr}))
        raise EvalFailure(attr_path, error, result.stderr)
    if args.verbose:
        sys.stderr.write(result.stderr)

    count = out_file.read_text().count('"fingerprint":')
    log(f"{kind} report for {tree.label}: {count} derivations in {elapsed:.1f}s")

    if cached:
        cache_dir.mkdir(parents=True, exist_ok=True)
        tmp = cached.with_suffix(".tmp")
        shutil.copyfile(out_file, tmp)
        tmp.rename(cached)
        out_file = cached
    return out_file


def evaluate_tests(args, trees, nix, fingerprints, cache_dir):
    """The tests reports for the trees, or None for each if they can't be evaluated, and the attribute paths that had to
    be skipped. A test can fail to evaluate in a way tryEval can't catch, failing the whole report; like find-skips,
    this skips the attribute path it failed at and evaluates again. Every tree's report skips the same paths, so a test
    skipped in only one can't show up as added or removed."""
    skips = set()
    done = {}
    while True:
        pending = [tree for tree in trees if done.get(tree, (None,))[0] != frozenset(skips)]
        if not pending:
            return {tree: done[tree][1] for tree in trees}, skips
        tree = pending[0]
        try:
            done[tree] = (frozenset(skips), evaluate(args, tree, "tests", nix, fingerprints, cache_dir, skips))
        except EvalFailure as e:
            path = tuple(e.attr_path) if e.attr_path else None
            if path is None or path in skips or len(skips) >= args.max_skips:
                reason = (
                    "the trace doesn't start with an attribute path"
                    if path is None
                    else f"skipping {nix_attr_path(path)} didn't help"
                    if path in skips
                    else f"already skipped {len(skips)} (see --max-skips)"
                )
                log(f"the tests of {tree.label} failed to evaluate ({reason}), so only packages are compared:")
                log(f"  {e.error}")
                if args.verbose:
                    sys.stderr.write(e.log_text)
                return {tree: None for tree in trees}, skips
            log(f"skipping {nix_attr_path(path)}, which failed to evaluate: {e.error}")
            skips.add(path)


def skip_file(args, kind):
    if args.skip:
        return str(Path(args.skip).resolve())
    if kind == "tests" and args.entry == "nixpkgs":
        return str(Path(NNR_SRC) / "skip.nix")
    return None


def file_digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest() if path else None


NIX_KEYWORDS = {"assert", "else", "if", "in", "inherit", "let", "or", "rec", "then", "with"}


def nix_attr_path(path):
    return ".".join(
        name if re.match(r"^[A-Za-z_][A-Za-z0-9_'-]*$", name) and name not in NIX_KEYWORDS else json.dumps(name)
        for name in path
    )


def diff(pre, post, tests_pre, tests_post):
    compared = tests_pre is not None and tests_post is not None
    with tempfile.TemporaryDirectory() as tmp:
        null = Path(tmp) / "null.json"
        null.write_text("null\n")
        result = subprocess.run(
            [
                "jq",
                "--compact-output",
                "--null-input",
                "--slurpfile",
                "pre",
                str(pre),
                "--slurpfile",
                "post",
                str(post),
                "--slurpfile",
                "testsPre",
                str(tests_pre if compared else null),
                "--slurpfile",
                "testsPost",
                str(tests_post if compared else null),
                "--argjson",
                "testsCompared",
                json.dumps(compared),
                "--from-file",
                str(Path(NNR_SRC) / "diff.jq"),
            ],
            capture_output=True,
            text=True,
        )
    if result.returncode != 0:
        die(f"diffing the reports failed: {result.stderr.strip()}")
    return json.loads(result.stdout)


def parse_args(argv):
    parser = argparse.ArgumentParser(
        prog="nnr",
        description="Print the attribute paths of the derivations added, changed and removed between two revisions "
        "of a git repository (by default HEAD^ and HEAD), or a revision and the working tree (--uncommitted).",
    )
    parser.add_argument("repo", nargs="?", default=".", help="a path in the git repository (default: .)")

    revs = parser.add_argument_group("what to compare")
    revs.add_argument("--base", metavar="REV", help="the revision to compare against (default: HEAD^, or HEAD with --uncommitted)")
    revs.add_argument("--head", metavar="REV", help="the revision to compare (default: HEAD)")
    revs.add_argument(
        "-u",
        "--uncommitted",
        action="store_true",
        help="compare the working tree (tracked files as they are, and staged new files, as flakes see a dirty tree) "
        "instead of --head",
    )
    revs.add_argument("--submodules", action="store_true", help="include submodules in the trees")

    entry = parser.add_argument_group(
        "entry point",
        "What to evaluate in each tree. By default, Nixpkgs (if the tree has pkgs/top-level/all-packages.nix), "
        "configured as the flake's reports are (see --system, --cuda, --ca), and otherwise --file default.nix.",
    )
    entry_kind = entry.add_mutually_exclusive_group()
    entry_kind.add_argument("-f", "--file", help="a Nix file, relative to the repository's root")
    entry_kind.add_argument("-E", "--expr", help="a Nix function from the tree (as builtins.fetchGit returns it, so usable as a path) to what to evaluate, e.g. 'src: (import src { }).pkgsCross.aarch64-multiplatform'")
    entry.add_argument("-A", "--attr", help="an attribute path (separated by dots) to select")
    entry.add_argument("--arg", nargs=2, action="append", default=[], metavar=("NAME", "EXPR"), help="pass a Nix value to a function")
    entry.add_argument("--argstr", nargs=2, action="append", default=[], metavar=("NAME", "STRING"), help="pass a string to a function")
    entry.add_argument(
        "--force-recurse",
        action="store_true",
        help="recurse into every attribute set, not just those with recurseForDerivations (e.g. for a Hydra jobset)",
    )
    entry.add_argument("--system", help="for Nixpkgs: the system to evaluate for (default: this one)")
    entry.add_argument("--cuda", action="store_true", help="for Nixpkgs: with cudaSupport (see configs/cuda.nix)")
    entry.add_argument("--ca", action="store_true", help="for Nixpkgs: with contentAddressedByDefault (see configs/ca.nix)")

    tests = parser.add_argument_group("tests")
    tests.add_argument("-t", "--tests", action="store_true", help="also compare each derivation's passthru.tests")
    tests.add_argument(
        "--skip",
        metavar="FILE",
        help="a Nix file with what not to evaluate, nested like the report (see skip.nix, the default for Nixpkgs' tests)",
    )
    tests.add_argument(
        "--max-skips",
        type=int,
        default=50,
        help="how many tests that fail to evaluate to skip before giving up on comparing tests (default: 50)",
    )

    output = parser.add_argument_group("output and evaluation")
    output.add_argument("--json", action="store_true", help="print the diff as JSON (as mkDiff.nix's output)")
    output.add_argument("--nix", help="the Nix to evaluate with (a path to its bin/nix, or a directory with bin/nix); it must be a Determinate Nix")
    output.add_argument("--eval-cores", type=int, default=0, help="evaluator threads (default: 0, one per core)")
    output.add_argument("--no-cache", action="store_true", help="don't read or write cached reports")
    output.add_argument("-v", "--verbose", action="store_true", help="show Nix's output")

    args = parser.parse_args(argv)
    if args.uncommitted and args.head:
        parser.error("--uncommitted and --head are mutually exclusive")
    return args


def main(argv=None):
    args = parse_args(argv)

    repo = git(args.repo, "rev-parse", "--show-toplevel")
    args.repo = repo

    if args.expr:
        args.entry = "expr"
    elif args.file:
        args.entry = "file"
    elif (Path(repo) / "pkgs/top-level/all-packages.nix").exists():
        args.entry = "nixpkgs"
    else:
        args.entry = "file"
        args.file = "default.nix"

    if args.entry != "nixpkgs" and (args.cuda or args.ca or args.system):
        die("--system, --cuda and --ca are for the Nixpkgs entry point; use --arg/--argstr (or --expr) instead")

    nix = args.nix or NNR_NIX or shutil.which("nix")
    if nix and Path(nix).is_dir():
        nix = str(Path(nix) / "bin" / "nix")
    if not nix:
        die("no Nix to evaluate with: pass --nix")
    nix = str(Path(nix).resolve())
    fingerprints = nix_has_fingerprints(nix)

    if args.system is None:
        args.system = subprocess.run(
            [nix, "eval", "--raw", "--impure", "--expr", "builtins.currentSystem"],
            capture_output=True,
            text=True,
            check=True,
            env=nix_env(),
        ).stdout.strip()

    head = Tree(repo, None) if args.uncommitted else Tree(repo, args.head or "HEAD")
    base = Tree(repo, args.base or ("HEAD" if args.uncommitted else "HEAD^"))

    entry = {
        "nixpkgs": f"Nixpkgs for {args.system}" + (" with CUDA" if args.cuda else "") + (" with CA" if args.ca else ""),
        "file": args.file,
        "expr": "--expr",
    }[args.entry] + (f", attribute {args.attr}" if args.attr else "")
    log(f"comparing {base.label} with {head.label}: {entry}")
    if not fingerprints:
        log(f"{nix} doesn't have fingerprint-derivations (see patches/nix); computing real output paths")

    cache_root = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "nix-nixpkgs-review" / "reports"
    cache_dir = None if args.no_cache else cache_root

    reports = {}
    for tree in (base, head):
        reports[tree] = evaluate(args, tree, "packages", nix, fingerprints, cache_dir)
    tests = {tree: None for tree in (base, head)}
    skips = set()
    if args.tests:
        tests, skips = evaluate_tests(args, (base, head), nix, fingerprints, cache_dir)

    result = diff(reports[base], reports[head], tests[base], tests[head])

    if skips:
        log(f"skipped {len(skips)} test(s) that failed to evaluate; to skip them up front, add to a skip file (--skip):")
        for path in sorted(skips):
            log(f"  {nix_attr_path(path)} = true;")

    if args.json:
        print(json.dumps(result))
        return

    for kind in ("added", "changed", "removed"):
        paths = result[kind]
        print(f"{len(paths)} {kind}:")
        for path in paths:
            print(f"  {nix_attr_path(path)}")
    if args.tests and not result["testsCompared"]:
        print("(tests weren't compared: a tests report didn't evaluate)")


if __name__ == "__main__":
    main()
