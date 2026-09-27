# Installation and TUI implementation receipt

## Inline integration — September 27, 2026

Qualified on macOS arm64 with Dart 3.12.2. All four interactive commands use
`TerminalMode.inline` and `exitApp()`. The native host measures the matrix's
content after layout and adjusts the region between 8 and 24 rows, bounded by
the terminal. Larger content scrolls; short terminals compact their footer.

- The current pass has 67 passing installation/init/CLI regression tests,
  including single-project completion, multi-project continuation, failed
  operations, cancellation, and init's unavailable choices. An earlier broader
  installation/init/CLI pass had 107 passing checks.
- The compiled executable passed 16 native PTY sessions in
  `check_installation_tui.py`: install without routing, use Local and execute its
  command, uninstall confirmation/cancel/removal, init review/Back/Create, all
  four commands at 40×18 with resize, and use/init with Ctrl+C, SIGINT, SIGTERM,
  and SIGHUP.
- `check_installation_ux.py` adds 15 native sessions: active/hover/keyboard states,
  unavailable reasons, `NO_COLOR`, multiple projects and `-p`, install/uninstall
  including empty inventories and the first usable row, multi-package init, and
  completing every command
  at 40×12. Two further cases exit use/init while a resize query is pending.
  Each session checks restoration and retained shell history.
- Terminal-buffer frames were inspected on dark and light rendering backgrounds.
  The page keeps the terminal background; active choices use a green cell fill
  and navigation uses blue. Hover moves focus without activation or underlines.
  Reverse video and checkmarks preserve meaning without color. These renders
  are not screenshots of a physical terminal emulator.
- Dogfooding found and fixed lost keyboard focus after multi-project operations,
  success styling on unavailable choices, and init's footer crowding its choices
  out of a short terminal. Native assertions retain coverage for those failures.
- Every native session verifies terminal modes and input blocking flags are
  restored, the inline frame is cleared, no alternate screen or whole-screen
  clear is used, and mouse capture is disabled. Signal exits retain 130/143/129.
- Analysis, formatting, and AOT compilation pass. CI runs both PTY scripts on
  macOS and Linux. The preceding integration passed both OS test jobs; this receipt's
  latest RK interaction evidence is local macOS until the updated CI runs.
  Fleury's exact pinned revision passed native inline CI on Linux and macOS,
  including Linux on the minimum supported Dart 3.10.4 SDK.
  Formatting uses Dart 3.12.2 consistently; functional CI tests use stable Dart.

The terminal harness now drains output written for the old viewport before
applying a new size. Without that ordering it could replay an old row
reservation at a new height and falsely report lost shell history. After the
correction, 100 resize stress runs passed with shell history and modes restored.

