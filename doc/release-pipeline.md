# Release pipeline architecture

How rk works, and the commitments it keeps, are in
[AGENTS.md](../AGENTS.md#how-rk-works); this document maps them onto the code.

`ReleaseCommand` is the decision ladder for the units a run selects. It reads
each unit through the same `UnitSnapshot` that `rk status` renders, refuses
unsafe starting states, and hands each unit's `UnitRun` to the stage runner,
then to publication. Targets supply destination semantics through
`TargetModule`; they do not acquire control of the pipeline.

```text
UnitRelease.derive   one model per unit: work, targets, files
     |
     v
ReleaseCommand  ----->  UnitSnapshot: every destination read once
     |                          |
     |                          +---- TargetModule.read
     |
     +----> Publication.checkReadiness
     |          ambient readiness, before any private work
     |                          |
     |                          +---- TargetModule.ready
     |
     +----> StageRunner.begin, one unit at a time
     |          interrupted outputs cleared + macOS identity settled
     |
     +----> StageRunner.run, every unit at once
     |          fixed lanes + one receipt per stage
     |                          |
     |                          +---- TargetModule.prepare
     |
     +----> Publication.authorize
     |          one question for every unit's remaining targets
     |
     +----> Publication.publish, unit by unit
                sessions once per provider, after the yes
                per target: read + check stage + act + confirm
                                |
                                +---- TargetModule.publish/confirm/explain
```

The arrows are the architecture. There is no event bus, lifecycle registry,
or callback for every sub-step.

## One release model

`UnitRelease.derive` turns a unit's configuration and manifests into one
value, by fixed rules rather than a graph search:

- `requirements`: the packages sibling units put on pub.dev first;
- `work`, in canonical order: each package's Pub archive, the release notes,
  each platform's build, notarization and archive (or the project's own
  build), the Homebrew formula, and last the barrier that completes the
  stage;
- `targets`: the tag, the pub.dev packages in dependency order, the GitHub
  release, and the Homebrew formula, each with the files it publishes;
- `artifacts`: every file that leaves the stage.

`rk plan`, the stage board, `rk status` and the release all read this one
model. The plan is a source-only view: no provider read, compiler or
credential is needed to render it.

## The stage record

A stage lives in `.rk/work/stages/<id>`. Its id hashes the commit, the tree,
the unit's configuration and origin, and the stage schema, so a stage holds
the bytes of exactly what it is named by. `stage.json` records the plan before
any work, then each piece of work's evidence and every file it wrote, with
its size and digest. rk replaces it by an atomic rename after each piece of
work, so a crash keeps everything recorded before it.

`Stage.check` says what a stage is:

| State | When | Stage and release |
| --- | --- | --- |
| absent | no receipt | build |
| resumable | interrupted, its files intact | skip the recorded work |
| broken | interrupted, a recorded file changed | start again |
| complete | the barrier recorded, every published file intact | reuse |
| changed | the barrier recorded, a published file missing or changed | `rk stage` rebuilds; `rk release` refuses (`RK-STAGE-002`) |
| unreadable | malformed, from another rk, or naming another stage | as changed |

The release manifest, the GitHub release's assets and status's inventory are
views over the receipt.

## Fixed lanes

