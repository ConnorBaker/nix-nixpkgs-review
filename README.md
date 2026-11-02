# nix-nixpkgs-review

Find out which packages a Nixpkgs change adds, changes or removes, by evaluating Nixpkgs before and after and comparing
the results. It doesn't instantiate or build anything to do so.

- `mkReport.nix` evaluates a tree (Nixpkgs, or another entry point, as nix-eval-jobs does) inside a derivation,
  read-only and in parallel (`nix eval --store dummy:// --eval-cores 0`). It records the output path of every
  derivation exposed for building, nested the way the attribute set is.
- `mkDiff.nix` compares two reports and lists the attribute paths added, changed and removed.
- `lib.mkReview` builds the diff between two revisions of a git repository from those, and `nnr` is its command line
  (see [`nnr`](#nnr-what-changed-in-a-git-repository)).
- `hydraJobs.determinate-nix` is a patched Determinate Nix optimized with CSPGO and BOLT. A report takes about half
  the instructions with it (see [Patched Nix](#patched-nix)).

Its main user is the [nixos-cuda](https://github.com/nixos-cuda) Hydra, which uses it to find the packages a pull
request changes (see [In a Hydra jobset](#in-a-hydra-jobset)). From the command line, use
[`nnr`](#nnr-what-changed-in-a-git-repository).

## Reports and diffs

A report is a JSON file mirroring Nixpkgs' attribute set. There are two kinds (`reportKind`).

A **packages report** records each derivation's output path:

```json
{
  "hello": { "fingerprint": "/nix/store/…-hello-2.12.2" },
  "python3Packages": { "torch": { "fingerprint": "/nix/store/…-python3.13-torch-2.9.0" }, "…": "…" },
  "lib": null
}
```

- A derivation is `{ "fingerprint": <output path> }`. With `fingerprintDerivations` (see below), it's a cheaper
  fingerprint instead, which isn't a real output path but is equal exactly when the real output paths are. (It can't be
  `outPath`: Nix prints an attribute set with an `outPath` as just that string.)
- An attribute set with `recurseForDerivations = true` is recursed into.
- Everything else, and anything that fails to evaluate, is `null`.

Output paths, not derivation paths, are recorded. Derivation paths also change when only how a source is fetched
changes (e.g., a fixed-output derivation's URL or fetcher), while output paths depend on fixed-output derivations only
through their content hashes.

A **tests report** records each derivation's `passthru.tests` instead (and only those: nothing else in `passthru` is
looked at, since it is full of dependencies and whole package sets):

```json
{
  "hello": { "passthru": { "tests": { "version": { "fingerprint": "/nix/store/…-hello-test-version" } } } },
  "python3Packages": { "torch": null, "…": "…" }
}
```

- Attribute sets within `passthru.tests` are recursed into, up to `passthru.tests.a.b.c`.
- A test is recorded by its output path only. Its own `passthru.tests` isn't looked at: tests are often overrides of
  the package, whose tests are more overrides.
- NixOS tests (`nixosTests.*`, which many packages list) are skipped (`null`): computing their output path evaluates a
  NixOS system per node, and needs a store, which reports don't have.
- A test that throws or fails an assertion is `null`, and doesn't affect other tests. Other errors (e.g. a missing
  attribute, calling a function with an argument it doesn't take, `abort`) can't be caught, and fail the whole
  evaluation. Nixpkgs' CI evaluates packages but not their tests, so such tests aren't rare: they're skipped by
  [`skip.nix`](./skip.nix) (see [Skipping tests](#skipping-tests)). A tests report always builds: if its evaluation
  fails, it's `null`, and its `error` output says why.

They're separate reports because a report never collects garbage, so one with both holds the garbage of both. For
Nixpkgs 16a0bed90bd8 (x86_64-linux, with CUDA, our earlier 3.23.1 build without fingerprints, on a busy machine,
single runs):

| Report | Wall | CPU | Peak memory | Size |
|---|---|---|---|---|
| Packages | 10.8 s | 107.5 s | 24.5 GB | 9.0 MB |
| Tests | 9.0 s | 84.4 s | 24.1 GB | 3.4 MB |
| Both in one (no longer made) | 15.6 s | 164.1 s | 39.9 GB | 10.3 MB |

The tests report had 9,031 tests of 3,444 packages. It skips `home-assistant-component-tests`: each of its ~1,000
packages is a component's tests, and lists all of them in its `passthru.tests`, as `home-assistant` does. Recording them
all took a report with both to 124.7 MB (1,011,030 of its 1,019,055 tests were Home Assistant's). Each is still
recorded once, as `home-assistant.passthru.tests.components.<component>`.

A diff lists the sorted attribute paths of the derivations added, changed and removed between two packages reports,
and, given the tests reports for the same Nixpkgs, their tests:

```json
{
  "added": [["foo"], ["hello", "passthru", "tests", "version"]],
  "changed": [["python3Packages", "torch"]],
  "removed": [],
  "testsCompared": true
}
```

These are attribute paths in Nixpkgs too: `hello.passthru.tests.version` evaluates to that test. Each packages report
is unioned with its tests report first, adding each of its derivations' tests (tests of derivations it doesn't have,
e.g. that failed to evaluate, are left out). A test's output path changes whenever anything it depends on does, so
this finds the tests of changed packages, tests in other packages' `passthru.tests` that depend on them, and new tests.
A test is listed if its output path changed, whether or not its package's did.

Tests are compared (`testsCompared`) only if both tests reports evaluated. Otherwise, only packages are, so that a
missing tests report doesn't show up as removed tests.

A packages report uses every core and, for all of Nixpkgs with `cudaSupport`, peaks at ~24 GB of memory. With the
patched Nix, one took ~5 s on a 32-thread workstation and 12–19 s on nixos-cuda's 16-thread Hydra host. A report is
~9 MB, and a diff a few KB.

## In a Hydra jobset

nixos-cuda's pull request jobset does this. The pieces are in three pull requests:

- [nixos-cuda/hydra-jobsets#51](https://github.com/nixos-cuda/hydra-jobsets/pull/51) adds a `tools` flake jobset that
  builds this flake's `hydraJobs`, i.e. `determinate-nix.x86_64-linux`.
- [nixos-cuda/infra#149](https://github.com/nixos-cuda/infra/pull/149) gives each pull request jobset two more inputs:
  - `nixNixpkgsReview`, a `git` input for this repository;
  - `evalNix`, a `build` input for `nixos-cuda:tools:determinate-nix.x86_64-linux`.
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
    nix = evalNix.outPath;
    fingerprintDerivations = true;
  };

diff = pkgs.callPackage "${nixNixpkgsReview}/mkDiff.nix" {
  name = "diff-pr";
  reportPre = mkReport "head" nixpkgs false;
  reportPost = mkReport "merge" nixpkgsMerge false;
};

changed = let d = lib.importJSON diff; in d.added ++ d.changed;
```

### `mkReport.nix`'s arguments

| Argument | Meaning |
|---|---|
| `name` | The derivation's name. |
| `nixpkgs` | The tree to evaluate (a path or store path): Nixpkgs, or, with `file`, any tree. |
| `evalSystem` | The `system` to import Nixpkgs for. It doesn't need to match the builder's system. |
| `withCA`, `withCUDA` | Passed to `nixpkgsArgs`. |
| `nixpkgsArgs` | Optional. A Nix file whose expression is a function from `{ withCA, withCUDA }` to the arguments to import Nixpkgs with (other than `system`). It is copied to the store on its own, so it can't refer to files outside it. Defaults to `./configs` and `./overlays`: `allowAliases = false`, `allowBroken = false`, `allowUnfree = false` and `checkMeta = true`; with `withCUDA`, `cudaSupport = true`, `cudaCapabilities = [ "8.9" ]` and only NVIDIA's CUDA licenses allowed; with `withCA`, `contentAddressedByDefault = true`; and without the attributes `nixpkgs-review` skips (`tests.trivial`, `nixos-install-tools`, …). |
| `fingerprintDerivations` | Optional, default `false`. Pass `--option fingerprint-derivations true`. Only `hydraJobs.determinate-nix` has this setting. The output paths are then fingerprints: equal exactly when the real paths are equal, but only comparable with reports made the same way. |
| `reportKind` | Optional, default `"packages"`. `"packages"` or `"tests"` (see above). |
| `skip` | Optional. What not to evaluate (see [Skipping tests](#skipping-tests)). Defaults to `import ./skip.nix` for a tests report, and to nothing for a packages report. |
| `file`, `args`, `attrPath` | Optional. What to evaluate in a tree that isn't Nixpkgs, as nix-eval-jobs does: a Nix file in the tree, which, if it's a function taking an attribute set, is called with the attributes of `args` it takes, and an attribute path to select (also for Nixpkgs). `args` is passed as JSON, so its values must be JSON values or paths. |
| `forceRecurse` | Optional, default `false`. Recurse into every attribute set, not just those with `recurseForDerivations` (e.g. for a Hydra jobset). Only with `file`: Nixpkgs would never finish (`pkgs.pkgs` is `pkgs`). |
| `nix` | The Nix to evaluate with. It must be a Determinate Nix: the evaluation uses `--eval-cores`, `--lazy-trees` and the `parallel-eval` feature, which upstream Nix doesn't have. |

The result has its arguments (`args`, `attrPath`, `evalSystem`, `file`, `forceRecurse`, `nixpkgs`, `reportKind`, `skip`,
`withCA` and `withCUDA`) in `passthru`, and a tests report
has an `error` output (see [Skipping tests](#skipping-tests)). `mkDiff.nix` takes `name`, the packages reports
`reportPre` and `reportPost`, optionally the tests reports `testsPre` and `testsPost` (both or neither), and
`requireTests`, to fail with the tests reports' errors rather than compare only packages when one didn't evaluate.

Things to keep in mind:

- **Use the same `nix` for every report you compare**, especially with `fingerprintDerivations`: fingerprints from
  different builds of Nix are not comparable.
- **Reports are built locally.** nix-eval-jobs builds import-from-derivation on the evaluating machine, so a Hydra
  host needs the memory for a report on top of its evaluator workers.
- **Build reports one after another.** Each one uses every core, so building several at once only adds memory. The
  jobset chains them by giving each report an `after` attribute referring to the previous one.
- **Only some evaluation errors are contained.** `tryEval` catches `throw` and failed assertions, which make a package
  or test `null`. Any other error fails the whole evaluation: a packages report then fails to build, and a tests report
  is `null` (see [Skipping tests](#skipping-tests)).
- **Nothing is collected.** Reports set `GC_DONT_GC=1`, and the patched Nix is built without Boehm GC. Garbage is
  never touched again, so it swaps out cheaply (zram compressed it ~4.5:1).

## Skipping tests

[`skip.nix`](./skip.nix) is what tests reports don't evaluate: an attribute set nested like the report, with `true`
for each attribute path to skip, and so everything below it. Most entries are tests whose evaluation fails in a way
`tryEval` can't catch:

```nix
{
  # function 'anonymous lambda' called with unexpected argument 'passthru' (pkgs/build-support/fetchurl/boot.nix)
  bashNonInteractive.passthru.tests.withChecks = true;
}
```

Paths that don't exist (e.g. on another branch) are ignored, so one file serves every branch. A test reachable through
several attribute paths (e.g. in `python312Packages` and `python313Packages`) needs an entry for each. To add to it,
merge recursively (`skip = lib.recursiveUpdate (import "${nixNixpkgsReview}/skip.nix") { ... };`); `//` would replace
whole top-level entries.

When a tests report still fails to evaluate (e.g. a test broke in Nixpkgs since `skip.nix` was last updated), it's
`null`, and its `error` output says why (it's `null` when the report evaluated):

```json
{ "attrPath": ["bashNonInteractive", "passthru", "tests", "withChecks"], "error": "error:\n … while evaluating …" }
```

`attrPath` is the attribute path the evaluation was printing when it failed, from the trace (null if there isn't one),
i.e. the path to skip. A diff then compares only packages (`testsCompared` is false), unless it has `requireTests`, in
which case it fails with the errors and their attribute paths (as `nnr --tests` does).

## `nnr`: what changed in a git repository

`lib.mkReview` is the diff between two trees of a git repository: it reads each with `builtins.fetchGit`, makes their
reports with `mkReport.nix`, as a Hydra jobset does, and diffs them with `mkDiff.nix`. `nnr` (the flake's default
package) is its command line: it resolves the revisions with git, builds the diff and prints it. Like nixpkgs-review,
but for any tree and entry point, like nix-eval-jobs:

```bash
# HEAD^ against HEAD, in a Nixpkgs checkout:
nix run github:ConnorBaker/nix-nixpkgs-review -- .

# HEAD against the working tree (uncommitted changes), with passthru.tests:
nix run github:ConnorBaker/nix-nixpkgs-review -- . --uncommitted --tests

# Any two revisions, with CUDA, as JSON (mkDiff.nix's output):
nix run github:ConnorBaker/nix-nixpkgs-review -- . --base origin/master --head my-branch --cuda --json

# Another repository's entry point:
nix run github:ConnorBaker/nix-nixpkgs-review -- . -f release.nix -A jobs --argstr system x86_64-linux --force-recurse
```

- **What it compares:** `--base` (default `HEAD^`) and `--head` (default `HEAD`), or, with `--uncommitted`, `--base`
  (default `HEAD`) and the working tree, as `builtins.fetchGit` sees it (as a flake sees a dirty tree): tracked files as
  they are on disk, and new files only once staged (`git add -N` is enough).
- **What it evaluates:** Nixpkgs, if the tree has `pkgs/top-level/all-packages.nix`, configured as the flake's reports
  are (`./configs` and `./overlays`, with `--system`, `--cuda` and `--ca`). Otherwise `default.nix`, or `-f`, called with
  `--arg` and `--argstr`. `-A` works for both, and `--force-recurse` for a file. These are `mkReport.nix`'s `file`,
  `args`, `attrPath` and `forceRecurse`.
- **With what:** the patched Nix, built with CSPGO and BOLT for the system it runs on (on x86_64-linux, that's
  `hydraJobs.determinate-nix`), with fingerprints.
- **Reuse:** a report's derivation depends only on its tree and the settings (it's named after the commit, e.g.
  `report-packages-e58dcdca81f2`), so a commit's reports are built once and reused by every diff with it, until
  garbage-collected.
- **Memory:** each report evaluates on every core and takes tens of GB, so `nnr` builds with `--max-jobs 1`. On
  aarch64-linux (20 cores), a Nixpkgs packages report (92,692 derivations) took 11.7–15.6s, with a peak RSS of 25.3 GB.
- **Tests:** with `--tests`, it also compares `passthru.tests` (skipping `skip.nix`'s entries). If a tests report doesn't
  evaluate, the diff fails with its error and the attribute path it failed at (see [Skipping tests](#skipping-tests)).
- **Limitations:** reports evaluate in a sandbox, on a dummy store, so an entry point that fetches anything (e.g.
  `fetchTarball`, or flake inputs) or uses import-from-derivation fails. `--arg` values reach the evaluation as JSON,
  so they can only be JSON values or paths, e.g.
  `--arg nixpkgs 'builtins.fetchGit { url = "/path/to/nixpkgs"; rev = "…"; }'`. `nnr` doesn't build what it lists.

## Patched Nix

`hydraJobs.determinate-nix.x86_64-linux` (and `nnr`'s Nix, on every system) is Determinate Nix (the `nix` input: its
`main` branch, locked in `flake.lock`) built by
[nix-optimization](https://github.com/ConnorBaker/nix-optimization). It's built with Clang full LTO, CSPGO and BOLT,
all trained on a parallel evaluation of Nixpkgs with fingerprints. It's built without Boehm GC, and with the patches in
`patches/nix`, which add:

- the `fingerprint-derivations` setting, which computes derivation and output paths by hashing a derivation's fields
  instead of serializing `.drv` files;
- `maybeParseStorePath()` no longer throwing for paths that obviously aren't store paths;
- evaluator hot path fixes;
- bump allocation from per-thread chunks when built without Boehm GC.

With CSPGO, the patches took ~54% fewer instructions per report than stock Determinate Nix. The reports are identical
apart from the fingerprints' values.

Building it runs four builds of Nix and three instrumented evaluations of Nixpkgs (each needs ~24 GB). Before the BOLT
stages were added, it took 20–28 minutes on a 32-thread workstation. On aarch64-linux, nix-optimization uses LLVM 23's
BOLT and leaves out the BOLT options that are x86-only or miscompile there (see its `helper.nix`).

Its training profiles aren't reproducible (see nix-optimization's README), but their store paths don't depend on what
they contain. If two machines each build the same profile, they hold different profiles at the same path, and
components built against them on different machines fail to link (`linking module flags 'ProfileSummary': IDs have conflicting values`). So make sure each profile is only built once: by building on one machine, or by making sure no
other builder already has an earlier build of it (e.g. after updating the `nix` input, every path is new). nix-optimization's
`contentAddressedProfiles` avoids this altogether, but needs builders that can build floating content-addressed
derivations.

The patches are against the `nix` input. When updating the input, rebase them onto it too, e.g. in a checkout of
[nix-src](https://github.com/DeterminateSystems/nix-src) at the new commit:

```bash
nix flake update nix
git -C ../nix-src am -3 "$PWD"/patches/nix/*.patch
git -C ../nix-src format-patch --no-signature --output-directory "$PWD/patches/nix" <new commit>..HEAD
nix build .#hydraJobs.determinate-nix.x86_64-linux
```

## Development

The formatter and checks are in the `dev` partition (`./dev`), so they don't appear in other flakes' lock files:

```bash
nix fmt
nix flake check
```
