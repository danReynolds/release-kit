# Dart artifact verification — 2026-09-21

Local verification of `codex/dart-artifact-bundles`, based on rk commit
`2ecabe0`. This covers the generic rk producer and synthetic programs. It is
not a Keybay release qualification or an Apple notarization receipt.

## Automated checks

- Full suite: **1,080 tests passed** on macOS 26.2 (25C56), ARM64, Dart 3.13.4.
- `dart analyze`: no issues.
- `dart format --output=none --set-exit-if-changed .`: unchanged.
- `git diff --check` and the diagnostic-code index check: passed.
- The native launcher test compiles and runs a real Dart bundle, relocates it,
  invokes it through a symlink outside its directory, and checks arguments,
  compile-time metadata, process ID, SIGTERM handling and exit status.
- Artifact tests reject missing companions, wrong modes, extra payloads and
  altered manifests. Receipt tests reject changed modules, recaptured bytes
  without matching signature evidence, missing signatures and different
  certificates. Published-identity tests cover single executables and bundles.
- A wrapper test and a local check using Flutter's `bin/dart` both resolve the
  actual SDK compiler/runtime pair.

## Local signed macOS check

A synthetic `tool` program was compiled with the same builder and signed through
`MacOsSigner` using the existing Developer ID certificate. The launcher,
`dartaotruntime` and AOT module each verified. Their identifiers were
`dev.example.rk.bundle.launcher`, `dev.example.rk.bundle`, and
`dev.example.rk.bundle.app`; the runtime retained the base process identity.

The signed command worked through a symlink with `/` as its working directory.
It reported version `1.2.3`, preserved `['a b', '', '$c']`, read its compile-time
identity and returned exit code `7`. Entitlements were empty. Replacing the
module with an ad-hoc-signed copy made launch fail with exit code `255`; the
original signed module was then restored.

The actual `BinaryChain.archiveStep` packed all five artifact files, decoded
and extracted them, verified all three code signatures and ran the extracted
command successfully. The runtime license traveled with the bundle.

## Linux check

The same synthetic program compiled into single executables for `linux-x64`
and `linux-arm64`. Each ran and reported the expected version through Docker
29.6.1 using `debian:bookworm-slim` and the corresponding container platform.
These are container execution results, not native Linux desktop qualification.

## Remaining external checks

Apple notarization was **not run**. Preflight found no Keychain credential
profile named `rk-notary`; no new credentials were created. Tests exercise
complete-payload submission, Accepted/log receipt binding and failure handling.
Live Apple acceptance and installed Keybay upgrade/security qualification still
belong to release preparation. No package, GitHub release or Homebrew tap was
published during these checks. Hosted CI and independent PR review have not run
for this change.
