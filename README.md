# nix-nixpkgs-review

Find out which packages a Nixpkgs change adds, changes, removes or breaks, by evaluating Nixpkgs before and after and
comparing the results. It doesn't instantiate or build anything to do so.

- `mkReport.nix` evaluates a tree (Nixpkgs, or another entry point, as nix-eval-jobs does) inside a derivation, in
  parallel, with [iets](https://github.com/numtide/iets)' `eval-jobs`. It records the output paths of every job, and
  the error of every attribute that fails to evaluate.
- `mkDiff.nix` compares two trees' reports and lists the attribute paths added, changed, removed, broken and fixed.
- `lib.mkReview` builds, from those, a Nix expression for what changed between two revisions of a git repository (for
  nix-eval-jobs or Hydra), and `nnr` is its command line (see [`nnr`](#nnr-what-changed-in-a-git-repository)).
- `hydraJobs.iets` is the iets the reports use (see [iets](#iets)).

Its main user is the [nixos-cuda](https://github.com/nixos-cuda) Hydra, which uses it to find the packages a pull
request changes (see [In a Hydra jobset](#in-a-hydra-jobset)). From the command line, use
[`nnr`](#nnr-what-changed-in-a-git-repository).

## Reports and diffs

A report is the jobs of a tree, as nix-eval-jobs and Hydra walk it: attribute sets with `recurseForDerivations` are
recursed into, and functions are called with the arguments they have defaults for. It's one JSON line per attribute
path, sorted. There are two kinds (`reportKind`).

A **packages report** records each derivation's outputs, or the error an attribute failed to evaluate with:

```json
{"attrPath":["hello"],"outputs":{"out":"/nix/store/nsq63r5qzvvlhhpmi5sa9hvs86j6mr8n-hello-2.12.3"}}
{"attrPath":["python313Packages","requests"],"outputs":{"dist":"/nix/store/7icywyw859yp5g2qxa8av38zz0ddflpb-python3.13-requests-2.34.2-dist","out":"/nix/store/6zl3v9fqbl4ycg28vmd3g98qx50488m6-python3.13-requests-2.34.2"}}
{"attrPath":["zoom-us"],"error":"Refusing to evaluate package 'zoom-7.2.1.5760' in /nix/store/kc3dkdhlx5hz6mf3wg3szbnjrgbbrmyj-source/pkgs/by-name/zo/zoom-us/package.nix:138 because it has an unfree license (‘unfree’)"}
```

- The error is its last `error:` line. Most are Nixpkgs refusing a package: for Nixpkgs e58dcdca81f2 (aarch64-linux),
  19,292 of 19,403 errors (with an iets that didn't yet call `__functor` sets, which add ~680 more) were packages that
  have problems, are unfree, aren't available on the platform or are insecure.
- Output paths, not derivation paths, are compared. Derivation paths also change when only how a source is fetched
  changes (e.g., a fixed-output derivation's URL or fetcher), while output paths depend on fixed-output derivations only
  through their content hashes.

A **tests report** records each derivation's `passthru.tests` instead, as jobs whose attribute paths are their paths in
the tree (see [`testsRoot.nix`](./testsRoot.nix)):

```json
{"attrPath":["hello","passthru","tests","version"],"outputs":{"out":"/nix/store/…-hello-test-version"}}
```

- Attribute sets within `passthru.tests` are recursed into, up to `passthru.tests.a.b.c`.
- Only `passthru.tests` is looked at (the rest of `passthru` is full of dependencies and whole package sets), and a
  test's own `passthru.tests` isn't: tests are often overrides of the package, whose tests are more overrides.
- NixOS tests (`nixosTests.*`, which many packages list) are skipped: computing their output path evaluates a NixOS
  system per node.
- What's too big to walk is skipped by [`skip.nix`](./skip.nix) (see [Skipping tests](#skipping-tests)).

eval-jobs evaluates each attribute on its own, so an error, of any kind (not just what `tryEval` catches: a missing
attribute, calling a function with an argument it doesn't take, `abort`), is only that attribute's. Nixpkgs' CI
evaluates packages but not their tests, so tests that fail to evaluate aren't rare; they're errors in the report like
any other. Only a fatal error (e.g. a stack overflow) fails a report.

For Nixpkgs e58dcdca81f2 (aarch64-linux, 20 cores, on a busy machine):

| Report | Jobs | Errors | eval-jobs | Peak memory |
|---|---|---|---|---|
| Packages | 92,713 | 20,082 | 19.7–29.8 s | 18.6–19.0 GB |
| Tests | 10,590 | 1,387 | 19.6–26.1 s | 23.5–24.2 GB |

(The times and memory, and the tests counts, are from iets without numtide/iets#354.) The packages report has as many
lines (112,794 attribute paths) as nix-eval-jobs prints for the same tree.

A diff lists the sorted attribute paths of the derivations added, changed, removed, broken and fixed between two trees'
reports (their packages reports, and their tests reports if given):

```json
{
  "added": [["foo"], ["hello", "passthru", "tests", "version"]],
  "changed": [["python3Packages", "torch"]],
  "removed": [],
  "broken": [["cowsay"]],
  "fixed": [],
  "testsCompared": true
}
```

- **added**: jobs in the second tree that weren't there in the first;
- **changed**: jobs in both, with different outputs;
- **removed**: jobs in the first tree that aren't there in the second;
- **broken**: jobs in the first tree that fail to evaluate in the second;
- **fixed**: attributes that failed to evaluate in the first tree and are jobs in the second.

An attribute that fails in both, or is new and fails, isn't listed. These are attribute paths in the tree:
`hello.passthru.tests.version` evaluates to that test. A test's output path changes whenever anything it depends on
does, so this finds the tests of changed packages, tests in other packages' `passthru.tests` that depend on them, and
new tests.

## In a Hydra jobset

nixos-cuda's pull request jobset does this. The pieces are in three pull requests, written for this repository's
earlier Nix-based reports; they need the changes below:

- [nixos-cuda/hydra-jobsets#51](https://github.com/nixos-cuda/hydra-jobsets/pull/51) adds a `tools` flake jobset that
  builds this flake's `hydraJobs`: now `iets.x86_64-linux` (it was `determinate-nix.x86_64-linux`).
- [nixos-cuda/infra#149](https://github.com/nixos-cuda/infra/pull/149) gives each pull request jobset two more inputs:
  - `nixNixpkgsReview`, a `git` input for this repository;
  - `evalNix`, a `build` input, which should now be `nixos-cuda:tools:iets.x86_64-linux`.
- [nixos-cuda/hydra-jobsets#52](https://github.com/nixos-cuda/hydra-jobsets/pull/52) uses them in
  `jobsets/nixpkgs-pr.nix`. It has the details, measurements and testing instructions.

The jobset builds the reports and diffs as import-from-derivation and reads the diffs to decide which jobs to create:

```nix
mkReport = when: tree: withCUDA:
  pkgs.callPackage "${nixNixpkgsReview}/mkReport.nix" {
    name = "report-${when}${lib.optionalString withCUDA "-cuda"}-x86_64-linux";
    nixpkgs = tree;
    evalSystem = "x86_64-linux";
    withCA = false;
    inherit withCUDA;
    # A file whose expression maps { withCA, withCUDA } to Nixpkgs' arguments (other than `system`).
    nixpkgsArgs = ./nixpkgs-pr-args.nix;
    iets = evalNix.outPath;
  };

diff = pkgs.callPackage "${nixNixpkgsReview}/mkDiff.nix" {
  name = "diff-pr";
  reportPre = mkReport "head" nixpkgs false;
  reportPost = mkReport "merge" nixpkgsMerge false;
};

changed = let d = lib.importJSON diff; in d.added ++ d.changed ++ d.fixed;
```

(`iets` is used as `${iets}/bin/iets`, through `nativeBuildInputs`; `evalNix.outPath` is enough.)

### `mkReport.nix`'s arguments

| Argument | Meaning |
|---|---|
| `name` | The derivation's name. |
| `nixpkgs` | The tree to evaluate (a path or store path): Nixpkgs, or, with `file`, any tree. |
| `evalSystem` | The `system` to import Nixpkgs for. It doesn't need to match the builder's system. |
| `withCA`, `withCUDA` | Passed to `nixpkgsArgs`. |
| `nixpkgsArgs` | Optional. A Nix file whose expression is a function from `{ withCA, withCUDA }` to the arguments to import Nixpkgs with (other than `system`). It is copied to the store on its own, so it can't refer to files outside it. Defaults to `./configs` and `./overlays`: `allowAliases = false`, `allowBroken = false`, `allowUnfree = false` and `checkMeta = true`; with `withCUDA`, `cudaSupport = true`, `cudaCapabilities = [ "8.9" ]` and only NVIDIA's CUDA licenses allowed; with `withCA`, `contentAddressedByDefault = true`; and without the attributes `nixpkgs-review` skips (`tests.trivial`, `nixos-install-tools`, …). |
| `reportKind` | Optional, default `"packages"`. `"packages"` or `"tests"` (see above). |
| `skip` | Optional. What a tests report doesn't walk (see [Skipping tests](#skipping-tests)). Defaults to `import ./skip.nix`. |
| `file`, `args`, `attrPath` | Optional. What to evaluate in a tree that isn't Nixpkgs, as nix-eval-jobs does: a Nix file in the tree, which, if it's a function taking an attribute set, is called with the attributes of `args` it takes, and an attribute path to select (also for Nixpkgs). `args` is passed as JSON, so its values must be JSON values or paths. |
| `forceRecurse` | Optional, default `false`. Recurse into every attribute set, not just those with `recurseForDerivations` (e.g. for a Hydra jobset). Only with `file`: Nixpkgs would never finish (`pkgs.pkgs` is `pkgs`). |
| `iets` | The iets to evaluate with (`hydraJobs.iets`, or any build of iets with numtide/iets#354 and numtide/iets#355; see [iets](#iets)). |

The result has its arguments (`args`, `attrPath`, `evalSystem`, `file`, `forceRecurse`, `nixpkgs`, `reportKind`, `root`,
`skip`, `withCA` and `withCUDA`) in `passthru`. `mkDiff.nix` takes `name`, the packages reports `reportPre` and
`reportPost`, and optionally the tests reports `testsPre` and `testsPost` (both or neither).

Things to keep in mind:

- **Reports are built locally.** nix-eval-jobs builds import-from-derivation on the evaluating machine, so a Hydra
  host needs the memory for a report on top of its evaluator workers.
- **Build reports one after another.** Each one uses every core, so building several at once only adds memory. The
  jobset chains them by giving each report an `after` attribute referring to the previous one.
- **Nothing is freed.** iets never frees memory during an evaluation; the evaluated package set stays reachable until
  the end anyway.

## Skipping tests

[`skip.nix`](./skip.nix) is what tests reports don't walk: an attribute set nested like the tree, with `true` for each
attribute path to skip, and so everything below it. Since each attribute is evaluated on its own, tests that fail to
evaluate don't need skipping; this is only for what's too big to walk. It has one thing, the Home Assistant component
tests: each of the ~1,200 components lists all of them in its `passthru.tests`, so walking them made 1.4M test jobs
instead of 10.6k. Each is still a test of `home-assistant`, as `home-assistant.passthru.tests.components.<component>`.

Paths that don't exist (e.g. on another branch) are ignored, so one file serves every branch. A test reachable through
several attribute paths needs an entry for each. To add to it, merge recursively
(`skip = lib.recursiveUpdate (import "${nixNixpkgsReview}/skip.nix") { ... };`); `//` would replace whole top-level
entries.

## `nnr`: what changed in a git repository

`nnr` (the flake's default package) captures what changed between two trees of a git repository, so that only that is
evaluated (e.g. by nix-eval-jobs) and built (e.g. by Hydra). It prints the store path of a Nix expression for the
derivations added, changed or fixed in the second tree:

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

It also prints how many jobs there are, and which jobs broke. The path (see `mkJobs.nix`) is a directory:

- `default.nix`: an attribute set from each added, changed or fixed attribute path, joined with dots (e.g.
  `"python3Packages.torch"`, `"hello.passthru.tests.version"`), to its value in the second tree. It's flat, rather than
  nested, because a derivation can both be a job and contain jobs (`hello` and `hello.passthru.tests.version`), and
  nix-eval-jobs doesn't recurse into derivations; Hydra names nested jobs the same way. It evaluates in pure mode.
- `root.nix`: what was evaluated in the tree, exactly as its report evaluated it (see `rootExpr.nix`): Nixpkgs with the
  same configuration, or the same file, arguments and attribute path.
- `changed.json`: the attribute paths, as a JSON list of lists.
- `diff.json`: the diff (see `mkDiff.nix`), with what was removed and what broke.

How:

- **What it compares:** `--base` (default `HEAD^`) and `--head` (default `HEAD`), or, with `--uncommitted`, `--base`
  (default `HEAD`) and the working tree, as `builtins.fetchGit` sees it (as a flake sees a dirty tree): tracked files as
  they are on disk, and new files only once staged (`git add -N` is enough).
- **What it evaluates:** Nixpkgs, if the tree has `pkgs/top-level/all-packages.nix`, configured as `mkReport.nix`'s
  default `nixpkgsArgs` (with `--system`, `--cuda` and `--ca`). Otherwise `default.nix`, or `-f`, called with `--arg`
  and `--argstr`. `-A` works for both, and `--force-recurse` for a file. These are `mkReport.nix`'s `file`, `args`,
  `attrPath` and `forceRecurse`.
- **With what:** `lib.mkReview` reads each tree with `builtins.fetchGit`, makes their reports with `mkReport.nix`,
  diffs them with `mkDiff.nix`, and makes the jobs with `mkJobs.nix`. `nnr` resolves the revisions with git and builds
  it.
- **Reuse:** a report's derivation depends only on its tree and the settings (it's named after the commit, e.g.
  `report-packages-e58dcdca81f2`), so a commit's reports are built once and reused by every comparison with it, until
  garbage-collected.
- **Memory:** each report evaluates on every core and takes ~20 GB for Nixpkgs, so `nnr` builds with `--max-jobs 1`.
- **Tests:** with `--tests`, it also compares `passthru.tests`. For Nixpkgs e58dcdca81f2 against two commits before
  (aarch64-linux), that's 28,199 jobs instead of 22,330.
- **Limitations:** reports evaluate in a sandbox, without a store, so an entry point that fetches anything (e.g.
  `fetchTarball`, or flake inputs) or uses import-from-derivation fails. `--arg` values reach the evaluation as JSON,
  so they can only be JSON values or paths, e.g.
  `--arg nixpkgs 'builtins.fetchGit { url = "/path/to/nixpkgs"; rev = "…"; }'`.

## iets

[iets](https://github.com/numtide/iets) is a Nix evaluator in Rust. Reports use its `eval-jobs`
(`--no-instantiate --max-memory-size 0`): one process, whose worker threads share one evaluation, computing
derivation and output paths without a store. It's checked against Nix:

- For Nixpkgs e58dcdca81f2 (aarch64-linux), `iets eval` of this repository's earlier report expression (a walk of
  Nixpkgs recording each derivation's `outPath`) gave output byte-identical to Determinate Nix's.
- `eval-jobs`' packages report has the same lines as nix-eval-jobs 2.34.3 (C++ Nix) for the same tree, but for one:
  `gnomeExtensions.1440`, an all-digit attribute name, which iets selects and nix-eval-jobs fails on. (drbd also
  differed, because it reads `$SHELL`; see `mkReport.nix`.)
- On the tests, the differences were nix-eval-jobs failing where iets didn't: on a test needing a store
  (`options-doc-regression`), and on all-digit attribute names.

The `iets` input is a branch of a fork, `ConnorBaker/iets` `nix-nixpkgs-review`: upstream main with two fixes, until
they're merged:

- [numtide/iets#354](https://github.com/numtide/iets/pull/354): auto-call an attribute set with `__functor` (what
  `callPackage` returns), as Nix does; without it, eval-jobs skips e.g. `androidenv.composeAndroidPackages`.
- [numtide/iets#355](https://github.com/numtide/iets/pull/355): an intermittent abort at exit
  (`RefCell already borrowed`), after the output is written, which fails a report.

To update it, rebase the branch onto upstream main (or switch the input back to `github:numtide/iets` once both are
merged), then `nix flake update iets`.

## Development

The formatter and checks are in the `dev` partition (`./dev`), so they don't appear in other flakes' lock files:

```bash
nix fmt
nix flake check
```
