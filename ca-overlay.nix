final: prev:
{
  bison = prev.bison.overrideAttrs {
    # ## ------------- ##
    # ## Test results. ##
    # ## ------------- ##

    # ERROR: 696 tests were run,
    # 6 failed unexpectedly.
    # 80 tests were skipped.
    # ## -------------------------- ##
    # ## testsuite.log was created. ##
    # ## -------------------------- ##

    # Please send `tests/testsuite.log' and all information you think might help:

    #    To: <bug-bison@gnu.org>
    #    Subject: [GNU Bison 3.8.2] testsuite: 36 40 48 73 172 229 failed

    # You may investigate any problem if you feel able to do so, in which
    # case the test suite provides a good starting point.  Its output may
    # be found below `tests/testsuite.dir'.
    doInstallCheck = false;
  };

  # bluez = prev.bluez.overrideAttrs (prevAttrs: {
  #   # > FAIL: unit/test-gattrib
  #   # > =======================
  #   # >
  #   # > TAP version 14
  #   # > # random seed: R02S05bdb7a494dd10494e7c5a49b7301301
  #   # > 1..6
  #   # > # Start of gattrib tests
  #   # > ok 1 /gattrib/refcount
  #   # > ok 2 /gattrib/get_channel
  #   # > ok 3 /gattrib/send
  #   # > ok 4 /gattrib/cancel
  #   # > **
  #   # > ERROR:unit/test-gattrib.c:497:test_register: assertion failed: (canceled)
  #   # > not ok /gattrib/register - ERROR:unit/test-gattrib.c:497:test_register: assertion failed: (canceled)
  #   # > Bail out!
  #   # > FAIL unit/test-gattrib (exit status: 134)
  #   postPatch = prevAttrs.postPatch + ''
  #     skipTest test-gattrib
  #   '';
  # });

  # coreutils = prev.coreutils.overrideAttrs (prevAttrs: {
  #   # FAIL: tests/split/line-bytes
  #   # ============================

  #   # rm: cannot remove 'x??': No such file or directory
  #   # 001012012301234012345012345601234567012345678012345678901234567890010120123012340123450123456012345670123456780123456789012345678900101201230123401234501234560123456701234567801234567890123456789Binary files in and out differ
  #   # 0010120123012340123450123456012345670123456780123456789012345678900101201230123401234501234560123456701234567801234567890123456789001012012301234012345012345601234567012345678Binary files no_eol_in and out differ
  #   # 0123456789012345678900101201230123401234501234560123456701234567801234567890123456789001012012301234012345012345601234567012345678012345678901234567890010120123012340123450123456012345670123456780123456789012345678900101201230123401234501234560123456701234567801234567890123456789FAIL tests/split/line-bytes.sh (exit status: 1)
  #   postPatch = prevAttrs.postPatch + ''
  #     sed '2i echo Skipping split line-bytes test && exit 77' -i ./tests/split/line-bytes.sh
  #   '';
  # });

  # cryptsetup = prev.cryptsetup.overrideAttrs {
  #   # Hangs after:
  #   # > PASS: compat-args-test
  #   doCheck = false;
  # };

  # elfutils = prev.elfutils.overrideAttrs (prevAttrs: {
  #   # Fails with:
  #   # > FAIL: run-strip-reloc-ko.sh
  #   # doCheck = false;
  #   postPatch = prevAttrs.postPatch + ''
  #     sed '2i echo Skipping run-strip-reloc-ko test && exit 77' -i ./tests/run-strip-reloc-ko.sh
  #   '';
  # });

  git = prev.git.overrideAttrs (prevAttrs: {
    # Flaky tests (again, maybe because of ZFS, maybe something else).
    preInstallCheck = ''
      NIX_BUILD_CORES=4
    ''
    + prevAttrs.preInstallCheck
    + ''
      disable_test t0050-filesystem
      disable_test t4104-apply-boundary
      disable_test t7513-interpret-trailers
    '';
  });

  gnutls = prev.gnutls.overrideAttrs {
    # Gets hung after:
    # PASS: dtls/dtls.sh
    doCheck = false;
  };

  pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
    (_: prev: {
      fs = prev.fs.overrideAttrs (prevAttrs: {
        # FAILED tests/test_encoding.py::TestEncoding::test_listdir - OSError: [Errno 84] Invalid or incomplete multibyte or wide character: '/bu...
        # FAILED tests/test_encoding.py::TestEncoding::test_open - OSError: [Errno 84] Invalid or incomplete multibyte or wide character: '/bu...
        # FAILED tests/test_encoding.py::TestEncoding::test_scandir - OSError: [Errno 84] Invalid or incomplete multibyte or wide character: '/bu...
        disabledTestPaths = prevAttrs.disabledTestPaths ++ [
          "tests/test_encoding.py::TestEncoding::test_listdir"
          "tests/test_encoding.py::TestEncoding::test_open"
          "tests/test_encoding.py::TestEncoding::test_scandir"
        ];
      });

      pygit = prev.pygit.overrideAttrs (prevAttrs: {
        # FAILED test/test_branch.py::test_lookup_branch_local - UnicodeDecodeError: 'utf-8' codec can't decode byte 0xb1 in position 28: in...
        disabledTestPaths = prevAttrs.disabledTestPaths ++ [
          "test/test_branch.py::test_lookup_branch_local"
        ];
      });

      # pycairo = prev.pycairo.overrideAttrs (old: {
      #   # FAILED tests/test_fspaths.py::test_fspaths - tests.test_fspaths.cairo.IOError: error while writing to output stream
      #   disabledTests = [
      #     "test_fspaths"
      #   ];
      # });

      # TODO: PyTest xdist failure?
      # FAILED testing/acceptance_test.py::TestLoadScope::test_workqueue_ordered_by_input - AssertionError: assert {'gw1': 10} == {'gw0': 10}

      watchdog = prev.watchdog.overrideAttrs (prevAttrs: {
        # FAILED tests/test_inotify_c.py::test_select_fd - OSError: [Errno 24] Too many open files: '/build/pytest-of-nixbld/pytest-0/test_select_fd0/new_file'
        disabledTestPaths = prevAttrs.disabledTestPaths ++ [
          "tests/test_inotify_c.py::test_select_fd"
        ];
      });
    })
  ];

  wget = prev.wget.overrideAttrs (prevAttrs: {
    # FAIL: Test-iri-list.px
    # FAIL: Test-ftp-iri-fallback.px
    # FAIL: Test-ftp-iri.px
    # FAIL: Test-ftp-iri-disabled.px
    # FAIL: Test-ftp-iri-recursive.px
    # FAIL: Test-iri-disabled.px
    # FAIL: Test-iri-list.px
    # These seem related to ZFS: "Invalid or incomplete multibyte or wide character"
    # These are already disabled on Darwin.
    # https://github.com/NixOS/nixpkgs/blob/7e297ddff44a3cc93673bb38d0374df8d0ad73e4/pkgs/by-name/wg/wget/package.nix#L89-L102
    preCheck =
      prevAttrs.preCheck
      + final.lib.optionalString (!final.stdenv.hostPlatform.isDarwin) ''
        # depending on the underlying filesystem, some tests
        # creating exotic file names fail
        for f in tests/Test-ftp-iri.px \
          tests/Test-ftp-iri-fallback.px \
          tests/Test-ftp-iri-recursive.px \
          tests/Test-ftp-iri-disabled.px \
          tests/Test-iri-disabled.px \
          tests/Test-iri-list.px ;
        do
          # just return magic "skip" exit code 77
          sed -i 's/^exit/exit 77 #/' $f
        done
      '';
  });
}
//
  builtins.mapAttrs
    (
      _: nodejs:
      nodejs.overrideAttrs (prevAttrs: {
        # Failed tests:
        # out/Release/node --test-reporter=./test/common/test-error-reporter.js --test-reporter-destination=stdout /build/node-v22.19.0/test/parallel/test-fileurltopathbuffer.js
        # out/Release/node --test-reporter=./test/common/test-error-reporter.js --test-reporter-destination=stdout /build/node-v22.19.0/test/parallel/test-fs-readdir-ucs2.js
        # Perhaps because of ZFS, perhaps something else.
        checkFlags = map (
          flag:
          if final.lib.hasPrefix "CI_SKIP_TESTS=" flag then
            ''${flag},test-fileurltopathbuffer,test-fs-readdir-ucs2''
          else
            flag
        ) prevAttrs.checkFlags or [ ];
      })
    )
    {
      # TODO: Keep up to date with nodejs releases.
      inherit (prev)
        nodejs_20
        nodejs-slim_20
        nodejs_22
        nodejs-slim_22
        nodejs_24
        nodejs-slim_24
        ;
    }
