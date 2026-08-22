# Changelog

## Unreleased

- Status no longer reports local binary archives as unstaged after an exact
  public target has already bound every archive in the completed release.
- Standalone macOS notarization verification examples now ask codesign to
  perform its required online ticket check.
- Single-architecture Homebrew releases now declare explicit OS and CPU
  requirements, so unsupported hosts receive the real compatibility refusal
  instead of a misleading missing-URL error.
- Successful staging prints its exact repository-relative directory instead
  of wrapping a long absolute checkout path, and RK's repository-local release
  helper advances both version declarations together.

## 0.1.8

- Homebrew is now Formula-only throughout inspection, staging, manifests, and
  tap updates. RK no longer reads, converts, or removes legacy Cask state.
- Binary and Homebrew initialization now defaults to the current host's native
  platform, so a Linux host does not silently propose a macOS artifact it
  cannot produce. Cross-builds remain explicit configuration choices.
- Docker and Podman capability probes are bounded and run only for releases
  that ship binaries. Missing or unresponsive runtimes remain optional and
  degrade cross-build smoke evidence instead of blocking publication.

## 0.1.7

- Homebrew releases now use a Formula, the native installation surface for a
  command-line tool, so freshly downloaded signed binaries run under macOS
  Gatekeeper instead of being rejected as an unstapled Cask artifact.
- The first Formula publication compare-and-swaps both tap coordinates in one
  commit: it creates `Formula/<name>.rb` and removes only the exact legacy
  `Casks/<name>.rb` that rk inspected.
- Release manifests now describe a generic Homebrew binding while retaining
  read compatibility with the public schema-6 Cask manifests.
- Native and containerized binary smoke tests now have a finite deadline, so
  a wedged runtime or credential helper cannot hold staging indefinitely.

## 0.1.6

- Pub publication confirmation now reads the immutable version coordinate
  rather than waiting for the package-history listing to catch up.
- Successful Pub uploads are given the service's documented ten-minute
  propagation window before rk reports that it lost sight of the result.

## 0.1.5

- Status now distinguishes a valid historical release tag from current source
  that still declares the released version, keeps the public target healthy,
  and directs the next release to bump rather than move an immutable tag.
- Target conflicts now carry structured, target-owned diagnostics and evidence
  while core retains the small shared lifecycle and reporting contract.
- Pub package warnings survive reusable stage receipts, raw provider failures
  are separated from recovery instructions, and cross-built binaries that were
  not executed are disclosed before release authorization.
- Published package evidence states why archive bytes were not compared, and
  already-released source no longer produces a misleading unstaged-artifact
  section.

## 0.1.4

- macOS signatures are verified again after the signed executable smoke test
  and against the executable decoded from the final release archive. A release
  now stops before publication if either final-artifact boundary fails.
- Stage schema 10 records and validates archive-extracted signature evidence,
  so a reusable stage cannot claim the stronger macOS gate without having run
  it.

## 0.1.3

- Staging and publication now run from validated dependency graphs. Independent
  work starts in parallel, and dependent targets unlock as soon as their own
  prerequisites finish instead of waiting for unrelated targets.
- Stage artifact inputs are checked against their producers, platform build
  lanes keep isolated scratch space, and failures stop new work while draining
  operations that have already started to a known result.
- Release progress remains on one coordinated target board, including concise
  waiting-on-prerequisite status, while captured provider output no longer
  disrupts the display.
- The target documentation now explains the shared graph, lifecycle-specific
  execution policies, and the minimal extension boundary for adding target
  N+1 without target-specific scheduler hooks.

## 0.1.2

- Release targets now live in small vertical slices behind a compact module
  contract. GitHub Release is the worked example for adding an N+1 target,
  while provider transactions remain private to their target.
- Release orchestration is split into preparation, staging, and publication
  coordinators. Targets describe their plans and observations; core retains
  ordering, authorization, reconciliation, and reporting.
- Concurrent platform builds use isolated producer lanes, and subprocess
  deadlines now cover process exit plus inherited output streams.
- Core CI runs formatting, static analysis, and the complete test suite on
  Ubuntu and macOS.

- Signed macOS binaries now start. The hardened runtime refuses the executable
  pages a Dart AOT snapshot maps at launch, so 0.1.0's binary was killed by the
  kernel before it printed anything — while its signature verified, its
  notarization succeeded, and Gatekeeper reported it as accepted. Signing now
  grants `com.apple.security.cs.allow-unsigned-executable-memory`, the one
  entitlement that fixes it.
- The signed binary is executed before a release can proceed. The smoke test ran
  at build time, so it proved the built binary worked and signing then broke it
  unobserved; a binary that will not start now fails the release (`RK-SIGN-014`).
- A bare designated-requirement identifier is read, not only a quoted one. rk's
  own identity prints unquoted, so rk could recognise every other project's
  published identity and not its own — which surfaces on a second release and
  never a first.
- Failure and publish evidence is retained where it was previously dropped, and
  a run nobody is waiting on no longer stops to ask.

## 0.1.0

Initial release of rk, a release tool.

- Three operational verbs: `status`, `init`, and `release`, plus the static
  `target` reference; public reality is the release record and re-running is
  the resume.
- Releases to pub.dev, GitHub Releases and a Homebrew tap, with signed and
  notarized macOS binaries, cross-compiled Linux binaries, notarization
  evidence published beside the archives, and a manifest binding every asset
  and Homebrew Cask.
- `release --stage` runs every private step for real — package preflight,
  build, sign, notarize, archive, notes, manifest, and Cask —
  and records exact reusable artifacts without publishing them.
- `status` and `release` share exact target inspection for Git tags, pub.dev,
  GitHub Releases, and Homebrew; every public act is inspected before and
  after, and a retry skips targets already published.
- Target rows show `✗` for any concrete issue linked to that target. Status has
  no synthetic authentication verdict: unsupported safe checks stay silent
  until release preflight.
- A normal interactive release runs one native `dart pub login` after private
  staging and before authorization when an unfinished pub.dev target exists;
  `release --stage` never logs in. Login proves a session, while publish plus
  public read-back remains the proof of package authority and completion.
- Compiled binaries report their embedded package version with `rk --version`
  so staging and downstream package managers can reject stale artifacts.
- Human status keeps diagnostic codes in JSON, distinguishes nonblocking
  warnings, and reports a local version succinctly as `behind` public reality.
- pub.dev package history is checked against the repository declared by the
  local pubspec, so a name owned by another project is reported directly.
- Dirty Git working trees may release registry-only or local outputs through
  an exact unbound snapshot; Git-identified targets still require clean source.
- Versioned publications are append-only: Pub stages and uploads one native
  archive, retained native digests catch known divergence, and occupied
  historical coordinates are never rebuilt or overwritten. Homebrew remains
  a forward-only channel updated by compare-and-swap and can recover from the
  authenticated public GitHub asset set when its local stage is gone.
