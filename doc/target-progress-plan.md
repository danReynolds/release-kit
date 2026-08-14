# Target-owned release progress plan

Status: implemented; final verification and merge review in progress.

## Outcome

Long release work always says which release output or public target is active,
what it is doing, and how long it has been doing it. A failure leaves that row
in place and the existing issue output explains why and how to recover.

```text
rk 0.1.0 · preparing release

  ✓ Git tag          v0.1.0 · checked
  ⠦ pub.dev          rk 0.1.0 · checking sign-in · 8s
  … GitHub Release   v0.1.0 · queued
  … Homebrew         rk.rb · queued
```

After authorization:

```text
rk 0.1.0 · releasing

  ✓ Git tag          v0.1.0 · pushed
  ✓ pub.dev          rk 0.1.0 · published
  ✗ GitHub Release   v0.1.0 · upload failed
  — Homebrew         rk.rb · not attempted

Issue
  GitHub rejected rk-0.1.0-macos-arm64.tar.gz
  Fix: refresh GitHub access, then run rk release again
```

`rk release --stage` uses the same progress renderer for local outputs and
stops at a completed stage. It never says `releasing`, acquires a publication
session, asks for authorization, or shows a public mutation.

## Review decisions

Three implementation-readiness reviews hardened the draft:

- An npm maintainer required credential sessions to be scoped by effective
  registry rather than target kind, and kept provenance inside `publishing`
  unless it is a separately observable operation.
- A RubyGems/native maintainer required stage rows to support several declared
  artifacts and validation-only work without adding target conditionals to
  `StageBoard`.
- A principal release engineer required one presentation owner, typed hook
  outcomes, coverage for every slow external read, explicit unit/provider/
  expectation scopes, and mutation-failure attribution that survives public
  reconciliation.

All three independently found that “the last activity supplies the failure”
was unsafe: reconciliation always displays `verifying`, which would otherwise
mislabel a definite upload or publish rejection as a verification failure.

## Product rules

1. The row names the subject; its status names only the current operation.
   Prefer `uploading 2/4` to `uploading published GitHub release assets`.
2. Do not show `ready`. Preparation finishes with a checked observation, then
   the transient board clears and the exact release plan is shown.
3. Show a distinct activity only when it explains meaningful work or waiting.
   Fast internal reads stay under `checking` or `verifying`.
4. One operation appears once. Homebrew may wait for binary archives, but it
   does not repeat the binary's build, signing, or notarization work.
5. The progress UI observes the release state machine. It never decides order,
   authorization, retry safety, public truth, or whether a target succeeded.
6. A failed subprocess is not necessarily a failed publication. RK performs
   its authoritative read-back before replacing an active row with a failure.
7. TTY output may animate and redraw. Pipes and JSON remain deterministic and
   do not receive spinner frames or elapsed-time events.
8. Report a bespoke activity only for a separately observable operation. Do
   not invent a `provenance` phase when a native publish command performs
   publication and provenance attestation as one opaque operation.
9. Every potentially slow external read belongs to a delayed progress surface,
   including reads before staging. Fast reads finish before the board appears.

## What core and targets own

RK core owns:

- lifecycle state: pending, active, complete, failed, and not attempted;
- row identity, target label, coordinate, ordering, and dependencies;
- spinner frames, elapsed time, color, alignment, redraw, and terminal width;
- authorization boundaries and the transition from preparation to release;
- final success or failure after authoritative inspection;
- issue collection, halt classification, and non-TTY/JSON behavior.

Each target owns:

- provider operations and their user-facing activity labels;
- when its real code moves from one activity to another;
- small dynamic details such as `2/4` or `waiting for pub.dev`;
- the existing diagnostic that explains a final failure and recovery;
- a precise final success word such as `pushed`, `published`, or `updated`.

Local producers use the same activity protocol for building, testing, signing,
notarizing, and archiving. They remain producers rather than pretending to be
public targets.

## Model

Do not put every possible activity in a core enum. That would make a new npm,
RubyGems, or future publisher edit core merely to say `packing`, `provenance`,
or another provider-specific operation.

Use a target-owned, internal presentation value:

```dart
final class ProgressActivity {
  const ProgressActivity({
    required this.running,
    required this.failed,
  });

  final String running;
  final String failed;
}
```

Core may offer conventional reusable values:

```dart
abstract final class CommonProgressActivities {
  static const checking = ProgressActivity(
    running: 'checking',
    failed: 'check failed',
  );

  static const verifying = ProgressActivity(
    running: 'verifying',
    failed: 'verification failed',
  );
}
```