The resize/exit defect is fixed upstream in Fleury
[PR #278](https://github.com/danReynolds/fleury/pull/278). Shutdown now keeps input
available long enough to settle the pending exchange and obtain a fresh cursor
report, clears the evidenced surviving rows without allocating another region,
then restores modes and releases input. The native regression fails against the
old revision and passes after the fix at 70×18 and 90×24. Stale replies, a second
resize, missing/invalid replies, and continuous resize are covered. A one-second
budget bounds the fresh ownership check; an unresponsive terminal still gets
mode restoration without a guessed clear.

The same upstream PR fixes an explicit native driver's `EAGAIN` crash on a full
output queue. RK pins both fixes at `c4d91f46`, ahead of upstream merge/hosted
publication. Fleury passed 141 lifecycle/query regressions and its full
10-session native inline suite; both native before/after reproductions are
recorded in the upstream PR.

The commands above use disposable homes, installation roots, and fixture
projects. No personal installations or shell configuration were switched.

Reproduce with a Python environment containing `tool/tui-requirements.txt`:

```sh
dart compile exe bin/rk.dart -o /tmp/rk-inline-check
python3 tool/check_installation_tui.py /tmp/rk-inline-check
python3 tool/check_installation_ux.py /tmp/rk-inline-check
```

## Earlier installation qualification

Checked on macOS arm64, September 23, 2026, using Dart 3.12.2 and fish 3.3.1.
This is a development qualification, not a cross-platform release certificate.

## Implemented

- Shared project discovery, installation lifecycle, exclusive mutation lock,
  provider adapters, owned command shims, and atomic grouped selection.
- Local, Homebrew, Pub, and public GitHub source adapters beside their native
  target implementations. SDK packages stay outside executable selection.
- Real Fleury matrices for bare use/install/uninstall. Explicit invocations and
  JSON use the same coordinator. Selection and effective PATH are separate facts.
- Init's output matrix and validated configuration review share one terminal
  session, including Back and cancellation. Selected outputs say **Added**.
- Dart 3.10.4 minimum; SDK formatting is separated from the functional commit.

## Evidence

- Static analysis, formatting, diagnostic-code index, and AOT compilation pass.
- The broad regression run passed 1,071 tests. Its 25 failures were all native
  build cases expecting `LICENSE` in the Dart SDK root; the Homebrew SDK places
  that file outside its root. All affected suites were rerun with the complete
  Flutter-bundled Dart SDK: 97 tests passed. No release build behavior was changed
  to accommodate that machine layout.
- After the archive-validator integration, 147 checks passed across installation,
  init, release-stage, and phase-conformance suites. The final CLI/init/installation run passed 88 tests. A further 26 focused
  checks passed for the TUI lifecycle, providers, YAML, and executable mapping.
- Installation tests cover grouped commands, cwd/argument preservation, source
  edits, missing entrypoints, collisions, locks across processes, cancellation
  before pointer replacement, symlink refusal, and native PATH ownership.
- Isolated fish configuration persists the managed PATH and resolves the selected
  command in a fresh fish process. Personal fish configuration was untouched.
- Real Pub smoke: install published RK 0.1.12 into a disposable cache, select its
  shim, execute `--version`, switch to a local fixture, deactivate Pub, and execute
  the replacement. Every step passed.
- Real GitHub smoke: download RK 0.1.12's macOS arm64 bundle, verify its manifest,
  checksum, full archive inventory and code signatures, select it, and execute
  `--version`. Switching to a local fixture and removing the inactive download
  preserved the replacement. Every step passed.
- Real pseudoterminal smoke: use Local, execute the selected command, and run init
  through configuration review and file creation. Both restore terminal modes and
  leave the alternate screen. The retained script runs with disposable homes:

  ```sh
  dart compile exe bin/rk.dart -o /tmp/rk-dogfood
  python3 tool/check_installation_tui.py /tmp/rk-dogfood
  ```

The terminal smoke found a lifecycle mistake that widget tests did not catch:
starting a second Fleury session for init review reconsumed stdin. Init now keeps
one session, and a regression exercises selection, review, Back, and Create
before one terminal restoration. The live GitHub check also found the optional
LICENSE/README archive entries; the installer now shares the release engine's
validator instead of maintaining a second layout parser.

## Still to qualify before release

- **Hosted Fleury dependency.** The pub.dev API returned 404 for Fleury during
  this check. The development override pins the revision used for the approved prototypes.
  Remove the override and qualify hosted dependency resolution after publication;
  RK intentionally refuses publishing its own package with a tracked override.
- **Live Homebrew installation/removal.** Native installed-formula inspection and
  adapter contracts were checked, including exact tap identity, no linking during
  install, and no implicit upgrades. A real install/removal was not performed
  against the operator's shared Homebrew prefix.
- **Linux native behavior.** The preceding inline integration passed the Linux
  CI test job, including its 16 native PTY sessions. The added visual-interaction
  suite still needs the updated CI result. Real Linux shell and package-manager
  installation/removal qualification remains separate.
- Custom Pub registries, private GitHub downloads, Windows, and shell aliases or
  functions overriding command names are outside this first implementation.
  POSIX shells receive a PATH command; automatic persistent setup is fish-only.

No public release was published, and the operator's installations and shell
configuration were not switched by this qualification.
