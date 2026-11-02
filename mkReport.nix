{
  # config
  name,
  # The tree to evaluate: Nixpkgs, or, with `file`, any tree.
  nixpkgs,
  evalSystem,
  withCA,
  withCUDA,
  # Nix file (or directory) whose expression maps { withCA, withCUDA } to the arguments (other than `system`) to import
  # Nixpkgs with; defaults to ./configs and ./overlays.
  nixpkgsArgs ? null,
  # What to evaluate in a tree that isn't Nixpkgs, like nix-eval-jobs' arguments: a Nix file in the tree (relative to
  # its root), which, if it's a function taking an attribute set, is called with the attributes of `args` it takes. With
  # null, the tree is Nixpkgs, imported for `evalSystem` with `nixpkgsArgs`. `args` is passed to the evaluation as JSON,
  # so its values can be anything JSON can hold, or paths (which are passed as store paths).
  file ? null,
  args ? { },
  # An attribute path to select in what `file` (or Nixpkgs) evaluates to, e.g. [ "python3Packages" ].
  attrPath ? [ ],
  # Whether to recurse into every attribute set, not just those with `recurseForDerivations` (see mkNestedReport.nix),
  # e.g. for a Hydra jobset. Not for Nixpkgs, which would never finish (e.g. `pkgs.pkgs` is `pkgs`).
  forceRecurse ? false,
  # Whether `nix` has the `fingerprint-derivations` setting (see ./patches/nix) and should use it: the reports' output
  # paths are then fingerprints, which are only good for comparing with reports made the same way.
  fingerprintDerivations ? false,
  # "packages" for a report of derivations' output paths, or "tests" for a report of their `passthru.tests` (see
  # mkNestedReport.nix's `kind`), which mkDiff.nix unions with the packages report for the same Nixpkgs. (Not `kind`,
  # which callPackage would fill with Nixpkgs' `kind`.)
  reportKind ? "packages",
  # What not to evaluate: an attribute set nested like the report, with `true` for each attribute path to skip (see
  # mkNestedReport.nix and ./skip.nix, which is the default for tests reports). To add to the default, merge with it
  # recursively, e.g. with `lib.recursiveUpdate (import ./skip.nix) { ... }`.
  skip ? if reportKind == "tests" then import ./skip.nix else { },

  # callPackage arguments
  jq,
  lib,
  pkgsBuildHost,
  nix,
  runCommand,
}:
assert lib.assertMsg (
  !(forceRecurse && file == null)
) "mkReport.nix: forceRecurse is for a `file`: Nixpkgs (e.g. `pkgs.pkgs`) would never finish";
let
  # What the report evaluates (shared with mkJobs.nix, through passthru.root).
  root = import ./rootExpr.nix {
    inherit
      args
      attrPath
      evalSystem
      file
      lib
      nixpkgs
      nixpkgsArgs
      withCA
      withCUDA
      ;
  };

  # The expression the report is the JSON of: mkNestedReport.nix's result for `root`.
  # NOTE: Using `--impure` allows us to read in the Nix expressions as bind-mounted in the store, without copying them
  # to a temporary store.
  # Because of Nix's path semantics, ./configs and ./overlays create top-level store path entries with the contents
  # of those directories. As such, references within the directory are fine, but references which escape the directory
  # are not going to work.
  expr = ''
    import ${./mkNestedReport.nix} {
      kind = ${builtins.toJSON reportKind};
      skip = builtins.fromJSON ${lib.strings.escapeNixString (builtins.toJSON skip)};
      forceRecurse = ${builtins.toJSON forceRecurse};
    } (${root})
  '';
