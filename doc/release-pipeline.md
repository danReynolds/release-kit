# Release pipeline architecture

How rk works, and the commitments it keeps, are in
[AGENTS.md](../AGENTS.md#how-rk-works); this document maps them onto the code.

`ReleaseCommand` is the decision ladder for the units a run selects. It resolves the
shared plan, reads each unit through the same `UnitSnapshot` that `rk status`
renders, refuses unsafe starting states, and hands work to two coordinators. Targets supply destination semantics through
`TargetModule`; they do not acquire control of the pipeline.

```text
                         TargetCatalog
                     derives plans + modules
                                |
                                v
ReleaseCommand  ----->  initial observation and refusal
     |                          |
     |                          +---- TargetModule.inspect/history
     |
     +----> ReleasePublicationCoordinator.checkReadiness
     |          ambient readiness, before any private work
     |
     +----> ReleaseStageCoordinator.begin, one unit at a time
     |          interrupted outputs cleared + signing identity settled
     |
     +----> ReleaseStageCoordinator.complete, every unit at once
     |          isolated producer lanes + receipt-backed stage
     |                          |
     |                          +---- TargetModule.stageInput
     |
     +----> ReleasePublicationCoordinator.authorize
     |          one question for every unit's remaining targets
     |
     +----> ReleasePublicationCoordinator.publish, unit by unit
                sessions once per provider, after the yes
                per target: check staged bytes + act + confirm
                                |
                                +---- TargetModule.publish/confirm
```

The arrows are the architecture. There is no general event bus, lifecycle
registry, or callback for every sub-step. A new target joins at the few points
where core genuinely coordinates several destinations.

## One graph, two execution policies

`DependencyGraph` is the small shared structural primitive. `Checklist`
derives stable public-step edges; `StageReceiptContract` resolves producer
inputs to their owning operations. Both feed the same validation/readiness
model instead of teaching either coordinator another ordering rule.

`rk plan` composes those same two graphs into `RepositoryReleasePlan`. It is a
source-only projection: no provider inspection, compiler selection, stage
creation, or credential access is needed to render it. JSON retains every
direct edge; the terminal renderer may fold repeated edges into a clearer tree
or outline, but cannot invent sequencing.

Execution policy stays with the lifecycle that owns the risk:

- Staging starts every ready producer. Platform chains use isolated scratch
  lanes, each completion is persisted, and a failed lane stops new work while
  already-running work drains into the resumable receipt.
- Publication starts every ready public target, with at most one active
  operation per target kind. Independent kinds overlap. A failure stops new
  public work, but every operation already started still performs its
  authoritative destination read-back before the command settles.

Artifacts remain data, not schedulable pseudo-targets. A stage contribution
names an artifact or producer input; receipt-contract resolution turns that
into an edge to the operation that produces it. Public target prerequisites
remain coarse and readable: GitHub Release waits for the Git tag, Homebrew
waits for GitHub Release, and Pub can run beside GitHub once their tag is exact.

## Responsibilities

| Owner | Owns | Does not own |
| --- | --- | --- |
| `ReleaseCommand` | repository/unit validation, checklist order, initial observation, cross-target refusal policy, stage-only exit | provider protocols, producer execution, sessions, authorization, publication transactions |
| `ReleaseStageCoordinator` | stage reuse, signing continuity, reading the source once and exporting it to isolated producer lanes, target-provided stage inputs, receipt persistence, and resuming an interrupted stage from its recorded outputs | public credentials or public mutations |
| `ReleasePublicationCoordinator` | ambient target readiness, the one authorization question, sessions acquired once per provider after the yes, the read of each target and its staged bytes right before its act, target publication, and authoritative read-back | building or changing reviewed stage bytes |
| `TargetModule` | one destination's plan, observations, optional history/readiness/session/stage contribution, publish transaction, and provider-specific recovery semantics | global ordering, authorization timing, retry policy, progress layout, or another target |

`release_progress.dart` contains presentation helpers shared by the two
coordinators. `release_preparation.dart` contains the small typed handoff from
private preparation to public authorization: first claims and signing
identity. Neither file decides policy.

## Handoffs

There are two deliberate cross-subsystem values:

- `PreparedRelease` is produced by staging and consumed by publication. It
  carries only the claims and signing facts that authorization needs; stage
  bytes remain addressed by `ReleaseStage` and proved by its receipt.
- `PublicationPlan` is assembled after staging. It carries the public steps,
  their dependency graph, target plans, the states the snapshot observed, and
  the prepared stage. Its remaining targets are what the one question asks
  about; publication reads each again right before its act.

Both copy their collections at the boundary. Coordinators may update their own
working state without letting later command code silently change what was
handed over.

## Temporal invariants

The split preserves the safety properties that make a release resumable:

1. Public unknown or conflict never authorizes private work.
2. Every producer lane has its own scratch directory; concurrent targets do
   not share mutable build space.
3. Signing identity is settled before producers run and recorded with the
   stage, and the stage's plan is recorded before any producer writes.
4. Target readiness is checked before any private work. Native sessions are
   acquired once per provider, after the yes.
5. Public state is read once, before staging, and that snapshot is what the yes
   covers. Right before an upload rk reads the registry again, and before any
   act it checks the staged bytes it publishes. Origin's tags are listed once
   a run: git refuses to replace a tag, so the push is its own check.
6. Authorization may lose work to another actor, but it cannot gain a new
   target after the operator says yes.
7. A publish command's answer is proof only where the native tool makes it
   definite: a git push that exits 0. Otherwise, and after any act that
   fails, the target reads the destination back and core decides from that
   state.
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
that form one transaction stay behind `TargetModule.publish`; derived private
inputs stay behind `TargetModule.stageInput`. The intended N+1 change is a
vertical target slice plus catalog/checklist registration, not another release
coordinator branch.

## Standalone CLI payloads

The binary chain uses one [artifact description](cli-artifacts.md) for Linux
executables and macOS Dart bundles. Companion files are build outputs and
explicit inputs to notarization and archiving, so stage reuse cannot adopt an
unrecorded runtime or module. The process identity stays on the Dart runtime
when upgrading from a single macOS executable.
