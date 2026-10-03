# Repository release contract

Status: packet 4 implementation is under qualification on
`codex/dependency-staging`. Whole-stack private staging and read-only status have
command evidence. Focused consent and native publication checks pass; the final
full suite and complete release qualification remain open. See the
[delivery plan](dependency-staging-plan.md) and
[native evidence](dependency-staging-native-proof.md).

## Scope

One root `release.toml` describes independently versioned units:

```text
rk plan [unit]              show source-only candidate topology
rk stage [unit]             prepare all units, or exactly one named unit
rk release [unit]           prepare the selected scope, then publish it
rk release --yes            accept the same reviewed publication disclosure
rk release -y              alias of --yes
```

There is no shared version, release group, automatic manifest edit or `--all`.
A compatible Fleury 0.2.0 can supply an MCP 0.1.0 build without changing MCP's
version. An incompatible local version does not replace its native requirement.

Bare staging discovers the complete selected native graph before producers run.
Providers produce exact archives before consumers use them. A named command may
use a current verified completed sibling stage, or ordinary hosted resolution;
it never builds or publishes the sibling. An authorized saved consumer retains
its frozen choices across bare/named and stage/release commands, even after a
provider stage is cleaned. Ambiguous, corrupt or unauthorized saved choices
refuse rather than silently solving again.

## Preparation, review and publication

For `core 0.2.0 -> cli 0.1.0`, a repository release:

1. inspects source, public destinations, monotonicity and recovery requirements;
2. restores or discovers selected native contexts and prepares every required
   private stage, including the consumer against exact provider archives;
3. reviews all remaining targets, receipts, signing identities, first claims,
   warnings and effective endpoints;
4. asks once, then acquires publication sessions and publishes in public
   dependency order, checking each operation again before acting.

A failure during preparation or review causes no publication session acquisition
or public mutation. Completed private stages remain available for retry. Local
build/signing credentials are separate from publication sessions.

`--yes` accepts this invocation's disclosure. It does not bypass preparation,
inspection or refusal, and it is not a reusable approval of an earlier JSON
report. Only `y` or `yes` accepts an interactive prompt; No, empty input and EOF
refuse. Stage, local-only work and an entirely exact public scope need no
publication confirmation. `rk stage --yes` remains a usage error.

Consent binds exact receipt content and stage identity, authenticated public
recovery bindings, disclosed signing and warnings, and each remaining target and first-name claim. The work may shrink
when another actor completes a target. Changed or expanded inputs/disclosures
refuse instead of asking a second, broader question. Already-public targets,
including whole no-op units, remain under repository-wide exactness checks
before consent, sessions and public acts. A disappeared target cannot become
new work under the previous review. Selected local-only outputs remain under
receipt/context checks too, without adding a publication prompt or target.

## Separate native dependency projections

Private preparation and public publication reuse native facts, but have distinct
edges. Core schedules opaque provider/consumer identities; adapters own version,
source, constraint and runtime semantics. Git tag, GitHub Release and Homebrew
retain their target lifecycle edges.

Dart publication projects original runtime requirements through the frozen
selected manifests. A private development helper or development-only selection
creates no public obligation. A development constraint that shadows a runtime
package name cannot donate that selection's transitive edges to the runtime
projection. Source-only `rk plan` shows candidates and pending native discovery;
it is not a frozen publication solution.

Immediately before a package is marked attempted, the native gate:

- fetches every relevant selected first-party provider from its declared public
  registry and verifies the exact staged archive digest and full manifest;
- resolves a fresh external consumer with only the prospective consumer archive
  preloaded under its original hosted identity, fetching runtime dependencies
  publicly and excluding private helpers and workspace source mappings;
- checks that the prospective consumer's source, version, archive and extracted
  package remain exact, and verifies the staged providers again after the solve.

A broad runtime range may select a newer compatible public dependency. That
solution is recorded separately and cannot replace the frozen private binding.
If it selects the staged coordinate, the archive must match. Same-version
repacking, unavailable provider bytes, propagation lag and an unresolvable
runtime graph stop before upload with `RK-PUB-018`; the target remains
`not_attempted`. The existing post-publication availability warning has a
different role and cannot substitute for this blocking gate. The coordinator
rechecks stage/context and destination, then uploads the same staged archive.

An SDK runtime branch that reaches a staged first-party provider is explicitly
unsupported: current frozen SDK evidence lacks the original hosted constraints
needed to prove that obligation. This is a proof limitation, not a claim that
Pub cannot solve it. An SDK branch containing only public dependencies remains
part of the fresh native consumer solve. Runtime path/Git substitutions remain
unsupported.

## Ordering and recovery

Preparation and publication each diagnose their actual dependency graph before
serial unit execution. An acyclic package/producer graph that requires units to
interleave gets an explicit regrouping refusal. Public acts are not a transaction;
a failure preserves earlier public truth and exact saved stages.

A partial release with built assets, or a package-only unit with an exact
configured Git tag, needs its original stage when remaining targets need those
bytes (`RK-STAGE-005`). The tag is a conservative unit-progress marker, not a
cryptographic commitment to the Pub dependency graph. One independently public
package does not establish prior staging of its siblings: a tagless mixed
package-only unit may prepare fresh on either command when no saved stage exists.
Retained stages still require strict restoration, and existing public archives
must still match any staged archive used for comparison. Unread public targets
refuse before fresh preparation. A missing new-schema directory cannot bypass
authenticated unit-progress or old-stage recovery requirements.

Fresh mixed-unit preparation uses already-public packages as hosted dependency
inputs, while the complete-unit contract still packages all configured outputs.
Before release, those outputs must match the exact already-public archives.
Native tar mtimes can make a fresh archive differ despite unchanged source
contents; in that case release refuses before consent. Preserve or restore the
original matching stage to finish the unit. If the public package never had an
RK stage in a fresh tagless setup, regroup it into its own fully-public unit and
prepare the remaining members separately. Regrouping does not bypass recovery
for an existing frozen stage or tagged unit. Provider eligibility does not waive
this raw archive comparison or remove outputs from the complete-unit contract.

A remaining moving target may recover entirely from authenticated public inputs.
That narrow path does no native discovery, package production or private-provider
selection, and its recovery binding is checked again before consent and acting.
An absent package upload is never such a recovery target. Completely public
units need no local stage but remain covered by the no-op growth guard.

## Evidence and remaining qualification

The existing JSON schema reports per-unit verdicts/actions, issues, warnings and
attachments; no repository journal or new release group is introduced.
`authorization-disclosures/run` retains the aggregate disclosure, and
`native-publication/<step-id>` retains transient native gate evidence. These are
invocation evidence, not a replacement stage plan.

Focused tests cover all-selected preparation before consent, no-public-action
failure boundaries, immutable consent, no-op drift, native projection and exact
archive/public consumer checks. Native fixtures use owned loopback registries;
they do not publish to public registries. Final full-suite, current Fleury release
command qualification and independent final review are still required. No real
upload, remote tag, release draft or tap write is authorized by this qualification.
