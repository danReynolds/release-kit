# CLI artifacts

`binary_platforms` selects where a Dart CLI runs. rk chooses its packaging;
there is no single-file versus bundle setting to maintain.

| Platform | Archive contents | Command |
|---|---|---|
| Linux x64 / ARM64 | One compiled executable | `tool …` |
| macOS ARM64 | Native launcher, matching Dart runtime, signed AOT module | `tool …` |

Without native hooks, Linux uses `dart compile exe`. macOS uses `dart compile aot-snapshot` and
copies `dartaotruntime` from that same SDK. It needs Xcode command-line tools
to compile the small launcher. A macOS archive looks like this:

```text
tool
lib/tool/dartaotruntime
lib/tool/app.aot
lib/tool/LICENSE.dart
rk-artifact.json
LICENSE                  # when present in the project
README.md                # when present in the project
```

The launcher finds its companions relative to its installed location, including
when invoked through a symlink. It replaces itself with the runtime, preserving
arguments, environment, process identity, signals and exit status. Keep the
extracted directory together when installing manually. Homebrew installs the
archive under `libexec` and links the command into `bin`; the same installation
rule works for Linux's single executable.

## Dart native code assets

When the package or a resolved production dependency has `hook/build.dart`, rk
uses `dart build cli`
from the staged package. Dart runs the hooks and supplies the application and
native libraries. rk preserves their relative paths and generates a schema-2
`rk-artifact.json` from the build output. There is no library list to maintain
in `release.toml`. Packages without hooks retain their existing layouts, and
schema-1 archives and stages remain readable.

Native Linux bundles contain `bin/tool`, `lib/<generated libraries>` and the
manifest. macOS retains its signed launcher and separate runtime:

```text
tool
lib/tool/bin/dartaotruntime
lib/tool/bin/app.aot
lib/tool/lib/<generated libraries>
lib/tool/LICENSE.dart
rk-artifact.json
```

The copied runtime has an `@executable_path/..` rpath so Dart finds those
libraries after installation. Homebrew preserves the complete directory under
`libexec` and links either the root launcher or `bin/tool`. GitHub installation
uses the manifest's entry point. Manual installs must keep the bundle together.

The machine needs a compatible build environment for each native target:

- Install the native tools and libraries required by the package hooks. rk
  resolves dependencies with `pub get --enforce-lockfile` when the staged
  package or workspace contains a lockfile. Commit that lockfile for locked
  releases; otherwise Pub performs normal resolution.
- Until Dart supports both separate AOT output and compile-time declarations
  in `build cli`, macOS native releases need the matching
  [temporary build helper](../tool/dart_build_patch/README.md). Set
  `RK_DART_BUILD_TOOL=/path/to/rk-dart-build`, or place it on `PATH`. Use the
  stock Dart 3.13.5 SDK that helper requires for rk's compiler. An upstream SDK
  exposing the required options will be used directly when no override is set.
- To build native Linux targets from another OS or architecture, start Docker
  or Podman and set `RK_DART_BUILD_IMAGE` to an image containing Dart and the
  package's hook prerequisites. `{arch}` in the name expands to `amd64` or
  `arm64`, for example `my-dart-build:{arch}`. With current Dart, an image also
  needs `rk-dart-build` on `PATH` when the project supplies Dart declarations.
  Each target builds in its own staged repository copy, using the selected
  platform and an independent container Pub cache. On Linux hosts it runs as
  the operator's UID/GID, with a temporary writable home/cache; Podman also
  uses its `keep-id` user namespace. The image must support
  `sh`, `grep`, and `readlink -f`. Pin images for reproducible build environments.

These are machine settings, not application-specific RK configuration. Once
prepared, the workflow remains `rk stage <unit>` and `rk release <unit>`.
Missing native build environments fail the build with a remedy; rk does not
silently try Dart's pure-code cross-compiler for native hooks.

The smoke test still invokes the application's `--version`; it is not a
functional native-adapter test. Applications should additionally exercise a
native call from a relocated archive with development libraries unavailable.
RK's integration fixture does this on each qualified target.

Homebrew rewrites each library's install name to its keg path and re-signs the
library ad hoc, which the signed runtime would refuse. The module therefore has
an `@rpath/app.aot` install name, and the generated formula declares
`preserve_rpath`, which keeps such names. Both are needed; this requires
Homebrew 4.6.17 or later. The formula has no bottle, so Homebrew installs it as
a source build and needs the Xcode Command Line Tools.

## One release contract

`BinaryArtifact` describes the entry point, relative paths, modes and files that
need signatures. Build receipts, notarization, archive verification and
installation use that description. The bundle manifest is generated metadata,
not an extension point for arbitrary paths or build hooks. rk refuses incomplete
bundles, extra payloads, unsafe archive entries and changed file modes.

Each macOS code file is signed with the selected Developer ID certificate and
hardened runtime. rk clears inherited SDK entitlements: neither unsigned
executable memory nor disabled library validation is needed for this layout.
The launcher and module receive `.launcher` and `.app` identifier suffixes. The
runtime retains the existing program identifier and designated requirement,
since it becomes the process that accesses OS services such as Keychain.
Previous single-file rk archives remain readable as the signing baseline.

Library validation admits any library signed by the same team, so a signed
runtime would otherwise run any module signed with that team's certificates.
rk signs the module and all bundled native libraries first, then signs the runtime with a library load
constraint that admits their code directory hashes. macOS's own
libraries are exempt. codesign refuses a constraint it cannot evaluate, the
signed smoke test proves the module still loads, and the receipt records both
hashes. The pin protects runtimes signed from this change on. A runtime
published earlier, such as rk 0.1.12's, is unpinned and still loads any module
signed by the same team; only a change of program identity retires it. An older
pinned release still runs only its own module. rk still compares the runtime's
designated requirement with the published one, so a signing change that altered
the program identity would stop the release.

rk runs the signed command and notarizes the whole payload. The archive holds
the signed files byte for byte, and the receipt binds every companion file.
The artifact manifest stores paths, modes and signing roles, without a second
hash inventory. Final signed outputs enter the existing stage receipt once;
resuming an interrupted stage checks those recorded files. A completed stage
checks its public archives, without rehashing expanded libraries. Same-run
hash reuse remains in place, and command startup gains no new file hashing.

The stage is named by the commit and the unit's configuration, not by the
Dart SDK or Xcode tools that built it, so updating either does not orphan a
stage that a partly published release still needs.

These checks establish release artifact integrity and launch behavior. An
application with persistent OS credentials still needs its own upgrade and
installed-artifact qualification.

## Compile-time metadata from pubspec

A CLI may need native metadata compiled into its executable. Select the fields
on that project in `release.toml`:

```toml
schema = 2

[release.cli]
publish = []
binary_platforms = ["macos-arm64", "linux-x64"]
dart_defines_from_pubspec = ["keybay.application_id"]
```

The value stays in its owning `pubspec.yaml`:

```yaml
keybay:
  application_id: dev.example.my_cli
```

rk passes `-Dkeybay.application_id=dev.example.my_cli` to either compilation
format. Missing, empty or structured values fail resolution before building.
For a multi-project unit, put the setting on its `[[release.cli.project]]` row.
These are public compile-time constants, not secrets; they also appear in the
release plan identity. This mechanism does not change the package's pub.dev
installation behavior or add a dependency on Keybay to rk.
