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
  command is run before it is archived. See [CLI artifacts](doc/cli-artifacts.md)
  for layouts, signing and compile-time metadata.
- **Monorepos.** Cross-unit version constraints are checked before
  anything acts.

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
      pub.dev                    rk package archive
      GitHub Release             4 artifacts
      Homebrew                   rk.rb
```

The release itself — prepared, disclosed, then authorized with one yes — is
shown in [Two packages, one release](#two-packages-one-release).

`rk stage` opens with the project version and checkout it will use:

```console
$ rk stage rk
Staging rk 0.1.12
  release-kit · main@888444b
```

A stage belongs to an exact commit, the unit's configuration and the origin it
publishes to; a new commit or origin needs a new stage. Updating Dart, Xcode or
rk does not, unless a new rk changes how it records stages. A verified stage is
reused; interrupted staging resumes from the outputs it recorded. `rk stage`
rebuilds a completed stage that no longer verifies, and says so; `rk release`
refuses one (`RK-STAGE-002`).

Bare `rk stage` prepares all configured units: each is checked, and its signing
settled, in dependency order; then every unit that needs a stage builds at once,
on one board. Packages keep
independent versions, and Pub resolves their dependencies through its own cache.
A package that depends on another package in this repository, at a version that
satisfies its requirement, takes it from the same commit's source while staging,
so it can be staged before that sibling is published. `rk stage <unit>` prepares
exactly the named unit, the same way; it never builds or publishes the sibling.

`rk release` completes private preparation for every selected unit before one
confirmation, publication login or public action. Use `rk stage` first to inspect
the artifacts separately. A package publishes only once the packages it needs
are public: a sibling released in the same run publishes first, and a named
release asks for a sibling outside it to be released first.

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

A preparation failure leaves any completed private stages available for retry
and acquires no publication session. The yes covers exactly the targets shown
and nothing else; a target that was already public when asked is never acted
on. Right before each act rk reads that target again, skipping one another run
has published since, checks the staged bytes it publishes, acts, and reads the
result back. A Git tag is read once a run, with every other tag: git accepts a
tag push only as the exact object it was given, so its answer is the read-back.

Packages publish in dependency order, and each waits until pub.dev lists the
version it uploaded before the next unit starts. Development-only
dependencies never become publication prerequisites.

Public releases are not atomic. If a later publication fails, earlier completed
targets remain public; rerunning rechecks them and resumes with the recorded
stage. See [recovery](doc/release-pipeline.md#recovery) for when a release
needs the stage it started from.

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

```sh
rk use                     # compare installed and available versions; choose a source
rk use local               # bind this checkout; edits work on the next run
rk install pub             # prepare without switching
rk use --list              # sources, installation state and PATH resolution
```

Run inside the configured project. With multiple executable packages, select
one in the inline table or add `-p package_name`. Every command in a package
switches together; SDK dependencies follow that installation. See [installation management](doc/installations.md).

## Commands

| | |
|---|---|
| `rk init` | choose outputs and review `release.toml` |
| `rk status [unit]` | what is released, staged and left to do |
| `rk stage [unit]` | prepare and validate artifacts; publish nothing |
| `rk release` | publish unfinished units, in dependency order |
| `rk release <unit>` | one unit |
| `rk plan [unit]` | show the configured source-only release graph |
| `rk target [name]` | what this binary can create or publish, or one target in detail |
| `rk clean` | remove this repository's private stages |
| `rk use [source] [-p project]` | install if needed, then select command source |
| `rk install [source] [-p project]` | prepare a source without switching |
| `rk uninstall [source] [-p project]` | remove a confirmed inactive installation |
| `rk help [command]` | the commands, output marks and exit codes, or one command's flags |

`rk help` (or `rk -h`) lists the commands, output marks, and exit codes.
`rk help <command>` (or `rk <command> -h`) shows its flags and examples.

On a terminal, a finished step keeps how long it took once that reaches a
second, and a successful `stage` or `release` of ten seconds or more ends
with where the time went: `Done in 2m 53s · preparing 2s · staging 2m 29s ·
publishing 22s`. Time spent at rk's confirmation
prompt is not counted. For the whole breakdown, every phase and step however
fast, pass `--timings`: it is printed to stderr after the run, and the run is
written to `.rk/timings.json` as a trace that Perfetto opens.

## Agents

Releases are driven by agents as much as by hands. Every command
speaks `--json` ([doc/json.md](doc/json.md)) — the same facts as the
terminal output, with stable codes. Here, why `cli` releases after `core`:

```console
$ rk status --json | jq '.units[] | select(.name == "cli") | .steps[] | select(.kind == "prerequisite")'
{
  "id": "cli/requires/pub.dev/example_core/0.3.0",
  "kind": "prerequisite",
  "summary": "example_core 0.3.0 must be live on pub.dev",
  "verdict": "absent",
  "permanent": false,
  "public": false,
  "detail": "example_core has never been published"
}
```

It is not a problem: `rk release` publishes `core` first, so `problems` stays
empty, and the terminal report says `Releases after core 0.3.0`.

Without a terminal, a needed answer stops the selected release after private
preparation and before publication sessions or public actions. `--yes` is the
unattended yes to the same reviewed plan, and it skips no inspection. Exit codes: 0 report or
completed command, 1 refused or failed, 2 usage, 3 rk itself crashed —
`--json` mirrors it in `exit`.

## Behavior

Stages live under `.rk/work/stages`. Keep a unit's stage while its built release
assets are partly public: the assets on a GitHub release, a Homebrew formula that
names their hashes, or the release manifest a pushed tag records for them. The
remaining targets need those exact bytes, and rk refuses without them
(`RK-STAGE-005`). Any other unit stages again from its commit, even after its tag
is pushed, and a published package needs nothing from its stage: a version on
pub.dev is published, and a fresh stage publishes what remains. `rk clean` removes this
repository's stages, lists their recorded identities, and asks first. Receipt
metadata helps identify a stage; it does not prove that its bytes are no longer
needed.

A release is of a commit. `rk stage` and `rk release` build from a clean,
committed working tree, and refuse uncommitted changes or a directory outside
Git before doing anything. `rk status` and `rk plan` read either as it is, and
say what staging needs.

Releases run from your machine. The design anticipates CI; support is
deferred.

## This repository

rk releases itself, from a clean checkout:

```console
$ dart run bin/rk.dart status
$ dart run bin/rk.dart release rk
```

[MIT](LICENSE). Working notes in [`doc/`](doc/).
