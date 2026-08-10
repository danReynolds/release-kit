# rk

An austere, fail-closed release tool. rk is a checklist compiler: it reads
what native manifests already say plus one small `release.toml` of intent,
derives the complete ordered checklist for a release, and executes it —
validating everything before acting, inspecting reality before every step so
re-running is always safe, and refusing to guess.

rk manages the release steps and defers authentication to the native tools
that own it (`dart pub`, `codesign`, `notarytool`, `gh`, `git`). A normal
interactive release with unfinished pub.dev targets runs one native
`dart pub login` before private staging; `status` and `release --stage` never
log in. Login proves only that a current session exists, not that it may upload
every package. The attempted publish and exact public read-back remain the
authority, and a retry records an already-exact target without publishing it
again. rk stores no secrets and keeps no authoritative release ledger: public
targets are truth.
A private stage is disposable before publication begins and after every target
is exact; during a partial binary release, retain it so the remaining targets
receive the exact signed and notarized bytes already bound by the public ones.

Three verbs: `rk init`, `rk status`, `rk release`. No hooks, no templates,
no `--force`.

## Using it

```
dart pub global activate release_kit    # the command is rk
rk status                              # where things stand. Read-only.
rk init                                # propose a release.toml
rk release <unit> --stage              # exact reusable stage, nothing public
rk release <unit>                      # plan, confirm, act
rk release <unit> --confirm=<version>  # the typed yes as a flag, for agents
```

Most releases are driven by agents: every verb speaks `--json`
([doc/json.md](doc/json.md) is the contract and the drive loop), and
`--confirm=<version>` authorizes exactly one version noninteractively —
the same explicit-consent door `init --write` opens, and still
no `--force`: no inspection is skipped, and any other version still
refuses.

For release-kit's own first release, invoke the clean checkout explicitly
instead of an older globally installed `rk`:

```
dart run bin/rk.dart --version
dart run bin/rk.dart status rk
dart run bin/rk.dart release rk --stage
dart run bin/rk.dart release rk
```

Every published binary supports `rk --version`; staging uses that output to
prove it built the intended version before the artifact can be released.

`status` has no separate authentication state. A concrete issue that belongs
to a target marks that target `✗` and appears once under `Issues`; when a native
tool offers no safe read-only authentication check, status stays silent and
the normal release preflight owns the check.

The two production-alpha receipts are intentionally outside the default local
suite. Run them explicitly with
`dart test test/live_release_checkpoints.dart` when performing the supervised
releases.

`rk -h` lists every flag, the four marks, and the exit codes.
[doc/json.md](doc/json.md) is the `--json` contract: the schema, the frozen
verdict enum, and the blessed CI gate rule.

## Reading it

`bin/rk.dart` is the composition root — it parses flags, reads and resolves
`release.toml`, builds the collaborators, and dispatches to a verb.
`lib/src/commands/` holds the three coordinators. `lib/src/targets/` is the
closed catalog of Git tag, pub.dev, GitHub Release, and Homebrew lanes; each
module owns that target's expectation, reads, status policy, private stage
contribution, public act, read-back settling, and retry/failure semantics.
The contribution's in-memory contract drives both production and validation
of the reusable stage, so provider receipt rules are declared once.
`lib/src/destinations/` holds the lower-level provider protocols those modules
use. `lib/src/builds/` and `lib/src/transforms/` produce artifacts;
`lib/src/output/` owns the prose and `--json` surfaces; and `lib/src/engine/`
holds the shared model and readers.
`examples/` holds five repository shapes the tests drive end to end.

## Scope

Dart packages and Dart CLIs released from the operator's own machine to
pub.dev, GitHub Releases, and Homebrew. CI is designed-for and deferred.
The production-alpha canary is release-kit itself; the older keybay work is
preserved as historical design evidence in `doc/plan.md`.

The current path to a supervised local release is the
[production-alpha plan](doc/production-alpha-plan.md). The design is
[RFC 0002](doc/rfcs/0002-rk-core.md); the threat catalog and assurance ladder
it prices against is [RFC 0001](doc/rfcs/0001-rk-secure-release-compiler.md).
[doc/plan.md](doc/plan.md) preserves the original build plan, review records,
and evidence ledger.
