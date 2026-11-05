# The jobs: copied, as default.nix, into the output of ../lib.nix's mkJobs next to ./root.nix, settings.json (what the
# report of the tree evaluated) and changed.json (the attribute paths of what changed). An attribute set from each
# attribute path, joined with dots (e.g. "python3Packages.torch", "hello.passthru.tests.version"), to its value in the
# tree.
#
# It's flat, rather than nested like the attribute paths, because a derivation can be a job and contain jobs (`hello`
# and `hello.passthru.tests.version`), and nix-eval-jobs doesn't recurse into derivations. Hydra names the jobs of nested
# attribute sets the same way.
#
# settings.json refers to the tree's store path, so its contents carry that path as context, which fromJSON refuses.
# The tree is a runtime dependency of this directory, so discarding the context loses nothing.
let
  inherit
    (import ./root.nix (
      builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.readFile ./settings.json))
    ))
    select
    ;
in
builtins.listToAttrs (
  map (path: {
    name = builtins.concatStringsSep "." path;
    value = select path;
  }) (builtins.fromJSON (builtins.readFile ./changed.json))
)
