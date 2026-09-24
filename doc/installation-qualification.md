# Installation and TUI implementation receipt

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
- **Linux native behavior.** Platform selection and archive behavior have fixture
  coverage; native terminal, shell, and package-manager qualification in this pass
  is macOS only.
- Custom Pub registries, private GitHub downloads, Windows, and shell aliases or
  functions overriding command names are outside this first implementation.
  POSIX shells receive a PATH command; automatic persistent setup is fish-only.

No public release was published, and the operator's installations and shell
configuration were not switched by this qualification.
