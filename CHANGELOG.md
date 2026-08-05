# Changelog

## 0.0.1

Initial release of rk, an austere release tool for Dart repositories.

- Four verbs: `status`, `init`, `release`, `verify` — inspect, act, verify,
  with reality as the only database and re-running as the resume.
- Releases to pub.dev, GitHub Releases and a Homebrew tap, with signed and
  notarized macOS binaries, cross-compiled Linux binaries, notarization
  evidence published beside the archives, and checksums.
- `--dry-run` runs every local step for real — build, sign, notarize,
  archive — and touches nothing public.
- `rk verify` proves a published release against its tag from any fresh
  clone: no state, no credentials, no `.rk/`.
