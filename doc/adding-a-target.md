# Adding a release target

A release target is one public lifecycle: rk plans it, observes it, prepares
any private inputs, asks for authorization, acts once, and observes the same
public state again. A target is a built-in source module, not a runtime plugin.

The GitHub Release target is the worked example. It publishes the exact
archives and `release-manifest.json` frozen in rk's completed stage, using the
selected Git tag as its identity and the matching changelog entry as its body.
It creates and verifies a private draft before making the release public.

## The boundary

Core owns the pipeline:

```text
plan -> inspect -> stage -> authorize -> publish -> confirm
```

See [Release pipeline architecture](release-pipeline.md) for the coordinator
boundaries and the typed handoffs between private preparation and publication.

That includes checklist order, prerequisite enforcement, stage validity,
progress rendering, authorization, retry policy, and the final decision about
whether public state is exact. Core never branches on GitHub, pub.dev, or
Homebrew.

A target module owns only the destination-specific meaning of those
operations. Its complete surface is small enough to read as one table:

| Member | Required? | Purpose |
| --- | --- | --- |
| `target` | yes | The configuration target this module implements. |
| `plan` | yes | Describes the destination, intended version, and public artifacts. |
| `inspectCandidate` | yes | Reads whether this exact release already exists. |
| `inspectHistory` | no | Returns typed current-version, refusal, and first-publication facts when candidate inspection is not enough. |
| `conflictRemedy` | yes | Explains how to resolve conflicting candidate state. |
| `publishActivity` | yes | Names the module's one meaningful public mutation. |
| `checkReadiness` | yes | Checks ambient requirements before private preparation. |
| `authentication` | no | Acquires a native-tool session late in the pipeline. |
| `destinationBinding` | usually no | Freezes the effective destination across authentication. |
| `publish` | yes | Performs one provider publication transaction. |
| `confirmPublication` | usually no | Reads public state after publication; defaults to `inspectCandidate`. |
| `classifyUnconfirmedPublication` | usually no | Refines shared failure handling for a real recovery semantic. |
| `stageInput` | no | Derives a private, receipt-backed input required by this target. |
| `stageRecoveryBinding` | no | Identifies public inputs that let a moving channel resume without its stage. |

`TargetHistory` is deliberately one result rather than several hooks. A target
translates provider data into its current `version`, any provider-specific
`problems`, and any irreversible `claims`; core does not parse evidence maps or
ask a second callback what the first callback meant.

Defaults cover shared read-back, destination binding, failure classification,
and targets without history, authentication, stage inputs, or moving-channel
recovery. Override one only for a concrete provider semantic.

## GitHub Release as the worked example

The implementation is one vertical slice:

```text
lib/src/targets/github_release/
  module.dart                 public target lifecycle
  client.dart                 GitHub CLI reads and publish transaction
  release_notes_stage.dart    optional changelog-derived stage input
```

The module is deliberately readable from top to bottom. Its essential shape
is:

```dart
final class GithubReleaseTargetModule extends TargetModule {
  const GithubReleaseTargetModule();

  @override
  PublishTarget get target => PublishTarget.githubRelease;

  @override
  TargetPlan plan({
    required ResolvedUnit unit,
    required Step step,
    String? repository,
  }) {
    final tag = requiredTargetTag(unit, target);
    final artifacts = ReleaseAssets.expectedForUnit(unit).toList()..sort();
    final coordinate =
        repository == null ? tag : '$repository/releases/tag/$tag';
    return TargetPlan(
      label: 'GitHub Release',
      kindLabel: 'GitHub Release',
      identity: repository ?? 'no origin remote',
      coordinate: coordinate,
      targetVersion: unit.version.canonical,
      step: step,
      artifacts: artifacts,
      planNote: '${artifacts.length} assets to $coordinate',
    );
  }

  // inspectCandidate, checkReadiness, publishActivity, publish, and
  // conflictRemedy follow.
}
```

Draft creation, asset upload, verification, and publication are not four core
hooks. Together they are GitHub's one publication transaction, so they stay in
`client.dart` behind `publish`. The client returns facts such as whether a draft
changed, whether a public mutation may have happened, and the final transcript;
core applies the shared failure and halt policy.

Likewise, the target does not reconstruct producer paths. `ReleaseBundle`
joins the completed-stage receipt to the public asset names once, and both
inspection and publication consume that same bundle. This keeps the bytes the
operator reviewed identical to the bytes the target verifies and uploads.

Release notes are a legitimate optional stage contribution: they are private,
derived from the staged source, and required by this target. Their contract,
validation, and producer live together in `release_notes_stage.dart` rather
than becoming several general-purpose hooks.

## The same boundary across the built-ins

The other targets use the same vertical-slice shape, with only the pieces their
lifecycles actually need:

```text
lib/src/targets/git_tag/
  module.dart                 lifecycle and rollback classification
  client.dart                 exact git protocol reads and writes
  transaction.dart            create, sign, validate, and push one tag

lib/src/targets/pub_dev/
  module.dart                 lifecycle and immutable-registry semantics
  client.dart                 pub.dev HTTP reads
  package_stage.dart          native Pub archive stage input
  session.dart                native Pub authentication session

lib/src/targets/homebrew/
  module.dart                 lifecycle and repairable-channel semantics
  client.dart                 GitHub tap reads and compare-and-swap update
  cask_stage.dart             rendered cask stage input
```

These differences did not require more core hooks. Git tag's signing and
rollback steps form one transaction behind `publish`; pub.dev alone contributes a
native authentication session; pub.dev and Homebrew contribute target-owned
stage inputs. Each module overrides shared failure handling only where the
destination's public-state semantics genuinely differ.

## Adding target N+1

1. Add its configuration name, scope, prerequisites, and Git requirement to
   `PublishTarget`.
2. Add one public `StepKind` and place its step explicitly in `Checklist`, with
   the exact prerequisites it needs. Do not hide ordering in target callbacks.
3. Create `lib/src/targets/<target>/module.dart`. Keep native API/CLI mechanics
   in a sibling client when they would obscure the lifecycle.
4. Register one module in `TargetCatalog`. Its coverage check fails until every
   `PublishTarget` has exactly one module.
5. Add the installed-binary reference shown by `rk target <name>`.
6. Extend catalog tests for identity, artifacts, order, and any stage contract;
   add client contract tests for exact, absent, conflict, uncertain mutation,
   and successful read-back.

Before adding a hook, ask whether core must coordinate the operation. If core
only needs the final provider-neutral outcome, keep the operation inside the
target's client. If several targets independently need the same lifecycle
concept, add the smallest typed core abstraction after the second real use.

## Acceptance bar

A target is ready to serve as an example when:

- status and release use the same `plan` and `inspectCandidate` path;
- an already-exact target is a no-op;
- absent, conflicting, and unreadable state are distinct;
- publish is followed by authoritative read-back;
- staged public bytes come from receipt-backed shared abstractions;
- private provider state and possibly-public state are reported separately;
- provider code does not leak into commands or shared stage orchestration;
- optional hooks correspond to visible lifecycle differences;
- the module explains the lifecycle without requiring the reader to understand
  provider parsing or subprocess details first.

All four built-in targets meet this bar. Repetition that remains after clean
targets is evidence for a shared abstraction; a hypothetical target is not.
