{
  description = "nix-nixpkgs-review";

  inputs = {
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    # Determinate Nix's main branch (locked in flake.lock); ./patches/nix are rebased onto the locked commit.
    nix = {
      url = "github:DeterminateSystems/nix-src";
      inputs = {
        nixpkgs-regression.follows = "";
        nixpkgs-23-11.follows = "";
        flake-parts.follows = "";
        git-hooks-nix.follows = "";
      };
    };

    # Builds `nix` with PGO; see `hydraJobs.determinate-nix`.
    nix-optimization = {
      url = "github:ConnorBaker/nix-optimization";
      inputs = {
        nix.follows = "nix";
        flake-parts.follows = "flake-parts";
      };
    };

    # Just use whatever Nix has pinned.
    nixpkgs.follows = "nix/nixpkgs";

    # Commit prior to PR -- no easy way to get this commit using flake URI since the caret character (^) is treated
    # as "extra".
    nixpkgs-pre.url = "github:NixOS/nixpkgs/16a0bed90bd882834bf3fc1dea26ed22b67b962f";

    # HEAD of PR
    nixpkgs-post.url = "github:NixOS/nixpkgs/pull/437723/head";
  };

  outputs =
    inputs:
    let
      inherit (inputs.nixpkgs) lib;

      configurations = {
        evalSystem = [
          "aarch64-linux"
          "x86_64-linux"
        ];
        when = [
          "pre"
          "post"
        ];
        withCA = [
          false
          true
        ];
        withCUDA = [
          false
          true
        ];
      };

      mkName =
        {
          evalSystem,
          when,
          withCA,
          withCUDA,
        }:
        "pkgs-${evalSystem}"
        + lib.optionalString withCA "-ca"
        + lib.optionalString withCUDA "-cuda"
        + "-${when}";

      mapCartesianProductToAttrs =
        f:
        lib.flip lib.pipe [
          (lib.mapCartesianProduct f)
          lib.listToAttrs
        ];

      # The patched Nix (see `hydraJobs.determinate-nix`), in each of nix-optimization's variants.
      patchedNixVariants =
        system:
        inputs.nix-optimization.lib.mkOptimizedVariants {
          inherit system;
          profileWorkloads = [
            [
              "nixpkgs"
              "parallel"
            ]
          ];
          patches = lib.pipe (builtins.readDir ./patches/nix) [
            lib.attrNames
            (lib.filter (lib.hasSuffix ".patch"))
            (map (name: ./patches/nix + "/${name}"))
          ];
          extraProfileEvalArgs = [
            "--option"
            "fingerprint-derivations"
            "true"
          ];
          enableGC = false;
        };

      concatMapCartesianProductToAttrs =
        f:
        lib.flip lib.pipe [
          (lib.mapCartesianProduct f)
          lib.concatLists
          lib.listToAttrs
        ];
    in
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.flake-parts.flakeModules.partitions
      ];

      systems = configurations.evalSystem;

      transposition = {
        packageSets.adHoc = true;
        reports.adHoc = true;
        diffs.adHoc = true;
      };

      perSystem =
        {
          config,
          pkgs,
          system,
          ...
        }:
        {
          # To be used for introspection only; these are instantiated within a derivation, so
          # don't use or instantiate these because they'll hang around instead of being GC'd.
          packageSets =
            let
              mkPackageSet = cfg: {
                name = mkName cfg;
                value = import inputs."nixpkgs-${cfg.when}" {
                  # NOTE: We use the evalSystem from cfg as the system to instantiate Nixpkgs with.
                  # This simplifies the reviews packages because we can avoid indexing into systems in
                  # the packageSets attribute set, instead using the current system.
                  system = cfg.evalSystem;
                  config = import ./configs { inherit (cfg) withCA withCUDA; };
                  overlays = import ./overlays { inherit (cfg) withCA; };
                };
              };
            in
            mapCartesianProductToAttrs mkPackageSet configurations;

          # TODO: Generalize reports so we can generate them for systems other than the current one.
          reports =
            let
              mkReport =
                cfg:
                let
                  name = mkName cfg;
                in
                {
                  inherit name;
                  value = pkgs.callPackage ./mkReport.nix {
                    inherit (cfg) evalSystem withCA withCUDA;
                    name = "report-${name}";
                    nixpkgs = inputs."nixpkgs-${cfg.when}";
                    # We don't need the doc or dev outputs.
                    nix = inputs.nix.packages.${system}.default.out;
                  };
                };
            in
            mapCartesianProductToAttrs mkReport configurations;

          diffs =
            let
              mkDiff =
                { reportPreName, reportPostName }:
                let
                  name = reportPreName + "-" + reportPostName;
                  reportPre = config.reports.${reportPreName};
                  reportPost = config.reports.${reportPostName};
                in
                lib.optionals
                  (
                    # It doesn't make sense to compare across systems.
                    reportPre.evalSystem == reportPost.evalSystem
                    # It doesn't make sense to compare with and without CA derivations.
                    && reportPre.withCA == reportPost.withCA
                  )
                  [
                    {
                      inherit name;
                      value = pkgs.callPackage ./mkDiff.nix {
                        name = "diff-${name}";
                        inherit reportPre reportPost;
                      };
                    }
                  ];

              reportNames = lib.attrNames config.reports;
            in
            concatMapCartesianProductToAttrs mkDiff {
              reportPreName = reportNames;
              reportPostName = reportNames;
            };

          # TODO: Create a review shell or something so that with failing derivations I can do `nix why-depends` with
          # the derivation and the review shell and see how the dependency is being brought in (e.g., directly or
          # transitively).
          packages =
            lib.mapAttrs' (
              name: diff:
              let
                name' = "review-${name}";
                packageSetAttrPath = "packageSets.${system}.${lib.removePrefix "report-" diff.reportPost.name}";
              in
              {
                name = name';
                # NOTE: These scripts won't capture being run with --override-input since it doesn't change the committed lockfile.
                # TODO: What if we forwarded all arguments the script received and used them to build diff and everything else
                # with those arguments?
                # Ideally having the reference through inputs.self.outPath and inputs.self.narHash would be enough if, when
                # --override-input is used, a new store path entry with a new flake lockfile is created; if that's not the case,
                # need to think of something else.
                # Unfortunately, that doesn't seem to be the case.
                # Consider the case where we do forward the arguments and do override-input in the script --
                # what if the inputs are unlocked? If evaluation of the diff takes long enough, by the time
                # we're running `nix build`, the unlocked inputs could have changed and been fetched again.
                # TODO: Sometimes I get errors about the nix store path in flakeRef not existing and being incapable of being built.
                # Maybe something to do with lazy-trees?
                value = pkgs.writeShellScriptBin name' ''
                  echo "added derivations: $(${lib.getExe pkgs.jq} < ${diff} '.added | length')"
                  ${lib.getExe pkgs.jq} --raw-output '.added[] | join(".")' < ${diff}
                  echo

                  echo "changed derivations: $(${lib.getExe pkgs.jq} < ${diff} '.changed | length')"
                  ${lib.getExe pkgs.jq} --raw-output '.changed[] | join(".")' < ${diff}
                  echo

                  echo "building added and changed derivations"
                  # Quote each attribute name, since some contain dots.
                  ${lib.getExe pkgs.jq} \
                    --raw-output \
                    '(.added + .changed)[] | ".#${packageSetAttrPath}." + (map(tojson) | join("."))' \
                    < ${diff} | \
                  nix build \
                    --keep-going \
                    --no-link \
                    --stdin
                '';
              }
            ) config.diffs
            // {
              default = config.packages.nnr;

              # What changed between two revisions of a git repository (see README.md and nnr.py).
              nnr = pkgs.writeShellApplication {
                name = "nnr";
                runtimeInputs = [
                  pkgs.git
                  pkgs.jq
                ];
                runtimeEnv = {
                  # What a report's expression imports (not all of this repository, so editing e.g. the README doesn't
                  # invalidate cached reports).
                  NNR_SRC = lib.fileset.toSource {
                    root = ./.;
                    fileset = lib.fileset.unions [
                      ./configs
                      ./diff.jq
                      ./mkNestedReport.nix
                      ./overlays
                      ./skip.nix
                    ];
                  };
                  # The Hydra jobsets' Nix on x86_64-linux. Elsewhere, the same patched Nix without the (long) profiling
                  # pipeline.
                  NNR_NIX =
                    let
                      variants = patchedNixVariants system;
                    in
                    "${
                      if system == "x86_64-linux" then variants.cs-pgo-bolt.nix-cli else variants.baseline.nix-cli
                    }/bin/nix";
                };
                text = ''
                  exec ${lib.getExe pkgs.python3} -I ${./nnr.py} "$@"
                '';
              };

              # Finds the attribute paths to add to ./skip.nix for a Nixpkgs tree: builds a tests report, and while
              # evaluating it fails (see mkReport.nix's `error` output), skips the attribute path it failed at and builds
              # it again. Each round evaluates Nixpkgs, so it takes a while.
              find-skips = pkgs.writeShellApplication {
                name = "find-skips";
                runtimeInputs = [ pkgs.jq ];
                text = ''
                  usage() {
                    echo "usage: find-skips [--cuda] [--system <system>] --nix <Determinate Nix> <nixpkgs>" >&2
                    echo "  --nix: the Nix to evaluate with (a store path), e.g. the output of" >&2
                    echo "    nix build .#hydraJobs.determinate-nix.x86_64-linux" >&2
                    echo "  or a stock Determinate Nix" >&2
                    exit 2
                  }

                  withCUDA=false
                  evalSystem=${system}
                  evalNix=
                  nixpkgs=
                  while (( $# > 0 )); do
                    case "$1" in
                      --cuda) withCUDA=true ;;
                      --system) evalSystem=$2; shift ;;
                      --nix) evalNix=$(realpath "$2"); shift ;;
                      -*) usage ;;
                      *) [[ -z "$nixpkgs" ]] || usage; nixpkgs=$(realpath "$1") ;;
                    esac
                    shift
                  done
                  [[ -n "$nixpkgs" && -n "$evalNix" ]] || usage

                  skip=$(nix eval --json --file ${./skip.nix})
                  found='[]'
                  while true; do
                    echo "find-skips: building a tests report with $(jq length <<< "$found") new skip(s)" >&2
                    # --eval-store auto: `--nix` is a path in the store builds use, which builtins.storePath must find even if
                    # evaluation is configured to use another store.
                    error=$(
                      nix build --no-link --print-out-paths --impure --eval-store auto \
                        --argstr nixpkgs "$nixpkgs" --argstr evalSystem "$evalSystem" --argstr evalNix "$evalNix" \
                        --argstr withCUDA "$withCUDA" --argstr skip "$(jq --compact-output --argjson found "$found" 'reduce $found[] as $p (.; setpath($p; true))' <<< "$skip")" \
                        --expr '
                          { nixpkgs, evalSystem, evalNix, withCUDA, skip }:
                          let
                            pkgs = import ${inputs.nixpkgs} { system = "${system}"; };
                          in
                          (pkgs.callPackage ${./.}/mkReport.nix {
                            name = "find-skips-tests-report";
                            nixpkgs = builtins.path { path = nixpkgs; name = "source"; };
                            inherit evalSystem;
                            withCA = false;
                            withCUDA = withCUDA == "true";
                            reportKind = "tests";
                            skip = builtins.fromJSON skip;
                            nix = builtins.storePath evalNix;
                          }).error
                        '
                    )
                    attrPath=$(jq --compact-output .attrPath "$error" 2> /dev/null || echo null)
                    if [[ "$(< "$error")" == null ]]; then
                      break
                    elif [[ "$attrPath" == null ]]; then
                      echo "find-skips: evaluating tests failed, but the trace doesn't start with an attribute path:" >&2
                      jq --raw-output .error "$error" >&2
                      exit 1
                    elif jq --exit-status --argjson p "$attrPath" 'index([$p]) != null' <<< "$found" > /dev/null; then
                      echo "find-skips: skipping $attrPath didn't help:" >&2
                      jq --raw-output .error "$error" >&2
                      exit 1
                    fi
                    echo "find-skips: skipping $attrPath: $(jq --raw-output '.error | split("\n") | map(select(test("^ *error: "))) | last // "?"' "$error")" >&2
                    found=$(jq --compact-output --argjson p "$attrPath" '. + [$p]' <<< "$found")
                  done

                  echo "find-skips: tests evaluate with $(jq length <<< "$found") new skip(s); add these to skip.nix:" >&2
                  # As Nix attribute paths, quoting names that aren't identifiers (or are keywords).
                  jq --raw-output '
                    def nixName:
                      if test("^[A-Za-z_][A-Za-z0-9_-]*$") and (IN("assert", "else", "if", "in", "inherit", "let", "or", "rec", "then", "with") | not) then . else tojson end;
                    .[] | "  " + (map(nixName) | join(".")) + " = true;"
                  ' <<< "$found"
                '';
              };
            };
        };

      # The Nix used by mkReport.nix; Hydra jobsets consume it as a `build` input so they never need to fetch or build
      # it during evaluation.
      # It is built with CSPGO and then BOLT (both profiled on a parallel evaluation of Nixpkgs) and with the patches in
      # ./patches/nix
      # (`git format-patch` output, applied in order), notably:
      # - the `fingerprint-derivations` setting, which computes derivation and output paths that are only good for
      #   telling whether derivations changed, but much more cheaply;
      # - `maybeParseStorePath()` not throwing (~1.8M exceptions per report) for paths that obviously aren't store
      #   paths, such as the files of Nixpkgs;
      # - evaluator hot path fixes (~20% fewer instructions per report), which keep the reports identical (apart from
      #   the fingerprints' values, which only need to be comparable with each other).
      # The patches are against the `nix` input, so update them together.
      # It is built without Boehm GC: reports never collect anyway (see mkReport.nix), so the evaluator bump-allocates
      # from per-thread chunks instead, which took ~7% fewer cycles and 2.5G less memory (24G peak).
      flake.hydraJobs.determinate-nix = lib.genAttrs [ "x86_64-linux" ] (
        system: (patchedNixVariants system).cs-pgo-bolt.nix-cli
      );

      partitionedAttrs = {
        checks = "dev";
        devShells = "dev";
        formatter = "dev";
      };

      partitions.dev = {
        extraInputsFlake = ./dev;
        module = ./dev/flake-module.nix;
      };
    };
}