in
runCommand name
  {
    __structuredAttrs = true;
    strictDeps = true;

    outputs = [ "out" ] ++ lib.optionals (reportKind == "tests") [ "error" ];

    nativeBuildInputs = [
      jq
      nix
    ];

    inherit expr;

    passthru = {
      inherit
        args
        attrPath
        evalSystem
        file
        forceRecurse
        nixpkgs
        reportKind
        root
        skip
        withCA
        withCUDA
        ;
    };
  }
  # The report is mkNestedReport.nix's result as JSON, as `nix eval` prints it: nested like Nixpkgs, with
  # `{ "fingerprint": <output path> }` (or, for a tests report, `{ "passthru": { "tests": ... } }`) for each derivation,
  # and null for attributes that aren't derivations, failed to evaluate or are skipped. Flattening it (e.g., with jq)
  # took ~0.8s per report, longer than diffing two reports as they are (see mkDiff.nix).
  #
  # A tests report always builds, since a test can fail to evaluate in a way tryEval can't catch, failing the whole
  # evaluation; that shouldn't fail whatever reads the report (e.g. a Hydra evaluation, as import-from-derivation). Its
  # `error` output is null if it evaluated. Otherwise, `out` is null, and `error` is
  # { "attrPath": [ ... ], "error": "..." }: the error, and the attribute path of the report it was evaluating, taken from
  # the trace (null if the trace doesn't start with one). Adding the attribute path to `skip` skips it.
  #
  # NOTE: Parallel evaluation is GC-bound, and the evaluated package set stays reachable until the end, so collecting
  # buys little: for x86_64-linux with CUDA (~98k derivations, 16 eval cores, Determinate Nix 3.23.0) GC_DONT_GC=1 took
  # 11.4s with a 26G peak and a 16G initial heap 12.5s with a 19G peak, but an 8G initial heap (below the ~14G live set)
  # took 252s. The uncollected garbage is never touched again, so under memory pressure it is swapped out cheaply (e.g.,
  # to zram, which compressed it ~4.5:1). (A `nix` built without Boehm GC, like flake.nix's `hydraJobs.determinate-nix`,
  # ignores GC_DONT_GC and never collects either.)
  ''
    runEval() {
      ${lib.getExe pkgsBuildHost.time} --verbose \
        env \
        GC_DONT_GC=1 \
        nix eval \
        --show-trace \
        --verbose \
        --offline \
        --store dummy:// \
        --read-only \
        --json \
        --impure \
        --no-eval-cache \
        --no-allow-import-from-derivation \
        --no-fsync-metadata \
        --lazy-trees \
        --extra-experimental-features ca-derivations \
        --extra-experimental-features parallel-eval \
        --eval-cores 0${lib.optionalString fingerprintDerivations " --option fingerprint-derivations true"} \
        --expr "$1" \
        > "$out"
    }

    # The attribute path at the start of the trace in a log, as a JSON list (null if there is none): the attributes of
    # the report `nix eval` was printing when the error happened. The trace's frames start with "…", outermost first.
    traceAttrPath() {
      sed -n '/^error:/,$p' "$1" \
        | awk '/^ *… / { if (match($0, /^ *… while evaluating attribute \x27[^\x27]*\x27$/)) { sub(/^ *… while evaluating attribute \x27/, ""); sub(/\x27$/, ""); print } else exit }' \
        | jq --raw-input --slurp 'split("\n") | map(select(. != "")) | if . == [] then null else . end'
    }

    nixLog "running eval"
    if [[ -z ''${outputs[error]-} ]]; then
      runEval "$expr"
    elif runEval "$expr" 2> eval.log; then
      cat eval.log >&2
      echo null > "''${outputs[error]}"
    else
      cat eval.log >&2
      echo null > "$out"
      jq --null-input \
        --argjson attrPath "$(traceAttrPath eval.log)" \
        --rawfile error <(sed -n '/^error:/,$p' eval.log) \
        '{ attrPath: $attrPath, error: $error }' \
        > "''${outputs[error]}"
      nixLog "evaluating the tests report failed (see the error output), while evaluating $(jq --compact-output .attrPath "''${outputs[error]}")"
    fi

    nixLog "computed $(grep -o '"fingerprint":' "$out" | wc -l) output paths"
  ''
