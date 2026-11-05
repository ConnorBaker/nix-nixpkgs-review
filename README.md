# nix-nixpkgs-review

Find out which derivations a change to a git repository (usually Nixpkgs) adds, changes, removes or breaks, by
evaluating the tree before and after with [iets](https://github.com/numtide/iets)' `eval-jobs` and comparing the
results. It doesn't instantiate or build anything to do so. What it produces is a Nix expression for exactly what
changed, to evaluate with nix-eval-jobs or a Hydra jobset and build.

```bash
# HEAD^ against HEAD, in a Nixpkgs checkout; evaluate exactly what changed:
nix-eval-jobs --expr "import $(nix run github:ConnorBaker/nix-nixpkgs-review -- .)"

# HEAD against the working tree (uncommitted changes), with passthru.tests:
nix run github:ConnorBaker/nix-nixpkgs-review -- . --uncommitted --tests

# Any two revisions, with CUDA:
nix run github:ConnorBaker/nix-nixpkgs-review -- . --base origin/master --head my-branch --cuda

# Another repository's entry point:
nix run github:ConnorBaker/nix-nixpkgs-review -- . -f release.nix -A jobs --argstr system x86_64-linux --force-recurse
```

`nnr` prints how many jobs there are and which broke, then the store path of the jobs (see [Jobs](#jobs)).

## Files

- [`nnr.sh`](./nnr.sh) is the command line (`packages.nnr`, the flake's default package). It resolves the revisions
  with git, turns its options into `lib.mkReview`'s arguments, and builds that.
- [`review.nix`](./review.nix) is `lib.mkReview`: it reads each tree with `builtins.fetchGit`, and makes their
  reports and the jobs with `lib.nix`.
- [`lib.nix`](./lib.nix) has the derivations, for a caller with the trees as paths: `mkReport` makes a tree's
  [report](#reports) by running `iets eval-jobs`, and `mkJobs` makes the [jobs](#jobs) from two reports. It's called
  with `callPackage` and an iets build; `hydraJobs.iets.<system>` is the flake's.
- [`eval/root.nix`](./eval/root.nix) is what a report evaluates, from its settings (passed as JSON): Nixpkgs, configured
  by [`eval/nixpkgs.nix`](./eval/nixpkgs.nix) (or the caller's `nixpkgsArgs` file), or a file in the tree, called with
  `args`; then `attrPath` selected. With `tests`, it adds the tree's `passthru.tests`, as
  [`eval/tests.nix`](./eval/tests.nix) gathers them.
- [`diff.jq`](./diff.jq) compares two reports.
- [`eval/jobs.nix`](./eval/jobs.nix) becomes the jobs' `default.nix`.

Nothing here is a stable interface. Its other user is the [nixos-cuda](https://github.com/nixos-cuda) Hydra's pull
request jobset (`jobsets/nixpkgs-pr.nix` in nixos-cuda/hydra-jobsets), which calls `lib.nix` with the `tools`
jobset's build of `hydraJobs.iets`, as a `build` input, and its own `nixpkgsArgs`, so that the reports evaluate Nixpkgs
as release-lib does for its jobs.

## Reports

A tree's report is every job `eval-jobs` finds in it, as nix-eval-jobs and Hydra walk it: attribute sets with
`recurseForDerivations` (or all of them, with `--force-recurse`) are recursed into, and functions are called with the
arguments they have defaults for. It's one JSON line per attribute path, sorted, with a derivation's outputs, or the
error the attribute failed to evaluate with:

```json
{"attrPath":["hello"],"outputs":{"out":"/nix/store/nsq63r5qzvvlhhpmi5sa9hvs86j6mr8n-hello-2.12.3"}}
{"attrPath":["hello","passthru","tests","version"],"outputs":{"out":"/nix/store/…-hello-test-version"}}
{"attrPath":["zoom-us"],"error":"Refusing to evaluate package 'zoom-7.2.1.5760' in /nix/store/kc3dkdhlx5hz6mf3wg3szbnjrgbbrmyj-source/pkgs/by-name/zo/zoom-us/package.nix:138 because it has an unfree license (‘unfree’)"}
```

- The error is its last `error:` line. Most are Nixpkgs refusing a package that has problems, is unfree, isn't
  available on the platform or is insecure.
- Output paths, not derivation paths, are compared. Derivation paths also change when only how a source is fetched
  changes (e.g., a fixed-output derivation's URL or fetcher), while output paths depend on fixed-output derivations only
  through their content hashes.
- eval-jobs evaluates each attribute on its own, so an error of any kind (not just what `tryEval` catches: a missing
  attribute, calling a function with an argument it doesn't take, `abort`) is only that attribute's. Only a fatal error
  (e.g. a stack overflow) fails a report.
- A report depends only on its tree and settings (it's named after the commit, e.g. `report-e58dcdca81f2`), so a
  commit's report is built once and reused by every comparison with it, until garbage-collected.

### Tests

With `--tests`, the same evaluation also walks each derivation's `passthru.tests`, as jobs whose attribute paths are
their paths in the tree (`hello.passthru.tests.version`):

- Attribute sets within `passthru.tests` are recursed into, up to `passthru.tests.a.b.c`.
- Only `passthru.tests` is looked at (the rest of `passthru` is full of dependencies and whole package sets), and a
  test's own `passthru.tests` isn't: tests are often overrides of the package, whose tests are more overrides.
- NixOS tests (`nixosTests.*`, which many packages list) are skipped: computing their output path evaluates a NixOS
  system per node.
- The Home Assistant component tests are skipped (`skip` in `eval/tests.nix`): each of the ~1,200 components lists all
  of them, so walking them made 1.4M test jobs instead of 10.6k. Each is still a test of `home-assistant`, as
  `home-assistant.passthru.tests.components.<component>`.

Nixpkgs' CI evaluates packages but not their tests, so tests that fail to evaluate aren't rare; they're errors like any
other.

### Cost

For Nixpkgs 344693dcf336 and e58dcdca81f2 (aarch64-linux, 8 workers, on a busy machine), with tests: 103,303 jobs and
21,668 errors (124,971 lines), in 14.4 s and 20.1 s, with a peak of 33.1 and 33.0 GB. Packages alone are 92,713 jobs and
20,081 errors with a peak of 18.8 GB.

Packages and tests are one evaluation, so the package set is evaluated once; as separate evaluations, they took 25 and
29 s, but peaked at 23.5 GB. Each report needs that memory, so `nnr` builds them one at a time (`--max-jobs 1`).

## Diffs

`diff.jq` lists the sorted attribute paths of the derivations added, changed, removed, broken and fixed between two
reports:

```json
{
  "added": [["foo"], ["hello", "passthru", "tests", "version"]],
  "changed": [["python3Packages", "torch"]],
  "removed": [],
  "broken": [["cowsay"]],
  "fixed": []
}
```

- **added**: jobs in the second tree that weren't there in the first;
- **changed**: jobs in both, with different outputs;
- **removed**: jobs in the first tree that aren't there in the second;
- **broken**: jobs in the first tree that fail to evaluate in the second;
- **fixed**: attributes that failed to evaluate in the first tree and are jobs in the second.

An attribute that fails in both, or is new and fails, isn't listed. A test's output path changes whenever anything it
depends on does, so this finds the tests of changed packages, tests in other packages' `passthru.tests` that depend on
them, and new tests.

## Jobs

What `nnr` prints, `lib.mkReview`'s result, is a directory:

- `default.nix`: an attribute set from each added, changed or fixed attribute path, joined with dots (e.g.
  `"python3Packages.torch"`, `"hello.passthru.tests.version"`), to its value in the second tree. It's flat, rather than
  nested, because a derivation can both be a job and contain jobs (`hello` and `hello.passthru.tests.version`), and
  nix-eval-jobs doesn't recurse into derivations; Hydra names nested jobs the same way. It evaluates in pure mode.
- `root.nix`, `nixpkgs.nix`, `tests.nix` and `settings.json`: what the second tree's report evaluated, so that each job
  is selected exactly as the report reached it, auto-calling functions along the way.
- `changed.json`: the attribute paths, as a JSON list of lists.
- `diff.json`: the diff, with what was removed and what broke.

For Nixpkgs e58dcdca81f2 against two commits before, with tests, that's 28,200 jobs.

## Options

- **What it compares:** `--base` (default `HEAD^`) and `--head` (default `HEAD`), or, with `--uncommitted`, `--base`
  (default `HEAD`) and the working tree, as `builtins.fetchGit` sees it (as a flake sees a dirty tree): tracked files as
  they are on disk, and new files only once staged (`git add -N` is enough).
- **What it evaluates:** Nixpkgs, if the tree has `pkgs/top-level/all-packages.nix`, configured by `eval/nixpkgs.nix`:
  `allowAliases = false`, `allowBroken = false`, `allowUnfree = false` and `checkMeta = true`; with `--cuda`,
  `cudaSupport = true`, `cudaCapabilities = [ "8.9" ]` and only NVIDIA's CUDA licenses allowed; with `--ca`,
  `contentAddressedByDefault = true`; and without the attributes `nixpkgs-review` skips (`tests.trivial`,
  `nixos-install-tools`, …). `--system` is the system to evaluate it for. Otherwise `default.nix`, or `-f`, called with
  `--arg` and `--argstr`. `-A` works for both, and `--force-recurse` only for a file (Nixpkgs would never finish:
  `pkgs.pkgs` is `pkgs`).
- **Limitations:** reports evaluate in a sandbox, without a store, so an entry point that fetches anything (e.g.
  `fetchTarball`, or flake inputs) or uses import-from-derivation fails. `--arg` values reach the evaluation as JSON,
  so they can only be JSON values or paths, e.g.
  `--arg nixpkgs 'builtins.fetchGit { url = "/path/to/nixpkgs"; rev = "…"; }'`. A function is called with `args` only
  if it takes an attribute set by name (`{ a, b }:`); `{ }:` and `x:` are left as they are.

## iets

[iets](https://github.com/numtide/iets) is a Nix evaluator in Rust. Reports use its `eval-jobs`
(`--no-instantiate --max-memory-size 0`): one process, whose worker threads share one evaluation, computing
derivation and output paths without a store. iets' own measurements (`docs/explanation/evaluation.md`, "Scaling
limits") stop improving at about 6 workers; reports use 8. It's checked against Nix:

- For Nixpkgs e58dcdca81f2 (aarch64-linux), `iets eval` of a walk of Nixpkgs recording each derivation's `outPath` gave
  output byte-identical to Determinate Nix's.
- `eval-jobs`' packages have the same lines as nix-eval-jobs 2.34.3 (C++ Nix) for the same tree, but for one:
  `gnomeExtensions.1440`, an all-digit attribute name, which iets selects and nix-eval-jobs fails on. (drbd also
  differed, because it reads `$SHELL`; see `lib.nix`.)
- On the tests, the differences were nix-eval-jobs failing where iets didn't: on a test needing a store
  (`options-doc-regression`), and on all-digit attribute names.

The `iets` input is upstream main; update it with `nix flake update iets`. It needs
[numtide/iets#354](https://github.com/numtide/iets/pull/354) (auto-call an attribute set with `__functor`, what
`callPackage` returns, as Nix does; without it, eval-jobs skips e.g. `androidenv.composeAndroidPackages`) and
[numtide/iets#355](https://github.com/numtide/iets/pull/355) (an intermittent abort at exit, `RefCell already borrowed`, which fails a report), both merged.

## Development

The formatter and checks are in the `dev` partition (`./dev`), so they don't appear in other flakes' lock files:

```bash
nix fmt
nix flake check
```
