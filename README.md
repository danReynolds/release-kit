# rk

An austere, fail-closed release tool. rk is a checklist compiler: it reads
what native manifests already say plus one small `release.toml` of intent,
derives the complete ordered checklist for a release, and executes it —
validating everything before acting, inspecting reality before every step so
re-running is always safe, and refusing to guess.

rk manages the release steps and defers authentication to the native tools
that own it (`dart pub`, `codesign`, `notarytool`, `gh`, `git`). It stores no
secrets and keeps no state.

Four verbs: `rk init`, `rk status`, `rk release`, `rk verify`. No hooks, no
templates, no `--force`.

## Using it

```
dart pub global activate release_kit    # the command is rk
rk status                              # where things stand. Read-only.
rk init                                # propose a release.toml
rk release <unit> --dry-run            # every local step, nothing public
rk release <unit>                      # plan, confirm, act
rk verify                              # prove a published release against its tag
```

`rk -h` lists every flag, the four marks, and the exit codes.
[doc/json.md](doc/json.md) is the `--json` contract: the schema, the frozen
verdict enum, and the blessed CI gate rule.

## Reading it

`bin/rk.dart` is the composition root — it parses flags, reads and resolves
`release.toml`, builds the collaborators, and dispatches to a verb.
`lib/src/commands/` holds the four verbs; `lib/src/destinations/` the places
a release is published to; `lib/src/builds/` and `lib/src/transforms/` the
adapters that produce artifacts; `lib/src/output/` the two surfaces (prose
and the `--json` document, written by the same calls so they cannot drift);
and `lib/src/engine/` the model and the readers everything else is built on.
`examples/` holds five repository shapes the tests drive end to end.

## Scope

Dart packages and Dart CLIs released from the operator's own machine to
pub.dev, GitHub Releases, and Homebrew. CI is designed-for and deferred.
First demo: keybay.

The design is [RFC 0002](doc/rfcs/0002-rk-core.md); the threat catalog and
assurance ladder it prices against is
[RFC 0001](doc/rfcs/0001-rk-secure-release-compiler.md).
[doc/plan.md](doc/plan.md) carries the build plan, the review records, and
the ledger of what is deliberately deferred.
