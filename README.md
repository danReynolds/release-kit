# rk

rk makes releasing code simple. A repository says what it releases and where
each piece goes — Dart packages to pub.dev, Git tags, GitHub Releases,
Homebrew formulas, standalone binaries — and rk turns that into one plan for
the whole repository and carries it out with one command:

```console
$ rk init       # say what to release: writes release.toml
$ rk status     # what is released, staged and left to do
$ rk release    # release the rest, in dependency order, asking once
```

`rk release` builds what is not built, shows every remaining target, asks
once, and publishes providers before the packages that need them. Re-running
it finishes a release that stopped anywhere, and publishes nothing twice.

## Features

- **One small file, written for you.** `rk init` proposes it; versions,
  names, and repositories come from native manifests and Git. Unknown
  fields are errors.
- **Reality first.** A target that is already public is recorded, not
  published again.
- **Refuses before acting.** The complete plan is checked before the first
  step acts, and every refusal names the problem and the fix
  ([doc/codes.md](doc/codes.md)).
- **No secrets.** Publication sessions belong to `dart pub`, `gh` and `git`;
  signing and notarization credentials to `codesign` and `notarytool`. rk
  asks for the `dart pub` and `gh` sessions once a run, after the yes;
  `status` and `stage` never do. A `dart pub login` rk runs leaves its
  session in place, as one you ran yourself would.
- **Signed when you say so.** rk signs a release tag when `tag.gpgSign` is
  set, as git does; a signing key alone does not sign it.
- **Final bytes checked.** Linux executables and macOS Dart bundles use one
  artifact contract. Every macOS code file is signed, and the installed
  command is run before it is archived. Dart dependency hooks supply native
  libraries automatically, carried intact through installation.
  See [CLI artifacts](doc/cli-artifacts.md)
  for layouts, signing and compile-time metadata.
- **Monorepos.** Cross-unit version constraints are checked before
  anything acts.

## Getting Started

`rk init` opens an inline Fleury matrix of packages and release outputs. Select the
cells you want, then choose **Review configuration** to see the exact
`release.toml` before creating it. Selected cells say **Added**, and prerequisites
such as GitHub's Git tag are added together.

That proposal is the whole configuration. Targets are opt-in —
release-kit's own file says yes to all of them. `rk plan` draws the configured
release graph before rk observes public state or changes anything:

```console
$ rk plan
RELEASE-KIT RELEASE PLAN
main@888444b

└─ 1 · rk 0.1.0
   ├─ STAGE
   │  └─ [source snapshot]
   │     ├─▶ [package archive]
   │     ├─▶ [release notes]
   │     ├─▶ linux-arm64  [build] ─▶ [archive]
   │     ├─▶ linux-x64  [build] ─▶ [archive]
   │     ├─▶ macos-arm64  [build + sign] ─▶ [notarize] ─▶ [archive]
   │     ├─▶ [Homebrew formula] · needs archives
   │     └─▶ [finalize stage]
   └─ PUBLISH
      └─▶ [tag v0.1.0]
          ├─▶ [pub.dev rk@0.1.0]
          └─▶ [GitHub Release · 4 assets]
              └─▶ [Homebrew · rk.rb]

no destination checks · no changes
```

`rk status` checks the
destinations themselves, not a log; "Not staged" is the private work
that must finish before anything goes public.

See [release status](doc/status.md) for the report's evidence and meaning.

```console
$ rk status
release-kit · main@888444b

  rk 0.1.0

    Not published
      Git tag                    v0.1.0
      pub.dev                    rk
      GitHub Release             danReynolds/release-kit
      Homebrew                   danReynolds/homebrew-tap

    Not staged
      Local binaries
        rk-0.1.0-linux-arm64.tar.gz
        rk-0.1.0-linux-x64.tar.gz
        rk-0.1.0-macos-arm64.tar.gz
      pub.dev                    rk package archive
      GitHub Release             4 artifacts
      Homebrew                   rk.rb
```

