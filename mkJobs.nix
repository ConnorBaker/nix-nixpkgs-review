{
  # config
  name,
  # The packages report of the tree to take the jobs from (the diff's `reportPost`; see mkReport.nix): its `root` is
  # what is evaluated.
  report,
  # The diff (see mkDiff.nix) whose added and changed attribute paths are the jobs.
  diff,

  # callPackage arguments
  jq,
  runCommand,
}:
# A Nix expression for the derivations a diff adds or changes, for nix-eval-jobs (`nix-eval-jobs --expr "import $out"`)
# or a Hydra jobset: an attribute set from each added or changed attribute path, joined with dots (e.g.
# "python3Packages.torch" or "hello.passthru.tests.version"), to its value in the report's tree, evaluated as the report
# evaluated it.
#
# It's flat, rather than nested like the attribute paths, because a derivation can be a job and contain jobs (e.g.
# `hello` and `hello.passthru.tests.version`), and nix-eval-jobs doesn't recurse into derivations. Hydra names the jobs of
# nested attribute sets the same way.
#
# $out is a directory: default.nix; root.nix, what the report evaluated (see rootExpr.nix); and changed.json, the
# attribute paths as a JSON list of lists.
runCommand name
  {
    __structuredAttrs = true;
    strictDeps = true;

    nativeBuildInputs = [ jq ];

    inherit (report) root;

    jobs = ''
      let
        root = import ./root.nix;
        paths = builtins.fromJSON (builtins.readFile ./changed.json);
      in
      builtins.listToAttrs (
        map (path: {
          name = builtins.concatStringsSep "." path;
          value = builtins.foldl' (value: name: value.''${name}) root path;
        }) paths
      )
    '';

    passthru = { inherit report diff; };
  }
  ''
    mkdir "$out"
    jq --compact-output '.added + .changed' ${diff} > "$out/changed.json"
    printf '%s' "$root" > "$out/root.nix"
    printf '%s' "$jobs" > "$out/default.nix"
  ''
