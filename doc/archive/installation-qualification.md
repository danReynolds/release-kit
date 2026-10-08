# Installation and TUI implementation receipt

## Status returns to the prompt — September 29, 2026

`rk status` and bare `rk` use the finite CLI report in every environment. A
terminal shows transient check progress before the durable report; no keypress
is needed to finish. JSON and redirected output retain the same release facts.
The status picker and its refresh/detail state are removed. `rk use` remains
interactive for choosing, installing, updating and removing executable sources.

`tool/check_status_cli.py` covers automatic exit, retained reports, wide/narrow
terminals, NO_COLOR, unit filtering, invalid configuration and JSON output.
Command tests retain the published-tag/source-change distinction in both
transient progress and the final report.

## Keyboard-only and responsive updates — September 28, 2026

Native command matrices leave mouse capture disabled except for `use`, which
accepts clicks without hover tracking. Hover never moves focus or styles a
button; a click or keyboard navigation establishes the blue action focus.
`use` keeps its keyboard controls and remote version checks live during installation. Additional
mutations are queued behind the active operation, preserving the manager/store
lock. Closing cancels queued work; failures clear it for review. Update appears
only after confirming a newer compatible version. Completed operations clear
their own action focus without moving it to Use or disturbing another row.

- Analyzer and all 56 installation tests pass on macOS arm64 with Dart 3.12.2.
- Delayed-provider widget tests cover keyboard navigation, background refresh,
  queued updates, duplicate Enter, cancellation, failure, and focus preservation.
- The installation, interaction, and status native PTY suites pass with keyboard
  controls, including 40-column layouts, resize, signals, and shell restoration.
  The harness checks that only `use` enables mouse capture, never enables hover
  tracking, and restores all mouse modes when it closes.
- These checks use disposable fixtures; no shared Homebrew/Pub installation was
  upgraded as part of this pass.

## Historical: shared Use and Status design — September 28, 2026

This status-matrix experiment is superseded by the finite report above. The
following records the earlier implementation and its qualification.

`rk status` now opens the release matrix. It and Use share the
104-column bound, terminal background, blue action focus, separators, detail
view, Back behavior and inline lifecycle. Status opens without focus and reads
each configured destination asynchronously; grouped publication cells retain
per-package evidence. Refresh creates new readers and reports its timestamp.
Status and bare rk open the matrix in a usable terminal. Redirected output
and JSON remain finite reports of the same snapshot.

The matrix consumes typed snapshots from the existing StatusCommand checks.
It does not reconstruct release readiness from display strings or introduce a
second release policy. Done prints the completed snapshot without another read.
Closing cancels owned network/process readers and ignores late callbacks.

Validation on macOS arm64 / Dart 3.12.2:

- Analyzer and the third-party import boundary check pass.
- Focused status, process-cancellation and shared TUI tests pass, including
  partial grouped publication, independently completing checks, refresh failure,
  cancellation during discovery, late replies, and destination-scoped details.
- The CLI suite passes, including the compiled binary case rerun outside the
  sandbox after Dart telemetry writes were denied by the initial sandbox run.
- All three native PTY suites pass: Use/Install/Uninstall/Init, their detailed
  interaction states, and Status. Status covers wide/narrow/no-color layouts,
  Back/focus restoration, refresh, resize to 40x12, Ctrl+C, error details,
  missing configuration, finite redirected/JSON output, and unchanged fixtures.
- The PTY emulator now explicitly retains clipped top rows in scrollback during
  a height reduction; pyte otherwise deletes those rows during resize itself.

A read-only pass against the actual RK checkout and installed sources also
passes: completed remote observations, bounded layout, static default, action
focus, detail/Back, uninstall cancellation, Ctrl+C and unchanged selection.
That pass exposed the need to show source drift even when all destinations
are published; the unit now says "changed" and the first release blocker is
visible beneath the matrix.

The browser study now contains only Use and the chosen release matrix, with
matching controls and destination detail views. It remains a simulated preview.
This is local UX qualification, not a new release or cross-platform release
qualification; the previously recorded SDK bundle limitation below remains.

