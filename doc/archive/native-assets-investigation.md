# Native Dart release bundles: macOS experiment

Observed 2026-10-09. RK `b259d34` (including Local PR #115), Keybay
`26ffd27`, hosted Keypass `0.1.0-dev.2`, macOS ARM64. The installed SDK was
Dart 3.12.2; Dart 3.13.5, the current stable release, was downloaded into a
disposable directory for comparison. No production release code changed.

## Decision

Extend the existing Dart builder and artifact contract. The value is a working
native release, and most of the signing, archive and installation machinery
already exists. Keep native compilation in Dart's hook pipeline and retain
RK's separate runtime/AOT arrangement and empty-entitlement signing policy.

There are two SDK prerequisites for a clean implementation: application
defines must reach compilation, and hook-aware builds must expose separate AOT
output. Current `dart build cli` provides neither. Resolve those through a
supported SDK interface before adding production integration. The experiment's
Mach-O payload extraction is a feasibility probe, not a proposed RK feature.

## Follow-up: SDK prerequisite implemented locally

A disposable checkout of SDK tag `3.13.5` (`04bcd1036cdc799ac6564988f159ee454d42c822`)
now has a small [proposed SDK patch](native-assets-sdk.patch):

- Expose `-D` / `--define` in `dart build cli`, with the existing compile
  command's repeated and comma-separated declaration semantics.
- Expose `--format=aot-snapshot`, retaining `exe` as the default. The snapshot
  is emitted at `bundle/bin/<name>.aot`; the caller supplies the matching
  `dartaotruntime` in that directory, with the necessary macOS rpath.
- Pass these choices to the existing `KernelGenerator`; native hooks, linking
  and asset bundling still run through Dart's existing implementation.

The production command change is 28 added and 4 removed lines; two regression
cases add 65 test lines. The command snapshot was rebuilt and installed only
in the disposable SDK, then the stock snapshot was restored after qualification.
No RK runtime code depends on these proposed flags.
The patch targets the tested stable SDK tag, not a reviewed upstream interface.

Observed with the patched SDK:

- Existing default and verbose native-build tests pass. New executable and
  AOT tests preserve string, integer and boolean declarations, relocate the
  bundle and call the native add/subtract libraries: **four tests passed**.
- An independent C-addition hook fixture works as both an executable and an
  AOT snapshot, including multiple declarations and an equals sign in a value.
- The real Keybay CLI builds with `keybay.application_id=keybay-cli` and reports
  `0.2.0`. This is compilation/version evidence, not a Keybay release verdict.
- The real Keypass probe uses the directly emitted AOT snapshot, with no
  executable-payload extraction. After Developer ID signing, archiving,
  relocation and launcher/symlink execution, it returns ABI 1,
  `invalidRequest`, and the configured `rk-probe-defined` identity. Source,
  SDK, dependency cache, build and Homebrew paths are denied by the sandbox.
- All seven signed files verify. Replacing a library with a validly signed
  same-team library is still rejected by the process library constraint.

The SDK proposal and [upstream issue draft](native-assets-sdk-issue.md) are
local and unsubmitted. SDK maintainer agreement and an available supported
interface remain the next dependency. RK integration, native Linux target
qualification, actual Keybay identity-upgrade qualification, notarization and
real Homebrew installation remain outstanding. The user's installed Dart and
compiled Local RK were not changed.

## Hashing budget for the proposed RK integration

Extend the existing stage receipt with the native files actually shipped.
Record their final signed bytes once when the build finishes. Reuse recorded
hashes while metadata is unchanged within that run. A later interrupted-stage
resume verifies its recorded outputs; a completed stage continues to verify
published archives and other public outputs, without unpacking libraries.

The bundle manifest describes paths, roles and modes; it does not duplicate
receipt hashes. macOS code-directory hashes come from `codesign` for the
existing library pins. No source-tree inventory, per-launch verification,
additional persistent cache or new hashing subsystem is proposed.

Using RK's unchanged `Sha256.file` in a compiled probe, the four SDK-produced
Keypass libraries total 5,457,280 bytes. Their combined hash time was 49.7 ms
on the first measured pass and a 46.6 ms median over nine warmed passes after
three warmups. The existing implementation uses a 64 KiB buffer. This measures
hashing only; signing, archiving and complete-stage timings still need an
implementation benchmark. Raw results are in
`.dart_tool/native-bundle-investigation/hash-cost.json`.

## Initial stock-SDK reproduction

| Check | Observed result |
| --- | --- |
| Current `DartCliBuilder`, clean Keybay commit and enforced lockfile, both SDK versions | Fails: `dart compile` does not support build hooks; package `keypass` |
| Add a native library to today's `BinaryArtifact` manifest | Rejected: description differs from its fixed layout |
| Standard `dart build cli` consumer of real Keypass | Builds the adapter, libfido2, OpenSSL and CBOR libraries; native ABI/request succeeds |
| Dart 3.13.5 `build cli -Dkeybay.application_id=...` | Argument rejected, exit 64 |
| Dart 3.13.5 `-Dkeybay.application_id=... build cli` | Build succeeds, but the program reads the default `MISSING` value |
| SDK executable signed with Developer ID, hardened runtime, empty entitlements and library pins | Signature verifies; execution receives SIGKILL, including `--version` |
| Separate runtime/AOT prototype, same policy, module and four libraries pinned | Version and real native request succeed |
| Archived prototype extracted elsewhere, through an RK-style launcher and symlink, with development paths denied | Native request succeeds |
| Replace one native library with a different, validly signed same-team library | Native load rejected by the process's library load constraint |

The native request checks ABI version 1 and sends an invalid operation through
Keypass's real worker, receiving `invalidRequest` with no secret bytes. It
exercises native loading and libfido2 initialization without device I/O, a PIN
request, a passkey ceremony or vault access. `--version` alone bypasses this path.

## Initial macOS extraction experiment

The SDK emits an executable containing an AOT payload. In a disposable copy,
the experiment extracted the payload identified by the executable's
`__dart_app_snap` load command and ran it with the same SDK's `dartaotruntime`.
It preserved the SDK's `bin`/`lib` relative layout and added the executable rpath
that the SDK build normally supplies. This isolated the packaging question from
the missing public AOT-output option.

The module and every generated library were signed first. Their final code
directory hashes were pinned in the runtime's signature using RK's existing
constraint structure. The small RK launcher was reused with adjusted companion
paths, preserving the SDK directory structure under `lib/probe`.

Signing used Developer ID with hardened runtime, empty entitlements and no
timestamp for this local experiment. After archive extraction, `sandbox-exec`
denied reads from the source directories, build directories, pub cache and
Homebrew. The native request still succeeded from an unrelated working
directory through the command symlink. A control read confirmed the sandbox
actually denied the development library. A changed library's signature still
verified, but the runtime refused its new code hash.

That initial extraction prototype reports `MISSING` for the application define. It proves
the macOS packaging and pinning approach, not a complete Keybay release.

## Smallest coherent RK change

1. **Dart builder:** use the supported hook-aware compilation path in the staged
   package with locked dependencies, preserving all configured defines. Keep
   the process's existing designated requirement when assembling macOS output.
2. **Artifact inventory:** introduce a versioned native-bundle layout derived
   from build output. Validate relative paths, file types, modes and command
   entrypoints; keep existing archive layouts readable. Developers should not
   enumerate native library filenames in configuration.
3. **Stage and consumers:** carry the actual build inventory into the existing
   receipt and through signing, notarization, archive validation and installation.
   `Stage.record` currently hashes the statically planned `Work.outputs`; changing
   only `BinaryArtifact` would leave generated libraries outside that receipt.
   Later steps must read the recorded inventory instead of reconstructing a
   fixed layout from the platform.
4. **Target environment:** build hooks need a compatible OS, architecture and
   native toolchain. Keypass explicitly refuses foreign OS/architecture builds.
   RK's current Linux cross-compilation path runs hooks on the host and uses a
   container only for smoke tests; it cannot supply this native build contract.
   Reuse local/container execution where suitable and report missing target
   prerequisites before building. A remote worker service is not part of this
   proposal.

Homebrew already installs the whole archive under `libexec`, links its command
and preserves rpaths. Preserve this approach, adapting the command entrypoint
if the new layout requires it. A real isolated Homebrew install still needs
qualification; the experiment tested the symlink arrangement only.

## Remaining release acceptance

- Supported compilation preserves Keybay's application ID and native assets.
- Real Keybay archive exercises its adapter after relocation with development
  paths denied, and retains the published macOS identity across an upgrade.
- Native Linux x64 and ARM64 builds have suitable toolchains and pass the same
  installed-artifact check.
- The complete signed inventory survives notarization, stage recovery,
  Homebrew installation and GitHub installation. No notarization or publication
  was performed in this investigation.

Evidence and probe scripts are retained locally in
`.dart_tool/native-bundle-investigation/`; the original disposable build tree is
`/private/tmp/rk-native-bundle-investigation`. The SDK hook cache was kept separate
per SDK after a reused 3.12 kernel failed under 3.13; the reported 3.13 build uses
a fresh package directory.

Primary references: [Dart build contract](https://dart.dev/tools/dart-build),
[Dart 3.13.5 build implementation](https://github.com/dart-lang/sdk/blob/3.13.5/pkg/dartdev/lib/src/commands/build.dart),
[Dart 3.13.5 AOT/executable generation](https://github.com/dart-lang/sdk/blob/3.13.5/pkg/dart2native/lib/generate.dart).
