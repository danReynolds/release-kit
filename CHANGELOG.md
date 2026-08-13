# Changelog

## 0.0.1

Initial release of rk, an austere release tool for Dart repositories.

- Three operational verbs: `status`, `init`, and `release`, plus the static
  `target` reference; public reality is the release record and re-running is
  the resume.
- Releases to pub.dev, GitHub Releases and a Homebrew tap, with signed and
  notarized macOS binaries, cross-compiled Linux binaries, notarization
  evidence published beside the archives, and checksums.
- `release --stage` runs every private step for real — package preflight,
  build, sign, notarize, archive, checksums, notes, manifest, and formula —
  and records exact reusable artifacts without publishing them.
- `status` and `release` share exact target inspection for Git tags, pub.dev,
  GitHub Releases, and Homebrew; every public act is inspected before and
  after, and a retry skips targets already proved exact.
- Target rows show `✗` for any concrete issue linked to that target. Status has
  no synthetic authentication verdict: unsupported safe checks stay silent
  until release preflight.
- A normal interactive release runs one native `dart pub login` before private
  staging when an unfinished pub.dev target exists; `release --stage` never
  logs in. Login proves a session, while publish plus exact read-back remains
  the proof of package authority and completion.
- Compiled binaries report their embedded package version with `rk --version`
  so staging and downstream package managers can reject stale artifacts.