## Local command DX follow-up — September 28, 2026

The effective default is now a static badge; it is excluded from focus traversal.
Saved-but-shadowed selections have a separate warning label. Install/Update
remain separate from Use, while contextual Uninstall reuses the existing scoped
confirmation. Broken owned installations expose Remove directly. `install
SOURCE --latest` uses the same checked update operation as the table.

Before changing RK itself, the manager preserves and verifies a recovery build
outside selectable provider installations and reports its exact invocation.
This covers switching, updating and confirmed uninstall. Runtime/snapshot
bundles retain their matching VM; source runs compile a standalone build.

Validation on macOS arm64 / Dart 3.12.2:

- Analyzer clean; 52 installation tests and 53 status tests pass.
- The new recovery regression compiles native, AOT and JIT variants, removes
  their originals, reopens each retained build, preserves it a second time,
  and executes the second recovery entry point.
- Both native PTY scripts pass, including all four commands at 40×12,
  pointer/keyboard focus, confirmation/back, multiple packages, signals,
  resize and terminal restoration.
- A read-only native pass against the user's installed sources confirms the
  green Homebrew default, action-only blue focus, contextual GitHub removal
  and cancellation, and unchanged selection after Ctrl+C.
- Status now retains completed binary-only artifacts, displays stage-read
  causes before repair instructions, and keeps detailed remote errors in
  Issues rather than repeating them on publication rows.

A broader phase-conformance run passed 52 checks and failed 14 release/bundle
checks: the installed Homebrew Dart SDK has no `libexec/LICENSE` where the
existing bundle builder expects it. An initial attempt also resolved Flutter's
wrapper on PATH and hit sandboxed cache writes; pinning the Homebrew SDK removed
that interference and exposed the LICENSE-path failure. The focused UX checks
above pass, but this follow-up is not full release qualification. No SDK files
or release-build behavior were changed to bypass those failures.

At that point status remained a finite report with three browser inspector
proposals. The shared-design follow-up above implements the chosen matrix.
Neither pass adds live Homebrew mutation or Linux qualification.


## Source version table — September 28, 2026

The `rk use` table has independent Installed and Available state. It starts
public update checks on opening, keeps local choices usable on failure, and
separates Download from Use. Row navigation includes sources that are not yet
installed; Enter on those rows does not download. Download retains source
selection and the open picker. Single-project Use restores the terminal as soon
as switching succeeds, without another provider scan.

The dogfood follow-up caps this table at 104 columns using Fleury's existing
Align/ConstrainedBox widgets. Row focus now propagates its blue style through
text and selected buttons. Pub conflicts show their reason and repair command
inline, rather than claiming the package is absent or requiring a Why action.

Evidence on macOS arm64, Dart 3.12.2:

- 48 installation/provider/controller/CLI tests pass, including late check
  replies, cancellation, download versus selection, exact project binding,
  compatible Pub releases, changed Homebrew formula refusal, and keyboard rows.
- Both retained native PTY scripts pass. They exercise all four inline commands,
  green selection and blue explicit focus, mouse/keyboard actions, multiple
  projects, compact terminals, resize, signals, and shell restoration.
- The broader suite passed 1,153 tests with one disposable-runner Homebrew test
  skipped. Its only failing architecture assertion was updated to permit
  `pub_semver` specifically in the Pub installation adapter, then passed on
  rerun. A status subprocess stalled during the run; terminating it let the
  suite continue, and the isolated status check passed. Release and signing
  code remain outside the third-party dependency boundary.
- Real public checks resolved Homebrew, Pub and GitHub to 0.1.13. Live Pub
  activation and GitHub archive download/verification/execution both passed in
  temporary stores, without selecting either source. The probe is repeatable
  with `tool/check_installation_sources.dart`.
- Closing the compiled table during live checks restored the shell in roughly
  0.3 seconds in the local PTY probe. This is local evidence, not a startup SLA.

