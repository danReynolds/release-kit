# Temporary Dart native-build helper

An opt-in preview of the small SDK patch proposed in
[dart-lang/sdk#64556](https://github.com/dart-lang/sdk/issues/64556). It adds
compile-time declarations and separate AOT output to Dart's existing
hook-aware CLI builder. This is an RK-distributed patched command, not an
official Dart SDK release.

Download the binary or source archive from the
[preview release](https://github.com/danReynolds/release-kit/releases/tag/dart-build-patch-3.13.5-1).
Verify the downloaded archive against `SHA256SUMS` before extracting it.

Only Dart **3.13.5**, SDK revision
`04bcd1036cdc799ac6564988f159ee454d42c822`, is supported. The published binary
is for **macOS ARM64**; the source also rebuilds on **Linux ARM64 and x64**
using this checkout's updated wrapper and rebuild script.
Use the official matching SDK from the
[Dart archive](https://dart.dev/get-dart/archive). The helper refuses other
versions and hosts. Keep your usual SDK and RK installation as they are.

From the application package, after resolving its locked dependencies:

```sh
/path/to/dart-sdk/bin/dart pub get --enforce-lockfile
/path/to/rk-dart-build /path/to/dart-sdk \
  --format=aot-snapshot -Dkeybay.application_id=keybay-cli \
  -t bin/keybay.dart -o /tmp/keybay-build
```

The arguments following the SDK directory are `dart build cli` options.
`--format=exe` remains the default. `-D` accepts repeated or comma-separated
declarations with the same semantics as `dart compile`; a comma is a separator,
not part of a declaration value. `--help` lists the options. The wrapper
preserves the working directory, environment, arguments and build exit code.
It calls the SDK command implementation, compiler and hooks. It does not
replace files in the SDK. Experimental data assets and recorded-use
tree-shaking are outside this preview.

The output is `bundle/bin/<entry>.aot` with native assets under `bundle/lib/`.
For AOT output, the caller must supply the matching `dartaotruntime` in
`bundle/bin/`. On macOS, give that runtime an `@executable_path/..` rpath before
signing it, and preserve the relative layout. Signing, library constraints,
notarization, archiving and installation belong to the release pipeline.

RK uses this helper through `RK_DART_BUILD_TOOL`, falling back to
`rk-dart-build` on `PATH` when the stock SDK lacks required options. See
[CLI artifacts](../../doc/cli-artifacts.md) for native bundle releases and
Linux image requirements. The helper by itself does not sign or release an
application.
Remove this directory and use the official command once the SDK supports both
options and passes the same release checks. There is no automatic SDK manager,
background update, startup hook or persistent helper cache.

## Rebuild and provenance

The source archive includes the exact compiler-reported source closure,
relative `package_config.json`, SDK patch, pinned repository revisions in
`PROVENANCE.json`, the SDK's `DEPS`, and license notices. The binary archive
contains the command snapshot, wrapper, patch, provenance and notices.

Extract the source archive into a fresh directory and run:

```sh
./rebuild.sh /path/to/dart-sdk
```

This compiles the helper from the included sources without `pub get`, a Pub
cache, network resolution or the original SDK source checkout. Source
rebuildability is promised; byte-identical AOT snapshots are not.
The compiler/runtime come from the matching stock SDK. Applications still
need their normal locked dependencies and native build tools.

### Linux build images

Use the source archive from the preview release. Its original scripts only
allowed macOS; copy this checkout's `rk-dart-build` and `rebuild.sh` over those
two files in the extracted source directory. Rebuild **inside each target
environment** with its matching Linux Dart 3.13.5 SDK. Keep `build.aot` and the
wrapper together, and put the wrapper on the image's `PATH`.

For example, after verifying and extracting the source archive into `helper/`
and copying the updated scripts, a build image can extend your existing
Dart/native-tool image:

```dockerfile
FROM your-native-build-image
COPY helper /opt/rk-dart-build
RUN /opt/rk-dart-build/rebuild.sh /path/to/dart-sdk
ENV PATH="/opt/rk-dart-build:$PATH"
```

Build that image for `linux/arm64` and `linux/amd64` (native builders or
configured emulation), tag the results `my-dart-build:arm64` and
`my-dart-build:amd64`, and set `RK_DART_BUILD_IMAGE='my-dart-build:{arch}'`.
RK mounts its staged sources and output, runs locked resolution and hooks in
the selected image, and removes the container after the build. There is no
shared container package cache or image construction performed by RK.

To prepare a new copy of this preview, check out the pinned SDK source and
its `DEPS` revisions, apply `doc/archive/native-assets-sdk.patch`, compile
`main.dart.in` (copied as `main.dart`) with the SDK source package map and
`--depfile`, then run `package.py` with the paths documented in its header.
Rebuild the exported source closure before packaging; do not ship a snapshot
built against incidental Pub-cache dependencies.

## Qualification

Observed on macOS ARM64, 2026-10-09:

- Four SDK tests pass: existing default/verbose and new executable/AOT cases.
- The exported source bundle rebuilds with network, Pub cache and original
  source/dependency checkouts denied by the sandbox.
- The rebuilt release helper builds an independent native C fixture in both
  formats. After relocation, both call the library, return 42 and retain
  string/integer/boolean declarations, including an equals sign in a value.
- A mismatched SDK is refused with exit 64; invalid options retain exit 64,
  and a missing entry point retains the SDK build error, exit 255.
- The release helper builds the real Keypass adapter. After Developer ID
  signing and archive relocation with development paths denied, it returns
  ABI 1, the native worker's `invalidRequest`, and the configured identity.
  All seven signatures verify; replacing a library with a validly signed
  same-team library is rejected by the process's library constraint.
- The stock SDK command snapshot remains byte-for-byte unchanged.
- RK formatting and analysis pass, along with 1,088 functional tests and
  8 publication tests (one environment-dependent functional test skipped).

Subsequent RK integration qualification covers native fixture relocation on
macOS ARM64 and both Linux architectures, plus a Homebrew install that preserves
all code bytes and calls the native adapter. See
[the integration record](../../doc/archive/native-bundle-integration.md) for
release pipeline evidence and remaining application-level boundaries.
