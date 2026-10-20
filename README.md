<div align="center">

# rk

**rk makes releasing code simple.**

One command releases a whole repository: Dart packages to pub.dev, version
tags, GitHub Releases with macOS and Linux binaries, and Homebrew formulas,
in the order they depend on each other, asking once.

[![pub.dev](https://img.shields.io/pub/v/rk?label=pub.dev)](https://pub.dev/packages/rk)
[![Core](https://github.com/danReynolds/release-kit/actions/workflows/core.yml/badge.svg)](https://github.com/danReynolds/release-kit/actions/workflows/core.yml)
[![MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

<img src="tool/demo/release.gif" width="860" alt="rk status lists what rk 0.2.2 has left to publish; rk release asks once, then pushes the tag, publishes to pub.dev, publishes the GitHub Release with three binaries, and updates the Homebrew formula">

<sub>rk releasing itself: version 0.2.2, recorded as it went public.</sub>

</div>

## Quick start

```console
$ brew install danreynolds/tap/rk     # or: dart install rk
$ rk init       # choose what to release; writes release.toml
$ rk status     # what is released, staged and left to do
$ rk release    # release the rest, in dependency order, asking once
```

`rk init` proposes outputs for each package. Choosing Homebrew adds the
binary and GitHub Release it installs from:

<img src="tool/demo/init.gif" width="940" alt="rk init: selecting Homebrew adds Binary and GitHub; the review shows a four-line release.toml, which rk writes">

## Plan

`release.toml` says what each unit releases and where. Versions, names and
repositories come from your manifests and Git. Two packages, `cli`
depending on `core`:

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

`rk plan` draws what releasing it will do, without reading a destination
or changing anything:

<img src="tool/demo/plan.gif" width="640" alt="rk plan: core stages its package and publishes to pub.dev; cli requires core on pub.dev, stages its package, builds for three platforms with macOS signing and notarization, writes a Homebrew formula, then publishes a tag, pub.dev, a GitHub Release with four assets and the formula">

## Stage, and re-run anything

`rk stage` builds and checks everything a release publishes, units side by
side, and publishes nothing. Stop it, or `rk release`, anywhere: running it
again keeps what finished, does the rest, and publishes nothing twice.

<img src="tool/demo/stage.gif" width="860" alt="rk stage on Fleury's four packages, interrupted partway; run again, it keeps what finished and stages the rest; run once more, all four are already staged">

## Release

Right before each upload, `rk release` reads the destination again and
checks the staged bytes, and afterwards it reads the result back. A problem found
before publishing stops the run with a code and the fix
([doc/codes.md](doc/codes.md)). Credentials stay with `dart pub`, `gh`,
`git`, `codesign` and `notarytool`.

## Use what you're building

`rk use` switches a command you release between this checkout's build and
a published one:

<img src="tool/demo/use.gif" width="860" alt="rk use lists rk's sources; rk use local compiles this checkout and makes it rk; rk use github downloads the published 0.2.2 and makes it rk">

## Agents

Every command speaks `--json`, with stable codes ([doc/json.md](doc/json.md)).
`rk release --yes` is the unattended yes to the same reviewed plan.

```console
$ rk status --json | jq -c '.units[].targets[] | {kind, coordinate, verdict}'
{"kind":"gitTag","coordinate":"v0.2.2","verdict":"absent"}
{"kind":"pubDev","coordinate":"rk","verdict":"absent"}
{"kind":"githubRelease","coordinate":"danReynolds/release-kit/releases/tag/v0.2.2","verdict":"absent"}
{"kind":"homebrew","coordinate":"danReynolds/homebrew-tap/Formula/rk.rb","verdict":"absent"}
```

## Supported targets

| Target | Publishes | You need |
|---|---|---|
| `git-tag` | a version tag, signed when `tag.gpgSign` asks | push access to origin |
| `pub.dev` | a Dart package | a `dart pub` sign-in |
| `github-release` | your binaries, or files your own build makes | a `gh` sign-in |
| `homebrew` | a formula that installs your binary | a `gh` sign-in and an existing tap, `<owner>/homebrew-tap` by default |
| `binary.platforms` | executables for `macos-arm64`, `linux-x64` and `linux-arm64`, the macOS one signed and notarized, for `github-release` and `homebrew` to ship | for macOS, a Developer ID certificate and an `rk-notary` notarytool profile; optionally, Docker or Podman to run the Linux ones |
| npm | planned | |
| RubyGems | planned | |

After the yes, rk checks the `dart pub` and `gh` sign-ins once a run, and
runs `dart pub login` if Pub needs it. `rk target <name>` explains a
target's settings with an example.

<details>
<summary><b>Release files your own build makes</b></summary>

A unit can publish files rk does not know how to make, such as a native
library built for a dozen platforms. Name the command and the files it
writes, and rk publishes them as the unit's GitHub Release. A Rust crate (a
`Cargo.toml` and no `pubspec.yaml`) releases only this way, named and
versioned by its `Cargo.toml`.

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

rk runs the command once per stage, from the project's directory in a clean
copy of the committed source, and publishes only the files `assets.files`
names from `{out}`. Its environment carries `RK_OUT`, `RK_SOURCE_COMMIT`,
`RK_REPOSITORY`, `RK_VERSION` and `RK_TAG`. `RK_CACHE`,
`.rk/cache/<unit>/<project name>`, outlives the stage for what the next
build can reuse; reuse only what the build can check is current.

</details>

## Install

```console
$ brew install danreynolds/tap/rk     # signed and notarized for macOS
$ dart install rk                     # Dart 3.10.4 or newer
```

`dart pub global activate rk` works too. From a checkout,
`dart install "rk@{path: '$PWD'}"` installs a snapshot of it.

## Documentation

| | |
|---|---|
| [Release status](doc/status.md) | what `rk status` reads, and what each line means |
| [The release pipeline](doc/release-pipeline.md) | stages, ordering and recovery |
| [CLI artifacts](doc/cli-artifacts.md) | binary layouts, signing and compile-time metadata |
| [Installations](doc/installations.md) | `rk use`, `rk install` and `rk uninstall` |
| [JSON](doc/json.md) and [codes](doc/codes.md) | the `--json` contract, and every refusal with its fix |
| [Adding a target](doc/adding-a-target.md) | how a new destination joins the pipeline |

`rk help` lists the commands; design history is in [`doc/archive/`](doc/archive/).
Releases run from your machine; CI is not supported yet. [MIT](LICENSE).