Live Homebrew upgrade and Linux provider operations have not been exercised in
this pass. Homebrew metadata checking is live-qualified; mutation is covered by
provider fixtures. Existing Homebrew installations were left untouched. The
Fleury Git override remains a development dependency, so this build is for local
dogfooding rather than publication.


## Core command UX review — September 27, 2026

Three separate reviews covered first-time setup, native keyboard/pointer
interaction, and release operations. Findings were reproduced with disposable
projects and terminal sessions before implementation.

- **Navigation and recovery:** arrows reveal the next matrix control rather
  than scrolling away from the old focus. This is an upstream Fleury fix.
  Unavailable sources open a complete, scrollable explanation with a concrete
  repair command; inspecting one does not make the command fail. Cancelling
  removal restores the originating cell and scroll position.
- **Long reviews:** overflow is visible, and PageUp/PageDown or Home/End work
  from the safe Back action. Scrollbars disappear when content fits without
  remounting controls. Init discovery notes remain available through selection
  and review, including why an untracked package was omitted.
- **Setup and CLI guidance:** cancelling a reviewed proposal suggests `rk init`,
  not `--write` with potentially different defaults. Init, status, plan, and
  release have focused help. Status shows one next command only when exactly
  one unfinished unit is unblocked.
- **Release reporting:** cancellation names the current unit instead of
  claiming nothing was published across an entire workspace. Local-only builds
  expose the archive directory before their final success line. Clean identifies
  each stage using bounded, local receipt metadata before confirmation; it does
  not treat that metadata as proof that the stage is safe to delete.
- **Independent follow-up review:** successful installation followed by failed
  refresh is reported as an inspection failure and retains the success result.
  Framework review also exercises clipped and nested scroll panes so arrow
  navigation cannot silently leave focus on an unreachable control.

The retained UX script adds compact reason/paging/Back checks and ten-project
confirmation/review flows. The native baseline expects cancellation to restore
focus. Both scripts use isolated homes and fixture installations; publication
and cleanup tests simulate effects. Terminal-buffer renders were inspected on
dark and light backgrounds, including 40×12 details and long reviews.

This pass updates the existing RK and Fleury review branches. Hosted Fleury,
live Homebrew mutation, and real Linux package-manager qualification remain
separate release work.

The full RK suite passed 1,129 tests, with formatting and analysis clean.
The exact development dependency is Fleury `45142d13`. Its full core suite
passed 3,943 tests (two skipped), and the embedded browser-client freshness
check passed. Five independently written public-widget probes also passed after
hardening fixed clipping, scroll limits, nested reveal, hidden focus recovery,
and containment. The final compiled RK binary passed all 35 retained native
sessions on macOS; Linux validation for the updated PRs remains with CI.

## Inline integration — September 27, 2026

Qualified on macOS arm64 with Dart 3.12.2. All four interactive commands use
`TerminalMode.inline` and `exitApp()`. The native host measures the matrix's
content after layout and adjusts the region between 8 and 24 rows, bounded by
the terminal. Larger content scrolls; short terminals compact their footer.

- The current pass has 118 passing installation/init/CLI/Git regression tests.
  Provider and UI tests were rerun after the final Homebrew path refinement
  (20 passing). Coverage includes single-project completion, multi-project
  continuation, failed operations, cancellation, and init's unavailable choices.
- The compiled executable passed 16 native PTY sessions in
  `check_installation_tui.py`: install without routing, use Local and execute its
  command, uninstall confirmation/cancel/removal, init review/Back/Create, all
  four commands at 40×18 with resize, and use/init with Ctrl+C, SIGINT, SIGTERM,
  and SIGHUP.
- `check_installation_ux.py` adds 16 native sessions: active/hover/keyboard states,
  unavailable reasons, `NO_COLOR`, multiple projects and `-p`, install/uninstall
  including empty inventories and the first usable row, multi-package init, and
  completing every command at 40×12, and a provider-call spy proving idle
  Ctrl+C does not reinspect installations. Two further cases exit use/init while a resize query is pending.
  Each session checks restoration and retained shell history.
