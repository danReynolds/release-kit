<div align="center">

# rk

**rk makes releasing code simple.**

One command releases a whole repository: Dart packages to pub.dev, version
tags, GitHub Releases with macOS and Linux binaries, and Homebrew formulas,
in the order they depend on each other, asking once.

[![pub.dev](https://img.shields.io/pub/v/rk?label=pub.dev)](https://pub.dev/packages/rk)
[![Core](https://github.com/danReynolds/release-kit/actions/workflows/core.yml/badge.svg)](https://github.com/danReynolds/release-kit/actions/workflows/core.yml)
[![MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

<img src="tool/demo/release.gif" width="880" alt="rk status lists what rk 0.2.2 has left to publish; rk release asks once, then pushes the tag, publishes to pub.dev, publishes the GitHub Release with three binaries, and updates the Homebrew formula">

<sub>rk releasing itself: version 0.2.2, recorded as it went public.</sub>

</div>

## Quick start

```console
$ brew install danreynolds/tap/rk     # or: dart install rk
$ rk init       # choose what to release; writes release.toml
$ rk status     # what is released, staged and left to do
$ rk release    # release the rest, in dependency order, asking once
```

`rk init` reads your packages and proposes their outputs. Choose Homebrew,
and it adds the binary and the GitHub Release the formula installs from:

<img src="tool/demo/init.gif" width="880" alt="rk init: selecting Homebrew adds Binary and GitHub; the review shows a four-line release.toml, which rk writes">

## What rk does

### One plan for the whole repository

`release.toml` says what each unit releases and where it goes. Versions,
names and repositories come from your manifests and Git. `rk plan` draws
what a release will do without reading a destination or changing anything:

```console
$ rk plan
RELEASE-KIT RELEASE PLAN
main@2fe7021

└─ 1 · rk 0.2.2
   │
   ├─ STAGE
   │  └─ [source snapshot]
   │     ├─▶ [package archive]
   │     ├─▶ [release notes]
   │     ├─▶ linux-arm64  [build] ─▶ [archive]
   │     ├─▶ linux-x64  [build] ─▶ [archive]
   │     ├─▶ macos-arm64  [build + sign] ─▶ [notarize] ─▶ [archive]
   │     ├─▶ [Homebrew formula] · needs archives
   │     └─▶ [finalize stage]
   │
   └─ PUBLISH
      └─▶ [tag v0.2.2]
          ├─▶ [pub.dev rk@0.2.2]
          └─▶ [GitHub Release · 4 assets]
              └─▶ [Homebrew · rk.rb]

no destination checks · no changes
```

### Builds side by side, and never twice

`rk stage` builds and checks everything a release publishes, and publishes
nothing. Units build at the same time, from one commit; a package that
needs a sibling not yet on pub.dev builds against that sibling's source. A
stage is named by what it was built from, so running it again reuses it.

<img src="tool/demo/stage.gif" width="880" alt="rk stage builds Fleury's four packages side by side in 10 seconds; running it again reuses all four">

<sub>Fleury's four packages: 10 seconds to stage, under one to reuse.</sub>

### Re-running is the recovery

Interrupt rk anywhere and run the same command again. It keeps what
finished, does the rest, and publishes nothing twice. There is no resume
flag and no cleanup step.

<img src="tool/demo/recover.gif" width="880" alt="rk stage is interrupted with three of four packages staged; running it again stages the fourth and keeps the three">

### Asks once, then checks what happened

`rk release` shows every remaining target in release order and asks one
question; the yes covers exactly those. Right before each upload rk reads
the destination again and checks the staged bytes, and afterwards it reads
the result back. When pub.dev accepts an upload but the response is lost,
rk finds the version there and carries on.

Problems found before publishing stop the run before anything is public,
each with a code and the fix ([doc/codes.md](doc/codes.md)). Credentials
stay with the tools that own them: `dart pub`, `gh`, `git`, `codesign` and
`notarytool`.

### Binaries for macOS and Linux

For a command-line app, rk builds standalone executables for macOS and
Linux, signs and notarizes the macOS one, runs each where this machine can,
attaches them to the GitHub Release, and writes the Homebrew formula that
installs them. Native libraries from Dart build hooks come along. See
[CLI artifacts](doc/cli-artifacts.md).

### Built for agents

Every command speaks `--json`: the same facts as the terminal, with stable
codes ([doc/json.md](doc/json.md)). `rk release --yes` is the unattended yes
to the same reviewed plan, and it skips no inspection.

```console
$ rk status --json | jq -c '.units[].targets[] | {kind, coordinate, verdict}'
{"kind":"gitTag","coordinate":"v0.2.2","verdict":"absent"}
{"kind":"pubDev","coordinate":"rk","verdict":"absent"}
{"kind":"githubRelease","coordinate":"danReynolds/release-kit/releases/tag/v0.2.2","verdict":"absent"}
{"kind":"homebrew","coordinate":"danReynolds/homebrew-tap/Formula/rk.rb","verdict":"absent"}
```

## What it releases

| Target | Publishes |
|---|---|
| `git-tag` | a version tag, signed when `tag.gpgSign` asks |
| `pub.dev` | a Dart package |
| `github-release` | a GitHub Release with your binaries, or files your own build makes |
| `homebrew` | a formula in your tap that installs your binary |
| `binary` | standalone executables for `macos-arm64`, `linux-x64` and `linux-arm64`, kept local unless a target above ships them |

Planned: npm and RubyGems. `rk target <name>` explains a target and its
settings with an example.

## Configure

`rk init` writes `release.toml`, and it stays yours to edit. Each
`[release.<name>]` is a unit, released on its own version. Two packages,
`cli` depending on `core`:

```toml
schema = 3

[release.core]
path = "packages/core"
publish = ["pub.dev"]

[release.cli]
path = "packages/cli"
publish = ["git-tag", "pub.dev", "github-release", "homebrew"]
binary.platforms = ["macos-arm64", "linux-x64", "linux-arm64"]
```

`rk release` publishes `core` first, because `cli` needs it.

<details>
<summary><b>Release assets your own build makes</b></summary>

A unit can publish files rk does not know how to make, such as a native
library built for a dozen platforms. Name the command that builds them and
the files it writes, and rk publishes those files as the unit's GitHub
Release:

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
  line beside its elapsed time. If it fails, rk prints its last lines, and
  the diagnosis keeps all of them.
- **Rust crates.** A directory with a `Cargo.toml` and no `pubspec.yaml` is a
  Rust crate. Its name and version come from the `[package]` table, and it
  is released only this way.

The rest is an ordinary rk release: the build runs once per stage, the
release is drafted, published and read back, and its tag carries the
manifest of what was built.

</details>

## Install

```console
$ brew install danreynolds/tap/rk     # signed and notarized for macOS
$ dart install rk                     # Dart 3.10.4 or newer
$ dart pub global activate rk         # also works
```

The same CLI ships from Homebrew, pub.dev and GitHub Releases;
`rk --version` says which version you are running. Run `rk` from the project
you want to release: its version and configuration come from that project.

`rk use` switches a command you release between this checkout's build and a
published one ([installations](doc/installations.md)).

<details>
<summary><b>Run a local checkout</b></summary>

From the release-kit checkout:

```console
$ dart install "rk@{path: '$PWD'}"
```

This installs a snapshot of the checkout; install again after editing it.
Use an absolute path: `$PWD` supplies it in fish, zsh and bash.
`dart pub global activate --source path .` follows source edits instead, and
can print Pub's output as it starts.

</details>

## Documentation

| | |
|---|---|
| [Release status](doc/status.md) | what `rk status` reads, and what each line means |
| [The release pipeline](doc/release-pipeline.md) | stages, ordering and recovery |
| [CLI artifacts](doc/cli-artifacts.md) | binary layouts, signing and compile-time metadata |
| [Installations](doc/installations.md) | `rk use`, `rk install` and `rk uninstall` |
| [JSON](doc/json.md) | the `--json` contract |
| [Codes](doc/codes.md) | every refusal, with its fix |
| [Adding a target](doc/adding-a-target.md) | how a new destination joins the pipeline |

`rk help` lists the commands, and `rk help <command>` a command's flags.
Design history is in [`doc/archive/`](doc/archive/).

## This repository

Releases run from your machine; the design anticipates CI, and support is
deferred. [MIT](LICENSE).