A target defines its bespoke activities beside its implementation:

```dart
abstract final class GithubProgressActivities {
  static const drafting = ProgressActivity(
    running: 'drafting',
    failed: 'draft failed',
  );

  static const uploading = ProgressActivity(
    running: 'uploading',
    failed: 'upload failed',
  );

  static const publishing = ProgressActivity(
    running: 'publishing',
    failed: 'publish failed',
  );
}
```

The active hook receives a row-scoped handle:

```dart
progress.begin(GithubProgressActivities.uploading, detail: '2/4');
progress.begin(
  CommonProgressActivities.verifying,
  detail: 'waiting for GitHub',
);
```

The dynamic detail is separate from the activity so a failure still renders
`upload failed`, not `2/4 failed`. Activities are not a public wire contract
and are not serialized into the report.

Validate target-owned presentation values at their construction/test boundary:

- running and failure labels are nonempty, lowercase, concise, and single-line;
- labels and details contain no control characters;
- labels do not repeat the target name or contain dynamic counters;
- details are width-limited and safe to display; and
- neither labels nor details may contain an endpoint or credential value.

Do not require a declared ordered activity list. Real target paths branch: a
GitHub release may create or adopt a draft, upload only a diff, or skip uploads
entirely. Activity transitions must be emitted by the code performing the
operation so a presentation plan cannot drift from execution.

## Progress surfaces

Use one rendering/state primitive with four scoped handles:

- `StageProgress` exposes only the output/validation rows declared by that
  stage contribution;
- `UnitPreparationProgress` updates genuinely shared source, stage, and signing
  checks;
- `ProviderPreparationProgress` updates grouped preflight or session work once;
- `TargetPreparationProgress` and `TargetReleaseProgress` update one exact
  target coordinate before and after consent respectively.

The scoped handle already knows its row. A target supplies only an activity
and optional detail; it cannot rename another target, reorder rows, mark itself
successful, or mark a downstream target attempted.

Subject cardinality is explicit:

- inspection, mutation, and settlement are expectation-scoped;
- preflight and sign-in may be provider/session-scoped; and
- source continuity, stage continuity, and signing-baseline continuity are
  unit-scoped.

This prevents one `dart pub login` from appearing once per package or being
arbitrarily attached to the first package in a multi-project unit.

The renderer owns the following legal transitions:

```text
pending -> active -> complete
pending -> active -> failed
pending -> not attempted
active  -> active       activity or detail changed
```

Only the coordinator may set `complete`, `failed`, or `not attempted` for a
public target. A stage producer may complete its private artifact only after
its receipt was captured successfully.

Elapsed time resets when the activity changes. `notarizing · 48s` measures the
notarization wait, not the entire target lifetime.

## Lifecycle hookup

The existing `TargetModule` seam remains the release extension point. Add a
progress handle to its existing contexts rather than creating a second target
executor.

| Existing hook | Progress ownership |
| --- | --- |
| `inspectExact` / public gate | coordinator shows `checking` |
| `preflight` | coordinator shows `checking`; target may refine it |
| `acquireSession` | target normally shows `checking sign-in` |
| `TargetStage.prepare` | target updates its stage-output row |
| local producer act | producer updates its artifact row |
| `act` | target reports `creating`, `pushing`, `publishing`, `uploading`, or bespoke work |
| `settleAfterAct` | target reports `verifying`, optionally `waiting for <provider>` |
| `classifyFailure` | existing diagnostic supplies the issue and selects mutation versus verification failure |

The current readiness booleans are too weak for this contract. Replace them
with a typed readiness outcome carrying a diagnostic and affected scope. Hooks
running under a live board do not receive unrestricted `Output`; they return
typed outcomes while the coordinator marks the row, settles the board, prints
the issue once, and assigns the halt. Apply the same rule to active stage and
producer hooks as they are migrated.

An exception or unsuccessful act does not immediately finish the progress row.
The coordinator snapshots the last mutation activity, shows reconciliation as
`verifying`, and still calls `settleAfterAct`. Final attribution is:

| Act and read-back | Final row |
| --- | --- |
| any command result, target exact | complete; optionally note the lost response |
| act failed, target proven absent | mutation activity failed, such as `upload failed` |
| act claimed success, target absent | `verification failed` |
| target unknown or conflicting after an act | `verification failed` and the existing safety halt |

Expected provider/process failures must be returned as typed outcomes. Once a
possibly-public act begins, core attempts authoritative settlement even if the
hook throws. If settlement proves exact, it completes successfully. An
unexpected programming exception that is not reconciled remains an RK crash,
not a fabricated provider diagnostic; the board and timers still settle before
crash reporting.

