# Release pipeline architecture

`ReleaseCommand` is the decision ladder for one release unit. It resolves the
shared plan, observes current truth, refuses unsafe starting states, and hands
work to two coordinators. Targets supply destination semantics through
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
     +----> ReleasePublicationCoordinator.prepareDestinations
     |          safe readiness + frozen destination bindings
     |
     +----> ReleaseStageCoordinator.prepare
     |          signing identity + isolated producer lanes
     |          target stage inputs + receipt-backed stage
     |                          |
     |                          +---- TargetModule.stageInput
     |
     +----> ReleasePublicationCoordinator.publish
                refresh public truth + validate reviewed stage
                acquire sessions + authorize
                publish one target at a time + confirm public truth
                                |
                                +---- TargetModule.publish/confirm
```

The arrows are the architecture. There is no general event bus, lifecycle
registry, or callback for every sub-step. A new target joins at the few points
where core genuinely coordinates several destinations.

## Responsibilities

| Owner | Owns | Does not own |
| --- | --- | --- |
| `ReleaseCommand` | repository/unit validation, checklist order, initial observation, cross-target refusal policy, stage-only exit | provider protocols, producer execution, sessions, authorization, publication transactions |
| `ReleaseStageCoordinator` | stage reuse, signing continuity, source snapshot, isolated producer lanes, target-provided stage inputs, receipt persistence and revalidation | public credentials or public mutations |
| `ReleasePublicationCoordinator` | ambient target readiness, destination binding, late sessions, final public-state gates, authorization, target publication and authoritative read-back | building or changing reviewed stage bytes |
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
- `PublicationPlan` is assembled after staging. It freezes the public steps,
  target plans, observed states, destination bindings, and prepared stage
  identity that publication must revalidate before acting.

Both copy their collections at the boundary. Coordinators may update their own
working state without letting later command code silently change what was
handed over.

## Temporal invariants

The split preserves the safety properties that make a release resumable:

1. Public unknown or conflict never authorizes private work.
2. Every producer lane has its own scratch directory; concurrent targets do
   not share mutable build space.
3. Signing identity and all stage inputs are resolved before producers run and
   recorded with the stage.
4. Target readiness freezes the effective destination before any late session
   acquisition; the binding is checked again afterwards.
5. Public state, signing baseline, repository context, and stage bytes are
   revalidated immediately before authorization.
6. Authorization may lose work to another actor, but it cannot gain a new
   target after the operator says yes.
7. A publish command result is never treated as proof. The target performs an
   authoritative read-back and core decides from that state.

## Extending the system

Start with [Adding a release target](adding-a-target.md). Add a core API only
when core must coordinate a lifecycle concept across targets. Provider steps
that form one transaction stay behind `TargetModule.publish`; derived private
inputs stay behind `TargetModule.stageInput`. The intended N+1 change is a
vertical target slice plus catalog/checklist registration, not another release
coordinator branch.
