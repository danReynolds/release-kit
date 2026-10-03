# rk

Release kit manages releasing a project to your configured targets: Git tags,
a GitHub Release, Homebrew, standalone binaries — as one checked plan instead
of a release script.

## Features

- **One small file, written for you.** `rk init` proposes it; versions,
  names, and repositories come from native manifests and Git. Unknown
  fields are errors.
- **Reality first.** A target that is already public is recorded, not
  published again.
- **Fail-closed.** The complete plan is validated before the first step
  acts, and every refusal names the problem and the fix
  ([doc/codes.md](doc/codes.md)).
- **No secrets.** Publication sessions belong to `dart pub`, `gh`,
  `codesign`, `notarytool`, and `git`. rk asks for them only after
  private work is finished and checked; `status` and `stage`
  never do. A session rk had to create is cleared when the run ends, so
  a release leaves no credential behind; one that already existed is
  left exactly as it was.
- **Signed when you say so.** `tag.gpgSign`, or a release history that is
  already signed, makes a signature required rather than incidental — and
  rk reads it back off the tag it created instead of trusting the config.
  A signature it cannot verify is refused, not reported as signed.
- **Final bytes checked.** Linux executables and macOS Dart bundles use one
  artifact contract. Every macOS code file is signed; the installed command
  is tested before and after archiving. See [CLI artifacts](doc/cli-artifacts.md)
  for layouts, signing and compile-time metadata.
- **Monorepos.** Cross-unit version constraints are checked before
  anything acts.

## Dogfood your commands

```sh
rk use                     # compare installed and available versions; choose a source
rk use local               # bind this checkout; edits work on the next run
rk install pub             # prepare without switching
rk use --list              # sources, installation state and PATH resolution
```

Run inside the configured project. With multiple executable packages, select
one in the inline table or add `-p package_name`. Every command in a package
switches together; SDK dependencies follow that installation. See [installation management](doc/installations.md).

## Getting Started

`rk init` opens an inline Fleury matrix of packages and release outputs. Select the
cells you want, then choose **Review configuration** to see the exact
`release.toml` before creating it. Selected cells say **Added**, and prerequisites
such as GitHub's Git tag are added together.

Arrow keys move; Space or Enter selects. **Show private packages** reveals
`publish_to: none` packages that can still ship through other outputs. Without
a terminal, RK prints its proposal; `rk init --write` explicitly accepts it.
**Discovery notes** explains omitted packages and available build platforms.
Long reviews support PageUp/PageDown and Home/End from the footer actions.

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

The graph and its direct dependency edges come from the same stage and public
contracts that `rk release` executes. It is source-only: it does not inspect
destinations, acquire credentials, build artifacts, or write a stage. Wide
terminals receive the tree; narrow terminals and pipes receive an outline, and
`--json` exposes the canonical nodes.

`rk status` checks the
destinations themselves, not a log; "Not staged" is the private work
that must finish before anything goes public.

`rk status` shows progress while checking, prints its report, and returns to the
prompt. The report stays in terminal scrollback; rerun it for a fresh check.
`rk use` is interactive because it manages local executables.
See [release status](doc/status.md) for the report's evidence and meaning.

When Binary or Homebrew is selected, `rk init` proposes every binary platform
the current host can produce. A macOS host can build its native macOS binary
and cross-compile pure-Dart Linux binaries; a Linux host does not add a macOS
artifact that requires a macOS release host. Docker and Podman are optional:
they run cross-built Linux binaries for the smoke test. Without one, the Linux
binary is still cross-compiled and is recorded as built but not executed.

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
        producers/rk/archives/rk-0.1.0-linux-arm64.tar.gz
        producers/rk/archives/rk-0.1.0-linux-x64.tar.gz
        producers/rk/archives/rk-0.1.0-macos-arm64.tar.gz
      pub.dev                    rk source
      GitHub Release             4 artifacts
      Homebrew                   rk.rb
```

The release itself — ordered, staged, disclosed, one yes per unit — is
shown in [Two packages, one release](#two-packages-one-release).

`rk stage` opens with the project version and checkout it will use:

```console
$ rk stage rk
Staging rk 0.1.12
  release-kit · main@888444b