## Session scopes

Session acquisition is not necessarily one-per-target-kind. npm scopes may use
different registries, several gems may share one RubyGems session, and GitHub
Release plus Homebrew may share the same `gh` identity.

Replace implicit grouping with a small internal session requirement containing:

- an opaque, non-secret key used only for deduplication;
- a safe display label such as `npm · registry.npmjs.org`;
- the target expectations covered by the session;
- the existing unreported effective-endpoint continuity value; and
- a typed acquisition operation/outcome.

Core groups by session key, acquires it once, and checks endpoint continuity for
that exact group before and after acquisition. Different hosts or credential
scopes must produce different keys. Shared built-in sessions use a shared
session component rather than choosing one target module arbitrarily. Keys,
effective endpoints, tokens, and credential-bearing URLs are never reported.

## Generic stage rows

`StageBoard` must stop recognizing pub.dev, the release manifest, `.rb` files,
and receipt-name conventions itself. Target stage rows derive from each
`TargetStage` contract plus a small target-owned presentation binding:

- declared output rows reference only paths in the contribution contract;
- validation-only contributions may declare one named row without an output;
- a contribution with several outputs receives handles only for those outputs;
  and
- a target may hide a fast private intermediate, such as release notes, while
  its receipt and validation remain authoritative.

Local binary producer contracts provide the equivalent bindings for their
archive rows. Core validates every binding against the stage contract and owns
the final manifest row. A future gem target can therefore show a `.gem`, a
signature, and a provenance/checksum output without editing `StageBoard`.

Rename `TargetStageContext.progress`, which currently means prior receipt
steps, to `priorSteps` or `receipts` before adding the scoped progress handle.
Partial-stage restoration derives completed activities and accumulated
signature/notarization notes from validated receipt evidence. It never reruns a
recorded producer or marks an archive complete merely because its build, but
not its later signing/notarization/archive work, completed.

## Provider operation events

Some destination clients currently hide several semantic operations inside one
method. `GithubRelease.publish`, for example, owns draft adoption, uploads,
draft validation, publication, and reconciliation. A module wrapper cannot
honestly narrate those boundaries from outside.

Split such clients at meaningful transaction boundaries or let them emit a
small provider-local semantic event callback. The target module maps those
events to its `ProgressActivity` values. Destination clients do not import the
output renderer or progress presentation types.

## Target activity vocabulary

Initial built-in activities should be small and honest:

- Binary: `checking`, `building`, `testing`, `signing`, `notarizing`,
  `archiving`, `verifying`.
- Git tag: `checking`, then after consent `creating`, `pushing`, `verifying`.
- pub.dev: stage `validating`; preparation `checking` and `checking sign-in`;
  after consent `publishing` and `verifying`, with `waiting for pub.dev` as a
  verification detail.
- GitHub Release: stage `validating`; preparation `checking` and
  `checking sign-in`; after consent `drafting`, `uploading n/m`, `publishing`,
  and `verifying`.
- Homebrew: stage `rendering`; preparation `checking`; after consent
  `updating` and `verifying`.

These are target-local definitions, not a promise that all targets share one
pipeline. Common values are conveniences for consistent prose.

A future npm target would normally show `packing` and `validating` while
staging, `checking sign-in` during session preparation, then `publishing` and
`verifying · waiting for npm`. If `npm publish --provenance` performs
publication and attestation in one native command, provenance is verified
evidence rather than a fictional separate activity.

## Stage mode

The stage board is live from the start of private preparation. It is organized
by output destination, as today, while each artifact narrates its producer:

```text
rk 0.1.0 · staging

  pub.dev · rk
    ✓ package source                 validated

  GitHub Release · danReynolds/release-kit
    ✓ rk-0.1.0-linux-arm64.tar.gz    built
    ✓ rk-0.1.0-linux-x64.tar.gz      built
    ⠦ rk-0.1.0-macos-arm64.tar.gz   notarizing · 1m 18s
    … release-manifest.json          queued

  Homebrew · danReynolds/homebrew-tap
    … rk.rb                           waiting for archives
```

On success, the final board remains and RK prints the stage directory. On
failure, the failed artifact remains, downstream rows become `not attempted`,
and the issue follows the board. A reusable completed stage renders immediately
as complete and does not replay producer activities.

## Full release mode

A one-shot full release has three visible surfaces, all delayed so fast work
does not flicker:

1. initial preparation plus the same live stage board as `--stage`;
2. a transient `preparing release` target board for public reads, signing
   baseline continuity, endpoint checks, and session acquisition;
