# rk

Release kit manages releasing a project to your configured targets: Git tags, a Github release
Release, Homebrew, standalone binaries — as one checked plan instead
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
  private work is finished and checked; `status` and `release --stage`
  never do.
- **Monorepos.** Cross-unit version constraints are checked before
  anything acts.

## Getting Started

`rk init` reads the repository and proposes a configuration.

```console
$ rk init
Select release outputs

                         Produce              Publish
  Unit                    Binary   Git tag   pub.dev   GitHub   Homebrew
› rk                      [ ]      [x]       [x]       [ ]      [ ]

Binary — standalone rk archives

↑↓ unit   ←→ option   space toggle   enter review   q cancel

```

That proposal is the whole configuration. Targets are opt-in —
release-kit's own file says yes to all of them. `rk status` checks the
destinations themselves, not a log; "Not staged" is the private work
that must finish before anything goes public:

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

## Install

```console
$ dart pub global activate rk
```

```console
$ brew install --cask danreynolds/tap/rk
```

The same CLI ships from pub.dev, Homebrew, and GitHub Releases —
`rk --version` reports what you are running.

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

`rk release` orders the units, stages and checks the private work,
and says what a yes makes permanent — before anything permanent acts:

```console
$ rk release
Release order: core 0.3.0 -> cli 0.3.0

    pub.dev · example_core                         not published
core 0.3.0 · staging
    pub.dev · example_core
✓     package archive                              staged
✓   Release inputs · targets · signing · staged bytes checked
✓   pub.dev · example_core                         signed in

  Release
    core 0.3.0
      publish example_core 0.3.0 to pub.dev
  pub.dev never deletes a version. a version can be retracted, which hides it and removes nothing.
  everything before this yes re-runs safely. after it, the first permanent step is: publish example_core 0.3.0 to pub.dev.

  this release claims, for the first time:
    pub.dev          example_core
                     permanent: a package name cannot be renamed, reassigned, or released back
Release core 0.3.0? [y/N]
```

## Commands

| | |
|---|---|
| `rk init` | propose a `release.toml` |
| `rk status` | inspect this repository |
| `rk release` | publish unfinished units |
| `rk release <unit>` | one unit |
| `rk release --stage` | private steps only |
| `rk target list` | what this binary can create or publish |
| `rk target <name>` | one target: requirements and a minimal example |
| `rk clean` | remove this repository's private stages |

`rk -h` lists every flag, the output marks, and the exit codes.

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

Without a terminal, a needed answer stops the release — "no terminal
to answer on — stopped; nothing was published." `--yes` is the
unattended yes, and it skips no inspection. Exit codes: 0 report or
completed command, 1 refused or failed, 2 usage, 3 rk itself crashed —
`--json` mirrors it in `exit`.

## Behavior

Stages live under `.rk/work/stages`. Keep them while a binary release is
partly public so the remaining targets receive the exact staged bytes
the public ones already pinned; `rk clean` removes this repository's
stages, and asks first.

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
