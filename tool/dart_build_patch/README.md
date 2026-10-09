# Temporary Dart native-build helper

An opt-in macOS ARM64 preview of the small SDK patch proposed in
[dart-lang/sdk#64556](https://github.com/dart-lang/sdk/issues/64556). It adds
compile-time declarations and separate AOT output to Dart's existing
hook-aware CLI builder. This is an RK-distributed patched command, not an
official Dart SDK release.

Download the binary or source archive from the
[preview release](https://github.com/danReynolds/release-kit/releases/tag/dart-build-patch-3.13.5-1).
Verify the downloaded archive against `SHA256SUMS` before extracting it.

Only Dart **3.13.5**, SDK revision
`04bcd1036cdc799ac6564988f159ee454d42c822`, on **macOS ARM64** is qualified.
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

**This helper does not yet add native release bundles to `rk stage` or
`rk release`.** That integration remains separate work. The preview unblocks
the SDK prerequisite; it is not a Keybay release or Linux qualification.
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

Actual Keybay upgrade identity,
notarization, native Linux targets and Homebrew installation remain outside
this preview's qualification.