The release itself — prepared, disclosed, then authorized with one yes — is
shown in [Two packages, one release](#two-packages-one-release).

`rk stage` builds and checks what a release publishes, and publishes nothing.
[The release pipeline](doc/release-pipeline.md#the-stage-record) says what a
stage holds and when it is reused.

## Install

With Dart 3.10.4 or newer, install a native executable:

```console
$ dart install rk
```

[`dart install`](https://dart.dev/tools/dart-install) builds once at installation.
Running `rk` starts the installed command directly, without resolving package
dependencies. Run the install command again to upgrade.

Pub global activation works too:

```console
$ dart pub global activate rk
```

For the signed and notarized macOS release, use Homebrew:

```console
$ brew install danreynolds/tap/rk
```

The same CLI ships from pub.dev, Homebrew, and GitHub Releases —
`rk --version` reports what you are running.

### Try a local checkout

From the release-kit checkout, install the current code:

```console
$ dart install "rk@{path: '$PWD'}"
$ rk --version
```

This installs a snapshot of the checkout; repeat the install after editing it.
Use an absolute path: `$PWD` supplies it in fish, zsh, and bash.
Run `rk` from the project you want to release: its version and configuration
come from that project, independently of the installed RK version.

`dart pub global activate --source path .` remains useful for development that
follows source edits. Dart Pub may resolve dependencies or rebuild its snapshot
before launching RK, so that route can print package-manager output at startup.

## Targets

| | |
|---|---|
| `git-tag` | create and push a version tag |
| `pub.dev` | publish a Dart package |
| `github-release` | create a GitHub Release with selected outputs |
| `homebrew` | publish the executable through a Homebrew tap |
| `binary` | build standalone executable archives, publishing nothing |

Planned: npm, RubyGems. `rk target list` is always the set your
installed rk supports. `rk target <name>` explains a target's settings
with an example.

Developing another built-in target? Start with
[Adding a release target](doc/adding-a-target.md), which uses GitHub Release as
the worked example and defines the modularity and correctness bar. The
[release pipeline architecture](doc/release-pipeline.md) shows how target
modules join the shared stage and publication coordinators.

## Two packages, one release

Each `[release.<name>]` is a unit, released on its own version. Two
units, `cli` depending on `core`, publishing under their pubspec names
— `init` writes this file too, and it stays yours to edit:

```toml
schema = 3

[release.core]
path = "packages/core"
publish = ["pub.dev"]

[release.cli]
path = "packages/cli"
publish = ["pub.dev"]
```

`rk release` prepares both units first; `cli` is staged against `core`'s
source from the same commit. Each keeps its own version. RK then shows the remaining targets,
first claims, signing identities and preparation warnings, and asks once:

```console
$ rk release
Releasing core 0.3.0 and cli 0.1.0
  example · main@3f2a91c

2 units staged
    core 0.3.0 · pub.dev · example_core
    ✓ package archive                              staged
    cli 0.1.0 · pub.dev · example_cli
    ✓ package archive                              staged
Release order: core 0.3.0 › cli 0.1.0

  Release core 0.3.0
    pub.dev                  example_core 0.3.0 · permanent · first claim

  Release cli 0.1.0
    pub.dev                  example_cli 0.1.0 · permanent · first claim
Release core 0.3.0 and cli 0.1.0? [y/N] y
```

See [recovery](doc/release-pipeline.md#recovery) for when a release needs the
stage it started from.

## Release assets your own build makes

A project can publish files that rk does not know how to make, such as a
native library built for a dozen platforms. Name the command that builds
them, and the files it writes; rk publishes those files as the unit's GitHub
release:

```toml
[release.parser]
path = "native/parser"
tag = "parser-v{version}"
publish = ["git-tag", "github-release"]
assets.build = ["tool/build_release_libraries.sh", "{out}"]
assets.files = [
  "libparser-macos-arm64.dylib",
  "libparser-linux-x64.so",
  "parser-windows-x64.dll",
]
```

- **Where it runs.** rk runs the command from the project's directory in a
  clean copy of the committed source. `{out}` is an empty directory the
  command writes to.
- **What reaches the release.** Only the files `assets.files` names, each
  under its file name.
- **What the command is told.** Its environment carries the release's facts:
  `RK_OUT`, `RK_SOURCE_COMMIT`, `RK_REPOSITORY` (`owner/name`), `RK_VERSION`
  and `RK_TAG`.
- **What it may keep.** `RK_CACHE` is a directory that outlives the stage,
  `.rk/cache/<unit>/<project name>`, for what the next build can reuse, such
  as a compiler's dependencies. rk never publishes it, but what the build
  makes from it is what gets released, so reuse only what the build can
  check is current. `rk clean` leaves it; delete it whenever in doubt.
- **While it runs.** On a terminal, the stage shows the command's latest
  line beside its elapsed time, and keeps how long the build took once it
  is done. If it fails, rk prints its last lines, and the diagnosis keeps
  all of them.
- **Rust crates.** A directory with a `Cargo.toml` and no `pubspec.yaml` is a
  Rust crate. Its name and version come from the `[package]` table, and it
  is released only this way.

The rest is an ordinary rk release. The build runs once per stage, the
release is drafted, published and read back, and its tag carries the
manifest of what was built.

## Dogfood your commands

`rk use` switches a command you release between this checkout's build and a
published one; see [installation management](doc/installations.md).

## Commands

`rk help` (or `rk -h`) lists the commands, output marks, and exit codes.
`rk help <command>` (or `rk <command> -h`) shows its flags and examples.

## Agents

Releases are driven by agents as much as by hands. Every command
speaks `--json` ([doc/json.md](doc/json.md)) — the same facts as the
terminal output, with stable codes.

## This repository

rk releases itself, from a clean checkout:

```console
$ dart run bin/rk.dart status
$ dart run bin/rk.dart release rk
```

[MIT](LICENSE). Reference in [`doc/`](doc/); design history in
[`doc/archive/`](doc/archive/).
