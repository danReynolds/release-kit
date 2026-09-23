# Dart artifact verification — 2026-09-21

Local verification of `codex/dart-artifact-bundles`, based on rk commit
`2ecabe0`. This covers the generic rk producer and synthetic programs. It is
not a Keybay release qualification. The live Apple receipt below covers the
synthetic bundle submitted with the merged RK implementation.

## Automated checks

- Full suite after review fixes: **1,081 tests passed** on macOS 26.2 (25C56),
  ARM64, Dart 3.13.4.
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
- Review regressions cover a stable bundle implementation identity even when
  invoked from its module directory, and selecting the Dart SDK rather than
  RK's own executable for the pub.dev availability check.

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

## Live Apple notarization

After the earlier inconsistent Keychain lookups, an elevated retry succeeded
with the existing `rk-notary` profile. The merged RK notarization step submitted
the complete signed synthetic bundle, received **Accepted**, and retained both
Apple's result and log. No credentials were created or changed.

- Submission: `016edcfc-2e91-4b21-b3ee-63be3687b492`.
- Result SHA-256: `edd13d0ff9a744dbeb88d0985a730cd7cec0fe99aaf80800511f560f47cab2cc`.
- Log SHA-256: `f87cc1fb4b08248d7994d2b6897bf54029fad0185572c60c16edad06373aaf6c`.

PR #77 merged after final-commit format/analysis and test CI passed on Ubuntu
and macOS. Local review fixed two installed-CLI regressions. The requested
GitHub Codex review did not return a response.

## Qualification boundary

No package, GitHub release or Homebrew tap was published during the synthetic
checks recorded here. Each real release needs its own stage and installation
checks; this report does not qualify Keybay's installed upgrade or security
behavior.

RK [0.1.12](https://github.com/danReynolds/release-kit/releases/tag/v0.1.12)
was subsequently published on 2026-09-23. That later release is separate from
the synthetic evidence above.