- Terminal-buffer frames were inspected on dark and light rendering backgrounds.
  The page keeps the terminal background; active choices use a green cell fill
  and navigation uses blue. Opening has no focused control; Enter cannot act
  until navigation or a click establishes focus. Hover leaves focus and
  styling unchanged. Matrices skip the invisible scroll-viewport stop;
  text-only configuration review retains keyboard scrolling.
  Reverse video and checkmarks preserve meaning without color. These renders
  are not screenshots of a physical terminal emulator.
- Dogfooding found and fixed lost keyboard focus after multi-project operations,
  success styling on unavailable choices, and init's footer crowding its choices
  out of a short terminal. Native assertions retain coverage for those failures.
- Every native session verifies terminal modes and input blocking flags are
  restored, the inline frame is cleared, no alternate screen or whole-screen
  clear is used, and mouse capture is restored. Signal exits retain 130/143/129.
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
output queue, and lets arrow navigation enter an unfocused group while respecting
reading order, skipped controls and focus traps. RK pins these fixes at
`12c60000`, ahead of upstream merge/hosted publication. The additional focus,
modal, navigator and button regression pass has 164 passing tests. Fleury passed 141 lifecycle/query regressions and its full
10-session native inline suite; both native before/after reproductions are
recorded in the upstream PR.

### Startup and dismissal measurements

A native PTY timed the first usable matrix and process exit after an idle
Ctrl+C. Three runs on this Mac, using the existing Homebrew cache and a
disposable RK installation root, measured:

| Launch | Open, median | Idle Ctrl+C, median |
| --- | --- | --- |
| Compiled RK | 0.92 s | 4 ms |
| `dart run bin/rk.dart` | 3.17 s | 42 ms |

Before this pass, idle Ctrl+C took 611 ms in the same native setup because the
CLI rescanned providers after the picker returned. That redundant scan is gone;
operations still refresh their results and wait for safe cancellation. A simple
fixture without Homebrew opens in about 130 ms compiled. These are local
measurements, not latency guarantees; fresh temporary Homebrew homes add cache
initialization work.

Startup reads just the Git origin instead of twelve release-preflight queries.
Homebrew inspection now checks exact installed tap names, reads only the matching
formula, and uses its canonical name with the cheap cellar-root query. The broad
`info --installed` query omitted this host's unlinked RK keg in the isolated-home
check; targeted inspection reports version 0.1.9 correctly. Opening time should
not be presented as a before/after speedup across that change: the inventory now
includes the installation it previously missed. Source execution adds roughly
2.25 seconds here; changing Local to a cached native build is separate work.

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


## Native hook local launch qualification (2026-10-05)

The local launcher now prepares hooks from the selected Dart project, then
restores the caller directory and launches its original entrypoint. A real
transitive C-library fixture verified cold native loading, rebuild after editing
C source, arguments with spaces and dollar signs, stdin, nonzero exit status,
uncaught errors, compile-time defines, and Platform.script. Installation
resolution also accepts development dependencies while ordinary release
resolution continues to reject them.

Analysis passed. The affected installation, resolver and review-regression tests
passed (119 tests across the focused run and the four-case CLI rerun). The CLI
fixture now compiles rk once before invoking real subprocesses; repeatedly
compiling it for every argument check timed out under local machine load.
The broad repository run was stopped after unrelated timeout failures and does
not constitute a full-suite pass. Native hooks do not qualify release artifact
staging, signing, or physical hardware behavior.

Rechecked on 2026-10-07 with main (rk 0.1.14) merged in, locally on an Apple M1
Pro with Dart 3.12.2:

- The full suite passed: 1,953 tests, one skipped.
- The three terminal checks passed against a compiled binary.
- With the bootstrap disabled, the native fixture fails as the change describes
  (`No available native assets`), so the test exercises the fix.
- The macOS CI run of 2026-10-05 stopped at the installation-UX check's Ctrl+C
  step while a provider check was still showing; that check passed locally.
