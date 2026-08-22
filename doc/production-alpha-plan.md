# Production release readiness

Status: completed for `rk 0.1.4` on 2026-08-21. The exact evidence is in
[production-alpha-receipt.md](production-alpha-receipt.md).

This document is the maintained release-readiness protocol for rk itself. It
replaces the implementation-era alpha checklist. The detailed design history
remains in [plan.md](plan.md) and the RFCs.

## What ready means

rk is ready for supervised use when all four proof levels pass. They answer
different questions and none substitutes for a later level.

1. **Implementation:** formatting, static analysis, and the full test suite
   pass on Linux and macOS CI.
2. **Private stage:** one source-bound stage contains every package, binary,
   archive, manifest, signature, notarization result, and rendered formula needed
   by the configured targets.
3. **Public reconciliation:** every published target reads back as an exact
   match for the intended source and staged bytes. A retry performs no public
   work.
4. **Clean consumption:** independently installed copies from pub.dev, a
   GitHub Release, and Homebrew execute and can inspect the released project.

`rk 0.1.4` passed all four levels. That is evidence that the current target
set and release lifecycle work end to end; it is not a promise that every
future provider failure can be anticipated.

## Supported product surface

The supported commands are:

```text
rk init
rk status [unit]
rk release [unit] [--stage]
rk target list
rk target <name>
rk clean
```

The built-in targets are Git tag, pub.dev, GitHub Release, Homebrew, and
standalone binary archives. Targets declare their stage and publication
dependencies; the coordinators validate the graph, run independent ready
nodes concurrently, and keep target-specific provider logic in the target
module.

The important safety contract is:

- `status` is online and read-only;
- `release --stage` may build, sign, notarize, and contact private services,
  but performs no public act;
- a normal release validates or creates the exact private stage before asking
  for authorization;
- public steps run only after their declared dependencies are exact;
- failures stop downstream dependants without serializing unrelated work;
- every public write is followed by provider read-back; and
- rerunning after an uncertain or partial outcome reconciles public reality
  and only resumes unfinished work.

## Release procedure

### 1. Establish the source boundary

Use a clean branch whose intended changes have passed review and CI. Confirm
the version and changelog, then inspect the plan:

```console
$ dart run bin/rk.dart status rk
```

Do not publish from an unreviewed or unpushed source commit when the release
uses Git-identified targets.

### 2. Create and inspect the private stage

```console
$ dart run bin/rk.dart release rk --stage
$ dart run bin/rk.dart status rk
```

For every archive, compare its SHA-256 with `release-manifest.json` and inspect
its inventory. A macOS executable must be checked from the final archive, not
only from the build directory:

```console
$ tar -xzf rk-<version>-macos-arm64.tar.gz -C <empty-directory>
$ <empty-directory>/rk --version
$ codesign --verify --strict --verbose=4 <empty-directory>/rk
$ codesign -R='notarized' -v <empty-directory>/rk
```

The stage contract also performs a signed smoke test, verifies the signature
again after execution, decodes the final archive, and verifies the signature
on those exact extracted bytes. Its receipt records all three checks.

### 3. Publish and reconcile

```console
$ dart run bin/rk.dart release rk
$ dart run bin/rk.dart status rk
$ dart run bin/rk.dart release rk --json
```

The final JSON retry must exit 0, contain no problems, and report every public
step as `exact` with `action: already_published`.

Provider acceptance and provider visibility are not always simultaneous. rk
confirms Pub through the immutable version coordinate and allows the service's
documented ten-minute propagation window. If that exact read still times out,
rk stops with an uncertain effect instead of allowing dependant publication
to assume success. Treat that as a safe-retry case; do not publish the
coordinate manually or discard the stage.

### 4. Consume public outputs

Use clean locations rather than the development checkout:

```console
$ PUB_CACHE=<empty-directory> dart pub global activate rk <version>
$ <empty-directory>/bin/rk --version

$ brew install danreynolds/tap/rk
$ rk --version
```

Also download one GitHub Release archive and its manifest, verify the archive
digest, extract it, and run the binary. On Apple Silicon, use the native
`/opt/homebrew` installation; rk currently ships its macOS binary for Apple
Silicon.

Each consumed binary should run `rk status rk` against a clean checkout. A
version print alone proves packaging, not that the shipped CLI can perform its
actual work.

### 5. Record the receipt

Update [production-alpha-receipt.md](production-alpha-receipt.md) with:

- the clean source commit, stage identity, and manifest digest;
- archive and package digests;
- signing certificate and Apple notary submission;
- exact public coordinates and the idempotent retry result; and
- clean-consumer results for pub.dev, GitHub Release, and Homebrew.

The receipt test is part of the default suite. When a later canary replaces
the receipt, update the evidence and its locked expectations together.

## Current boundary

The production canary establishes the current release promise well enough for
real supervised use. The following are useful future work, not blockers for
that promise:

- additional registry targets such as npm or RubyGems;
- additional binary platforms and architectures;
- unattended provider publication from hosted CI;
- signed Git tags as a required project policy; and
- broader failure-injection canaries against real providers.

Keep new target work behind the same bar: a small target module, explicit
dependencies, deterministic staged assets, exact public inspection, a safe
retry, and a clean-consumer receipt.