```

A stage belongs to an exact commit and release plan. A new commit, SDK, RK
installation, or release configuration can require a new stage. When recent
stage metadata explains the change, RK tells you why it is rebuilding. A
verified stage is reused; interrupted staging resumes from verified work.

Bare `rk stage` prepares all configured units in dependency order. Packages keep
independent versions, and consumers use the exact compatible dependency archives
prepared by the same run. `rk stage <unit>` stays within the named scope: it can
use a verified completed sibling stage or resolve published dependencies, but
does not build the sibling. Saved stages retain their recorded dependency choices
across named and repository-wide runs.

Run `rk release` to prepare as needed and publish. Use `rk stage` first when
you want to inspect the artifacts before publishing; name the unit when the
repository has several.

## Install

With Dart 3.10 or newer, install a native executable:

```console
$ dart install rk
```

[`dart install`](https://dart.dev/tools/dart-install) builds once at installation.
Running `rk` starts the installed command directly, without resolving package
dependencies. Run the install command again to upgrade.

For older Dart SDKs, Pub global activation is also supported:

```console
$ dart pub global activate rk
```

For the signed and notarized macOS release, use Homebrew:

```console
$ brew install danreynolds/tap/rk
```

The same CLI ships from pub.dev, Homebrew, and GitHub Releases —
`rk --version` reports what you are running.

The maintained [production release protocol](doc/production-alpha-plan.md)
and [0.1.4 canary receipt](doc/production-alpha-receipt.md) show the proof
required before calling those channels released.

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
installed rk supports.

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
schema = 2

[release.core]
path = "packages/core"
publish = ["pub.dev"]

[release.cli]
path = "packages/cli"
publish = ["pub.dev"]
```

`rk release` orders the units, shows what each will publish and what is
permanent, and asks once, before any of them acts:

```console
$ rk release
Release order: core 0.3.0 -> cli 0.3.0

  core 0.3.0
    pub.dev                  example_core 0.3.0 · permanent · first claim
  cli 0.3.0
    pub.dev                  example_cli 0.3.0 · permanent
Release core 0.3.0 and cli 0.3.0? [y/N] y

Releasing core 0.3.0
  ...
```

Each unit then stages, checks and publishes in turn, and reads everything
again before it acts. A unit asks again, and says why, when those reads
find something the question did not show, such as a name it would claim for
the first time, or when rk warns about it while it stages, as it does for
Pub's validation warnings. If a unit already cannot go ahead, as far as rk
can tell before staging, each unit asks for itself. A failure stops the
run. Units already published stay published, and running `rk release`
again carries on from there.

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
build = ["tool/build_release_libraries.sh", "{out}"]
assets = [
  "assets/libparser-macos-arm64.dylib",
  "assets/libparser-linux-x64.so",
  "assets/parser-windows-x64.dll",
]
```

- **Where it runs.** rk runs the command from the project's directory in a
  clean copy of the committed source. `{out}` is an empty directory the
  command writes to.
- **What reaches the release.** Only the files `assets` names, each under its
  file name.
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

The rest is an ordinary rk release. The build runs once per stage, the
release is drafted, published and read back, and its tag carries the
manifest of what was built.

## Commands

| | |
|---|---|
| `rk init` | choose outputs and review `release.toml` |
| `rk use [source] [-p project]` | install if needed, then select command source |
| `rk install [source] [-p project]` | prepare a source without switching |
| `rk uninstall [source] [-p project]` | remove a confirmed inactive installation |
| `rk plan [unit]` | show the configured source-only release graph |
| `rk status` | inspect this repository |
| `rk stage [unit]` | prepare and validate artifacts; publish nothing |
| `rk release` | publish unfinished units |
| `rk release <unit>` | one unit |
| `rk target list` | what this binary can create or publish |
| `rk target <name>` | one target: requirements and a minimal example |
| `rk clean` | remove this repository's private stages |

`rk -h` lists the commands, output marks, and exit codes. Use
`rk <command> -h` for its flags and examples.

## Agents

Releases are driven by agents as much as by hands. Every command
speaks `--json` ([doc/json.md](doc/json.md)) — the same facts as the
terminal output, with stable codes. Here, why `cli` waits for `core`:

```console
$ rk status --json | jq .problems
[
  {
    "unit": "cli",
    "code": "RK-REL-001",
    "message": "example_core 0.3.0 must be live on pub.dev: not published: example_core has never been published",
    "remedy": "publish the prerequisite first: rk release core"
  }
]
```

Without a terminal, a needed answer stops the current unit before its remaining
targets are published. Earlier completed units stay published. `--yes` is the
unattended yes, and it skips no inspection. Exit codes: 0 report or
completed command, 1 refused or failed, 2 usage, 3 rk itself crashed —
`--json` mirrors it in `exit`.

## Behavior

Stages live under `.rk/work/stages`. Keep them while a binary release is
partly public so the remaining targets receive the exact staged bytes
the public ones already pinned; `rk clean` removes this repository's
stages, lists their recorded identities, and asks first. Receipt metadata helps
identify a stage; it does not prove that its bytes are no longer needed.

Git-identified targets (`git-tag`, `github-release`, `homebrew`) need a
clean working tree. A registry-only or local release may include
uncommitted work: rk warns, snapshots that tree, and rechecks the
snapshot before publishing.

Releases run from your machine. The design anticipates CI; support is
deferred.

## This repository

rk releases itself, from a clean checkout:

```console
$ dart run bin/rk.dart status
$ dart run bin/rk.dart release rk
```

[MIT](LICENSE). Working notes in [`doc/`](doc/).