3. after the release plan and yes/no authorization, a persistent `releasing`
   board for public acts and verification.

The preparation board clears before the exact plan and disclosures are shown.
There is no `ready` status. A checked target may briefly show `checked`,
`not published`, or `already published`, derived from its inspection.

Start the delayed preparation surface before the current initial inspections,
monotonicity reads, preflight, first-claim reads, and signing-history reads.
Expectation-specific reads use their target rows. Truly shared work uses one
core-owned row rather than borrowing a target:

```text
  ⠦ Release inputs   source, stage, and signing · checking
```

The release board begins with authorized targets queued and exact targets
marked already published. The coordinator distinguishes a true dependency
wait, such as Homebrew waiting for GitHub Release, from an unrelated target
that is merely queued by stable release order.

## Interactive native tools

A fixed-height board must not fight a native tool that owns the terminal.
Provide one progress-aware interactive runner that:

1. records the current activity;
2. clears the live board and prints one durable handoff line, such as
   `pub.dev · rk 0.1.0 · publishing`;
3. runs the inherited-stdio command without rewriting its output; and
4. starts a fresh board below it in `finally`, including on exceptions and
   interrupts.

Use it for commands such as `dart pub login` and `dart pub publish`. Captured
commands can keep the board live. Do not hide useful native diagnostics merely
to preserve animation. Test an OTP-style prompt and Ctrl-C so timers, cursor
state, and output restoration remain balanced.

## Failure output

The progress board is the compact location receipt. The existing `Diagnostic`
remains the explanation and recovery contract.

```text
  ✓ Git tag          v0.1.0 · pushed
  ✗ pub.dev          rk 0.1.0 · publish failed
  — GitHub Release   v0.1.0 · not attempted
  — Homebrew         rk.rb · not attempted

Issue
  pub.dev rejected rk 0.1.0
  Fix: correct what dart pub reported, then run rk release again
```

The final failed status follows the reconciliation matrix: either the captured
mutation activity or verification. The issue comes from target failure
classification. Do not duplicate the full diagnostic inside the row. A rerun
marks exact public targets as already published and resumes at remaining work
using the existing safety rules.

## Non-TTY and JSON

- A non-TTY receives no spinner frames or elapsed counters. If an activity
  remains active beyond the normal display delay, print that transition once;
  fast transitions collapse into the stable completion/failure line.
- Native interactive output remains native output.
- JSON retains the existing step verdict, action, evidence, issue, and halt
  model. Transient activity is presentation state and adds no report key or
  schema bump.
- Tests use a fake clock and captured activity transitions; production output
  never serializes wall-clock progress.
- TTY and non-TTY agree on final row state and issue text. Delayed non-TTY
  activity lines are informational, not report state.

## Developer experience for a new target

Adding an npm target should require the developer to:

1. implement the existing target expectation, inspection, preflight/session,
   optional stage contribution, act, settlement, and failure hooks;
2. define only the bespoke `ProgressActivity` values it actually needs;
3. declare any stage rows and session requirements from its own contracts;
4. update the scoped progress handle where a meaningful operation changes;
5. map provider-client semantic events when a native transaction has several
   observable operations; and
6. register the target and pass the shared target contract tests.

It must not require editing release orchestration, output formatting, spinner
code, lifecycle-state enums, failure layout, `StageBoard` target conditionals,
or JSON reporting. Native project facts and dependency discovery remain
outside the registry target module.

## Implementation sequence

### Phase 1: one internal progress primitive

- Introduce `ProgressActivity`, row state, scoped handles, fake clock, and a
  fixed-height renderer in the output layer.
- Fold the current `TargetChecks` rendering into that primitive.
- Keep `StageBoard` as the artifact-to-producer mapping, but have its rows use
  the shared state rather than a parallel unused state model.
- Give the live board explicit `suspend`, `discard`, and `settle` operations;
  guarantee timer/cursor cleanup on success, refusal, crash, and suspension.
- Validate/sanitize labels and details, reset elapsed time per activity, and
  preserve final-state equivalence between TTY and non-TTY output.
- Preserve existing output when the delayed board never becomes visible.

Review gate: renderer state transitions, terminal erasure, narrow terminals,
failure persistence, sensitive/control-character rejection, timer closure,
interactive suspension, and non-TTY behavior are covered without target logic.

### Phase 2: live stage progress

- Give `TargetStageContext` and local-producer execution scoped progress.
- Rename the existing receipt-step `progress` field and derive target stage
  rows from declared contracts/presentation bindings rather than target names,
  extensions, or receipt-name conditionals.
