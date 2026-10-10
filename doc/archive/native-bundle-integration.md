# Dart native bundle integration qualification

Observed 2026-10-09 on an ARM64 Mac, using stock Dart 3.13.5
(`04bcd1036cdc799ac6564988f159ee454d42c822`) and the temporary build helper
from [SDK issue 64556](https://github.com/dart-lang/sdk/issues/64556).
This records local qualification, not an application publication.

## Scope and cost

Dart owns dependency resolution, hooks and native asset discovery. RK adds two
artifact layouts and carries their inventory through its existing producer
receipt, signing, notarization, archive and installation paths. No Keypass
plugin, configured library list, second hash inventory, SDK manager or new
persistent cache is introduced. The container adapter is a single build
invocation using the existing Docker/Podman capability probe and an image the
operator supplies. Its shell script is fixed; application arguments remain
separate positional arguments.

An explicit locked Pub resolution lets RK discover dependency hooks from Dart's
production dependency graph before choosing the compiler. This adds a Pub invocation to fresh
builds; completed stages do not resolve, discover hooks or build again. In the
real three-target Keybay stage, those three host resolutions took 1.95 seconds
in aggregate and ran in concurrent build lanes. Container targets also resolve
inside their own environment so host cache paths cannot enter their hooks.

Final signed files are hashed once into the existing receipt. Later interrupted
stages verify them; completed stages verify only public artifacts. The tests
delete an expanded library after stage completion and still reuse the stage,
while changing it before completion makes the stage broken.

## Observations

| Exercise | Result |
|---|---|
| Independent C hook fixture, macOS ARM64 | Archive relocated, source/build deleted, symlink launch returned `42` and the configured declaration; removing the native library failed |
| Same fixture, Linux ARM64 and x64 | Same result in `debian:trixie-slim`, network disabled, only the extracted bundle mounted |
| Actual Keypass 0.1.0-dev.2, all three targets | Relocated adapter returned ABI 1, its worker returned `invalidRequest`, and the compiled identity survived |
| Keypass macOS signed bundle | All seven code signatures verified; Apple notarization accepted; adapter ran with SDK, Pub cache and Homebrew paths denied |
| Same-team substitution | A modified native library with a valid signature from the same Developer ID was refused by the runtime's library constraint |
| Homebrew native fixture | Installed through a temporary tap, all code bytes unchanged, native adapter returned 42 through the installed command; probe tap and keg removed |
| GitHub installation tests | Schema-1 and schema-2 archives extract with exact modes; a native Linux `bin/` entry remains launchable when rediscovered |
| Interrupted stage tests | Dynamic outputs survive producer recording, library changes refuse reuse, notarization and archives contain exactly the inventory |
| Review regressions | An independent nested CLI builds despite an unrelated parent lock and a failing dev-only hook; workspace resolution overrides select the correct lock; Linux build arguments preserve caller ownership |
| Non-root Linux helper | Built and ran the native C fixture as UID 1000/GID 1001 with temporary HOME/Pub cache, verified output ownership and removed build/hook outputs successfully |

The Keypass worker probe submits an invalid operation; it does not create,
unlock or change a vault, request a passkey, or interact with a security key.
Linux build images needed Keypass's documented libfido2 >=1.16 prerequisite;
Debian's package alone was too old. Qualification used libfido2 1.17.0 and
OpenSSL 3, with the helper rebuilt from its source closure for each target.
The RK implementation knows none of those application-specific dependencies.

## Normal Keybay workflow and timing

A clean private clone of Keybay commit
`26ffd27a856a448c84885495898cc7c53afef3c1` ran:

```sh
RK_TIMINGS=1 rk stage keybay_cli --timings
RK_TIMINGS=1 rk stage keybay_cli --timings
```

The first run staged all declared macOS ARM64, Linux ARM64 and Linux x64
archives, a release manifest and the Homebrew formula. The macOS runtime's
designated requirement matched the previously published Keybay release, its
signed command ran, and Apple accepted notarization. Nothing was published.

- Fresh run: **55.9 seconds**, including remote reads, build/sign/notarize and
  archive production. Build lanes took approximately 28s ARM64 Linux, 48s x64
  Linux under emulation, and 47s macOS including notarization.
- Same commit repeated: **2.14 seconds**, mostly remote reads. Stage inspection
  took **0.201 seconds**, hashing seven public artifacts totaling **22.3 MB**.
  There were no compiler, signing, hook, container or notarization calls, and
  no expanded-library reads.
- Fresh-stage SHA-256 work: **0.765 seconds**, 27 recorded outputs totaling
  **78.3 MB**. This includes expanded final binaries and public archives at
  their existing receipt boundaries; the manifest contains no duplicate hashes.

These are one-machine observations, not a before/after speedup claim: RK could
not previously complete this native-asset release. The value of the added
code is correct complete releases; stage reuse keeps its existing cost model.

## Repeating the checks

The normal functional suite runs the real native fixture on Linux with stock
Dart, as well as deterministic receipt, archive and installation tests. On a
Mac with the qualified helper and Linux images, add:

```sh
export RK_DART_BUILD_TOOL=/path/to/rk-dart-build
export RK_DART_BUILD_IMAGE='my-dart-build:{arch}'
export RK_NATIVE_TEST_DART=/path/to/dart-sdk/bin/dart
RK_NATIVE_TEST_PLATFORMS=macos-arm64,linux-arm64,linux-x64 \
  dart test test/native_bundle_integration_test.dart --concurrency=1
# Uses a temporary Homebrew probe tap/keg; choose a suitable test host.
RK_BREW_INSTALL_TEST=1 dart test test/homebrew_install_test.dart
```

Formatting, analysis, 1,100 functional tests and eight publication tests passed
locally. The normal Mac suite skipped two environment-dependent checks; native
relocation and Homebrew were additionally enabled and passed as described above.

Independent review found and prompted fixes for unrelated ancestor lockfiles,
development-only hook discovery and Linux container output ownership. Pub's
own dependency graph now scopes hook discovery. Lock selection follows Pub's
workspace-resolution rule including overrides. Linux containers use the
operator's UID/GID and temporary home/cache; Podman's documented
[`keep-id` mapping](https://docs.podman.io/en/latest/markdown/podman-run.1.html#userns-mode)
preserves those IDs under rootless operation. The Podman argument path is
covered deterministically; a live rootless Podman run was not qualified here.

Application gates remain separate: actual Keybay credential migration and vault
operations, a published upgrade, and broader Linux distribution compatibility
are not established by this work. Build native libraries on the oldest runtime
baseline the application intends to support. RK's `--version` smoke test is
still only a launch/version check; the native adapter qualification above is
the stronger acceptance evidence.
