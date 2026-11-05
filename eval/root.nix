# What nnr evaluates in a tree, from its settings (see ../lib.nix): the tree imported as Nixpkgs, or a file in it
# called with `args`, then `attrPath` selected.
{
  # The tree, a store path.
  tree,
  # A Nix file in the tree (relative to its root), or null for Nixpkgs.
  file,
  # What `file`'s function (and every function along `attrPath`) is called with, as `nix-build --arg` does.
  args,
  attrPath,
  # For Nixpkgs: the system to import it for, and its arguments: a Nix file (a store path) whose function takes
  # `{ withCA, withCUDA }`, or null for ./nixpkgs.nix.
  evalSystem,
  nixpkgsArgs,
  withCA,
  withCUDA,
  # Whether `jobs` has the tree's tests: its `passthru.tests` and GPU checks (see ./tests.nix).
  tests,
  # With `tests`: the packages whose tests not to walk, as ./tests.nix's `skip` (and added to it).
  skipTests,
  # Whether to recurse into every attribute set, not just those with `recurseForDerivations`.
  forceRecurse,
}:
let
  # As Nix auto-calls a value (eval.cc:autoCallFunction): a function taking an attribute set is called with the
  # attributes of `args` it takes, and a `__functor` set is called through its functor.
  autoCall =
    args: f:
    if builtins.isFunction f then
      (
        if builtins.functionArgs f != { } then
          f (builtins.intersectAttrs (builtins.functionArgs f) args)
        else
          f
      )
    else if builtins.isAttrs f && f ? __functor then
      autoCall args (f.__functor f)
    else
      f;

  # The value at an attribute path, auto-calling each value on the way.
  selectAlong = args: builtins.foldl' (value: name: (autoCall args value).${name});

  imported =
    if file == null then
      import tree (
        {
          system = evalSystem;
        }
        // import (if nixpkgsArgs == null then ./nixpkgs.nix else nixpkgsArgs) { inherit withCA withCUDA; }
      )
    else
      import "${tree}/${file}";

  root = autoCall args (selectAlong args imported attrPath);
in
{
  # The tree eval-jobs walks: the derivations under `packages`, and with `tests`, their tests under `tests` and their
  # GPU checks under `gpuChecks`. The report drops that first attribute name, so each job's attribute path is its path
  # in `root`.
  jobs = {
    recurseForDerivations = true;
    packages = if builtins.isAttrs root then root // { recurseForDerivations = true; } else root;
  }
  // (if tests then import ./tests.nix { inherit forceRecurse skipTests; } root else { });

  # A job, by its attribute path in `root`, as eval-jobs reached it: it auto-calls every value it walks, with no
  # arguments.
  select = selectAlong { } root;
}