- Wire Binary, pub.dev validation, GitHub release-note/manifest work, and the
  Homebrew cask.
- Make `--stage` stop with the settled board and stage path.
- Replace direct terminal-outcome writes from active stage/producer hooks with
  typed outcomes so the coordinator settles the board before printing issues.
- Restore partial and complete reusable stages directly from receipt evidence.

Review gate: no producer appears twice, macOS phases are honest, failures mark
downstream outputs not attempted, and stage mode never acquires credentials or
prints public-release language. A target fixture contributes two outputs plus
a validation-only row without editing `StageBoard`.

### Phase 3: target preparation and public acts

- Add unit-, provider/session-, and expectation-scoped preparation handles
  around every slow initial/public read, signing-baseline continuity,
  context/stage revalidation, endpoint checks, and session hooks.
- Clear it before disclosures and authorization.
- Add the persistent release board after authorization.
- Replace readiness booleans and direct output access with typed outcomes.
- Introduce opaque endpoint-sensitive session requirements and deduplicate
  acquisition by session scope rather than only target kind.
- Define target-local activities in Git tag, pub.dev, GitHub Release, and
  Homebrew modules and report transitions from their real code paths.
- Split monolithic provider transactions or add provider-local semantic events
  where real sub-operations are otherwise hidden.
- Add the durable-handoff progress-aware interactive runner.
- Preserve the mutation activity across reconciliation and implement the full
  act/read-back attribution matrix, including thrown-act settlement.

Review gate: no public act moves before consent, post-consent work cannot grow,
ambiguous command failures reconcile before showing failure, and downstream
targets are distinguished as queued versus dependency-blocked. Same-provider
coordinates sharing a session acquire once, while different endpoints do not.

### Phase 4: hardening and dogfood

- Add shared target-module contract tests using fake activities and tools.
- Snapshot TTY, narrow-TTY, non-TTY, failure, resume, already-published, reusable
  and partial stage, interactive interruption, and multi-unit output.
- Update CLI/RFC documentation with the final stage and release examples.
- Dogfood a declined release, `--stage`, a resumed partial release, and RK's
  own full target set without weakening the existing release safety suite.

Review gate: a synthetic registry module exercises two coordinates, shared and
distinct endpoint sessions, two staged outputs, a validation-only row, native
interaction, a bespoke activity, and an ambiguous response reconciled to exact.
The test catalog may substitute this module, but the exercise requires no
coordinator, renderer, or `StageBoard` target-specific edit. This is an
architectural proof only; production npm publishing remains its own change.

## Acceptance

- Every wait longer than the renderer delay identifies a subject, operation,
  and elapsed time on a TTY.
- `--stage` reuses the live stage surface and stops before all public work.
- Full release clears preparation before the exact plan and begins public
  progress only after authorization.
- Targets define bespoke activities without changing a core activity enum.
- Core alone assigns public success, failure, and not-attempted states.
- Failed mutations, failed verification, and exact reconciliation use the
  explicit attribution matrix; reconciliation does not erase mutation context.
- Ambiguous acts and thrown acts are inspected before a failed row, issue, or
  crash is finalized.
- One failed target leaves completed and downstream target states visible,
  followed by exactly one actionable issue section.
- Active hooks cannot write around the live board; they return typed outcomes
  and diagnostics to its coordinator.
- Provider/session/unit work appears once at its honest scope, and credential
  scopes with different endpoints are never merged.
- Target stage rows derive from declared contracts, support multiple outputs
  and validation-only work, and restore valid partial progress honestly.
- Interactive subprocess output does not corrupt the live board, erase native
  diagnostics, leak timers, or lose its durable target/activity handoff.
- Pipes and JSON stay deterministic; the report schema does not change.
- Activity/label validation prevents multiline output, control characters,
  oversized details, duplicated target names, and credential disclosure.
- Existing stage receipts, target inspections, authorization, settlement,
  resume, dependency ordering, and halt semantics remain authoritative.
- The synthetic registry module proves novel activities, multiple stage rows,
  session grouping, native interaction, and reconciliation without editing
  release orchestration, output rendering, or target-specific `StageBoard`
  branches.

## Non-goals

- no public plugin API or runtime-loaded target system;
- no progress configuration in `release.toml`;
- no fixed universal publisher pipeline;
- no persisted event log or report-schema expansion;
- no parallel public publication;
- no change to authorization, retry, settlement, or dependency semantics; and
- no npm target in this change beyond an internal fixture proving the seam.
