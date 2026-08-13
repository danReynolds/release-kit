# Repository release plan

Status: reviewed implementation plan for the pre-alpha schema-2 CLI.

## Outcome

One root `release.toml` may describe independently versioned units. A bare
release visits every unit that still has work, in dependency order; naming a
unit narrows the operation to exactly that unit.

```text
rk release                 release unfinished units in dependency order
rk release <unit>          release exactly one unit
rk release --yes           show the same plans; skip their yes/no prompts
rk release -y              alias of --yes
rk release [unit] --stage  prepare one unit; name it when several exist
```

This adds no release group, shared version, root version, changeset file,
`--all`, or version inference. Each unit keeps the version declared by its
native project manifest.

## Scope and order

`rk release <unit>` never broadens. If that unit needs an unpublished sibling,
its existing prerequisite check refuses and names the sibling.

Bare `rk release` derives cross-unit edges from the same first-party native
dependency facts that already produce `ExternalPrerequisite` steps. Providers
come before dependants; unrelated units retain `release.toml` order. A cycle or
invalid first-party constraint refuses before any unit acts.

Every ordered unit then uses the existing unit pipeline. Exact targets skip;
absent targets are work; unknown or conflicting targets refuse. A unit whose
public targets are already exact is skipped unless a configured local output
still needs a reusable stage. Consequently Binary remains an independent
output rather than becoming conditional on a publisher.

Bare `--stage` is intentionally not a repository coordinator. In a repository
with several units it asks for a unit name. A dependent's honest native publish
dry-run can require the provider version to be public, so claiming to stage the
whole repository before publication would be false.

## Why release is sequential

Repository release is not atomic: registries and Git cannot roll back public
acts. More importantly, `dart pub publish --dry-run` resolves dependencies. A
package pinned to a newly bumped sibling may not complete its exact stage until
that sibling is live on pub.dev.

For `core 2.0.0 -> cli 3.0.0`, RK therefore does this:

1. validate the repository dependency graph and show the stable release order;
2. prepare, inspect, authorize, and settle `core 2.0.0` through the existing
   unit pipeline;
3. only after the provider coordinate reads exact, prepare and release
   `cli 3.0.0`;
4. stop on the first refusal and preserve completed public truth.

A rerun reconstructs the order, skips exact work, and resumes. If a binary unit
stopped partway, it may resume only with the exact reusable stage that produced
the already-public bytes; RK retains the existing RK-STAGE-005 refusal rather
than rebuilding or re-signing them.

## Authorization

Remove `--confirm=<version>` completely; compatibility is unnecessary
pre-alpha. Add `--yes` and `-y` to `release` only. There is still no `--force`.

Immediately before each unit's authorization, print its exact version and
remaining target summaries, followed by the existing permanence, first-name,
signing-identity, and unprovable-platform disclosures. Ask:

```text
Release fleury_widgets 0.4.2? [y/N]
```

Only case-insensitive `y` or `yes` proceeds. EOF, empty input, or any other
answer refuses. `--yes` skips only these prompts: it still prints every unit
plan and disclosure, runs every inspection, and honours every refusal. It is
blanket authorization for the versions and targets resolved by that invocation,
not a digest-bound preapproval from an earlier JSON run; an agent wanting the
narrowest scope should name the unit.

Native session acquisition remains before the prompt. The current pipeline
freezes the effective endpoint, acquires the native session, rechecks the
endpoint, and only then asks for consent. Login must not silently redirect what
the operator authorizes.

The authorized target-step IDs are frozen at the prompt. Subsequent inspection
may shrink the set when a target becomes exact, but may never grow it. A target
that was omitted as exact and later becomes absent, unknown, or conflicting
refuses and requires a fresh plan.

Already-exact and local-only units require no authorization. Supplying `--yes`
to an idempotent exact run remains harmless. `--yes --stage` is a usage error
because staging has no public act to authorize.

## Output

Bare release starts with one compact line:

```text
Release order: fleury 0.3.0 -> fleury_test 0.2.1 -> fleury_widgets 0.4.2
```

Each unit then retains the existing stage board, destination rows, safety
disclosures, and completion output. Avoid a second batch state model or a
speculative release-plan table.

The existing `units[]`, step verdicts/actions, `halt`, and `next[]` represent a
multi-unit run in deterministic order. Authorization disclosures are qualified
by unit so sequential releases cannot overwrite one another. If an earlier
unit acted and a later unit refuses, the repository-level halt is
`stoppedPartway`, never `beforeActing`.

`--yes` is invocation input and is not recorded as release evidence. No report
schema bump is needed unless implementation adds or changes a serialized key.

## Implementation shape

Keep the change deliberately small:

1. add a short stable topological ordering helper over
   `ExternalPrerequisite.declaredBy`;
2. have `ReleaseCommand.run` resolve the requested scope and call the existing
   one-unit pipeline in that order, stopping at the first refusal;
3. replace typed-version authorization with a yes/no callback and `--yes`;
4. freeze the unit's authorized step IDs across post-consent revalidation; and
5. make halt wording respect public acts performed by an earlier unit.

Do not add a repository coordinator object, mutable per-unit batch context,
wave abstraction, public group/transaction model, or new TOML.

## Acceptance

Focused tests prove:

- stable dependency order and cycle refusal before acting;
- a named dependent never broadens and refuses an absent sibling;
- a provider settles before its dependent begins staging;
- a later-unit refusal reports `stoppedPartway` and a rerun skips exact work;
- a partial binary unit still requires its exact reusable stage;
- each unit displays version, remaining targets, and existing disclosures;
- `y`, `yes`, `--yes`, and `-y` authorize while No/empty/EOF do not;
- `--yes` never bypasses conflicts, drift, source, stage, signing, or endpoint
  checks;
- post-consent work may shrink but never grow;
- multi-unit `--stage` requires a unit and never publishes;
- multi-unit JSON is deterministic; and
- the existing single-unit release safety suite stays green on the same path.

Dogfood discovery, status, plan rendering, and a declined release against a
Fleury-shaped repository without publishing it. Live publication remains a
separately authorized receipt.
