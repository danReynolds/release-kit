# Changelog

## 0.1.1

- Signed macOS binaries now start. The hardened runtime refuses the executable
  pages a Dart AOT snapshot maps at launch, so 0.1.0's binary was killed by the
  kernel before it printed anything — while its signature verified, its
  notarization succeeded, and Gatekeeper reported it as accepted. Signing now
  grants `com.apple.security.cs.allow-unsigned-executable-memory`, the one
  entitlement that fixes it.
- The signed binary is executed before a release can proceed. The smoke test ran
  at build time, so it proved the built binary worked and signing then broke it
  unobserved; a binary that will not start now fails the release (`RK-SIGN-014`).
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
