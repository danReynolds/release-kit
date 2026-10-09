# Adding a release target

A release target is one public lifecycle: rk reads it, prepares any private
inputs, asks for authorization, acts once, and reads the same public state
again. A target is a built-in source module, not a runtime plugin.

The GitHub Release target is the worked example. It publishes the exact
archives and `release-manifest.json` recorded in rk's completed stage, using
the selected Git tag as its identity and the matching changelog entry as its
body. It creates and verifies a private draft before making the release
public.

## The boundary

Core owns the pipeline:

```text
read -> stage -> authorize -> publish -> confirm
```

See [Release pipeline architecture](release-pipeline.md) for the phases and
what each unit carries between them.

That includes the release model, stage validity, scheduling, progress
rendering, authorization, retry policy, and the final decision about whether
public state is exact. What a target is (its identity, its stage work, the
files it publishes, what it waits for) is model data: `UnitRelease.derive`
states the four targets' fixed rules.

A target module owns only what those operations mean at its destination. Its
whole surface is one table:

| Member | Required? | Purpose |
| --- | --- | --- |
| `target` | yes | The configuration target this module implements. |
| `read` | yes | What the destination holds for this release, compared with the complete stage when there is one, and the lane's public history. Used by the snapshot, before each act, and by default after one. |
| `prepare` | no | Produces a piece of the target's stage work, such as release notes or a Pub archive. |
| `ready` | no | Ambient checks before staging; with `signIn`, the native session, once per run after the yes. Defaults to ready, so a target with credentials must override it. |
| `publish` | yes | Performs one provider transaction. An act whose provider answer is its read-back, as a Git tag push is, returns that state with the act. |
| `confirm` | usually no | Reads back what an act did; defaults to `read`. |
| `explain` | yes | Names, in the target's own code and sentence, a conflict found before acting. Core decides the halt. |
| `explainAct` | no | Names an act that did not settle exact, and the command to run next; defaults to the shared wording, what the act or the read after it said. Core decides the halt. |

`read` returns `TargetHistory` beside the state: the lane's current
`version`, any provider-specific `problems`, and any irreversible `claims`.
Core does not parse evidence maps or ask a second hook what the first one
meant. Typed facts ride on `Inspection`: `sourceMismatch`, `releasedFrom`,
and `recoversWithoutStage`, which says a moving channel can finish from
public inputs without its stage.

## GitHub Release as the worked example

The implementation is one vertical slice:

```text
lib/src/targets/github_release/
  module.dart                 read, prepare, ready, publish, explain
  client.dart                 GitHub CLI reads and the publish transaction
  release_notes_stage.dart    the release notes, from the staged changelog
```

Draft creation, asset upload, verification and publication are not four core
hooks. Together they are GitHub's one publication transaction, so they stay in
`client.dart` behind `publish`. The client returns facts such as whether a
draft changed, whether a public act may have happened, and the transcript;
core applies the shared halt policy.

The target does not reconstruct producer paths. Its `Target.files` names each
file it publishes, and the stage's receipt holds each one's size and digest,
so the bytes the operator reviewed are the bytes the target verifies and
uploads.

## The same boundary across the built-ins

```text
lib/src/targets/git_tag/
  module.dart                 read, publish, explain
  client.dart                 exact git protocol reads and writes
  transaction.dart            create, sign, and push one tag

lib/src/targets/pub_dev/
  module.dart                 read, prepare, ready, publish, confirm, explain,
                              explainAct
  client.dart                 pub.dev HTTP reads
  package_stage.dart          the native Pub archive

lib/src/targets/homebrew/
  module.dart                 read, prepare, publish, explain, explainAct
  client.dart                 tap reads and the compare-and-swap update
  formula_stage.dart          the formula, from the archives' digests
```

Git tag's signing and push form one transaction behind `publish`, and its
push is confirmed by git. pub.dev and GitHub Release sign in with their native
tools (`dart pub`, `gh`) once per run, after the yes. pub.dev polls after an
accepted upload, so it overrides `confirm`.

## Adding target N+1

1. Add its configuration name, scope, prerequisites and Git requirement to
   `PublishTarget`.
2. Give it a rule in `UnitRelease.derive`: its `Target`, any stage `Work` it
   prepares and the files it publishes, and its place in the plan view and
   the stage board. Each is one switch arm beside the other four.
3. Create `lib/src/targets/<target>/module.dart`. Keep native API or CLI
   mechanics in a sibling client when they would obscure the lifecycle.
4. Add its module to `TargetCatalog.moduleFor`, an exhaustive switch that
   does not compile until every `PublishTarget` has one.
5. Place it in a publication lane in `Publication.publish`.
6. Add the installed-binary reference shown by `rk target <name>`.
7. Extend `unit_release_test` for its identity, files and order, and add
   client tests for exact, absent, conflict, uncertain acts, and read-back.

Before adding a hook, ask whether core must coordinate the operation. If core
only needs the final provider-neutral outcome, keep the operation inside the
target's client.

## Acceptance bar

A target is ready when:

- status and release use the same `read`;
- an already-exact target is a no-op;
- absent, conflicting and unreadable states are distinct;
- every act is followed by an authoritative read-back;
- what it publishes comes from the stage's receipt;
- private provider state and possibly-public state are reported separately;
- provider code does not leak into commands or the stage runner.

## Optional executable installation capability

Installation is a separate `InstallationProvider` beside a target module,
currently `targets/{homebrew,pub_dev,github_release}/installation.dart`.
It implements inspect, install and uninstall for an `ExecutableProject`; it
returns a complete command map rather than changing PATH itself. The shared
manager owns capability checks, locking, cancellation and switching. Local has
its own adapter because a checkout is not a publication target. SDK publication
targets do not acquire an installation UI just by existing.
