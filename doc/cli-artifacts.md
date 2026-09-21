# CLI artifacts

`binary_platforms` selects where a Dart CLI runs. rk chooses its packaging;
there is no single-file versus bundle setting to maintain.

| Platform | Archive contents | Command |
|---|---|---|
| Linux x64 / ARM64 | One compiled executable | `tool …` |
| macOS ARM64 | Native launcher, matching Dart runtime, signed AOT module | `tool …` |

Linux uses `dart compile exe`. macOS uses `dart compile aot-snapshot` and
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

rk checks the signed command, verifies every signature again, notarizes the
whole payload, and verifies and runs the extracted final archive. Receipts bind
all companion files and their signatures. The stage key includes the matching
Dart runtime and the launcher compiler/SDK identity, as well as the existing
source and Dart compiler identities. Older stage receipts must be rebuilt.

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