Staging runs every piece of work that can start, in fixed lanes: each Pub
archive, the release notes, and each platform's build, notarization and
archive (or the project's own build) side by side; the formula once every
archive is recorded; then the barrier. Each lane that builds works in its
own export of the commit, outside the repository. A failed lane starts
nothing new, and work already running drains into the resumable receipt.

Publication publishes the tag alone, first. Then two lanes run at once: the
pub.dev packages in dependency order, and the GitHub release followed by the
Homebrew formula. A failure starts nothing new, and every act already under
way is confirmed before the run stops.

Each target goes through one loop:

1. Read it fresh. Exact is already published.
2. Anything but absent refuses, in the target's words (`explain`).
3. Check the stage it publishes: the complete stage, or, for a moving channel
   finishing without its stage, the public inputs it recovers from.
4. Act (`publish`), then take the act's own answer or read back (`confirm`).
5. Exact is done. Anything else stops with the halt that fits: before acting,
   partway, lost track, or not fixable by re-running.

## Responsibilities

| Owner | Owns | Does not own |
| --- | --- | --- |
| `ReleaseCommand` | unit selection and order, the snapshot, cross-target refusals, the stage-only exit, the run's summaries | provider protocols, producers, sessions, publication |
| `StageRunner` | stage reuse, the macOS identity, reading the source once, lanes, receipts, resuming an interrupted stage | public credentials or public acts |
| `Publication` | readiness, the one question, sessions once per provider after the yes, the per-target loop and its halts | building or changing stage bytes |
| `TargetModule` | one destination's read, stage work, readiness, act, read-back and words | ordering, authorization, retries, progress, other targets |

`UnitRun` is what one unit carries between them: the snapshot, whether it
finishes without its stage, the packages it builds from source, the identity
its macOS build signs as, and what the release did at each target.
`release_progress.dart` holds the progress rows both phases fill.

## Temporal invariants

1. Public unknown or conflict never authorizes private work.
2. Every producer lane has its own scratch directory; concurrent work does
   not share mutable build space.
3. The macOS identity is settled before producers run and recorded with the
   signed build, and the stage's plan is recorded before any producer writes.
4. Target readiness is checked before any private work. Native sessions are
   acquired once per provider, after the yes.
5. Public state is read once, before staging, and that snapshot is what the
   yes covers. Right before each act rk reads the target again and checks the
   staged bytes it publishes. Origin's tags are listed once a run: git
   refuses to replace a tag, so the push is its own check.
6. Authorization may lose work to another actor, but it cannot gain a new
   target after the operator says yes.
7. A publish command's answer is proof only where the native tool makes it
   definite: a git push that exits 0. Otherwise, and after any act that
   fails, rk reads the destination back and decides from that state.
8. A failed lane prevents new work from starting; work already in flight is
   drained and reconciled before the final halt is reported.

## Dependencies while staging

A package is staged the way its consumers will resolve it. Pub resolves it in
a scratch mirror of the commit, as a root of its own, with no lockfile and
through its normal cache. rk writes the mirror's `pubspec_overrides.yaml`,
which overrides only this repository's packages that cannot come from pub.dev
yet: one it needs at runtime whose version here satisfies the constraint and
is not published, and one only its development needs. Everything else comes
from pub.dev, as it does for consumers, and Pub leaves overrides files out of
archives, so they never change what is published.

A named command prepares exactly that unit and never builds or publishes a
sibling: a package whose prerequisite no unit in the run publishes waits for
it, and rk says which command releases them together.

## Recovery

Public acts are not a transaction: a failure keeps what is already public,
and a re-run resumes after it. A version on pub.dev is published; rk does not
compare it with an archive already there.

A partial release needs its original stage only while a unit's built release
assets are partly public (`RK-STAGE-005`): assets on a GitHub release, or a
Homebrew formula that names their hashes. Otherwise a fresh stage from the
same commit publishes what remains, even after the tag is pushed. When only a
Homebrew formula remains, rk renders it from the archives the GitHub release
serves, so a lost stage does not stop the release.

## Extending the system

Start with [Adding a release target](adding-a-target.md). Add a core API only
when core must coordinate a lifecycle concept across targets. Provider steps
that form one transaction stay behind `TargetModule.publish`; private inputs
a target needs stay behind `TargetModule.prepare`.

## Standalone CLI payloads

The binary chain uses one [artifact description](cli-artifacts.md) for Linux
executables and macOS Dart bundles. Companion files are build outputs and
explicit inputs to notarization and archiving, so stage reuse cannot adopt an
unrecorded runtime or module. The process identity stays on the Dart runtime
when upgrading from a single macOS executable.
