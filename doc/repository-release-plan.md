# Repository release contract

Status: implemented. How packages get their dependencies while they are
staged is described in [practical staging](practical-staging.md).

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
version. An incompatible local version leaves the requirement to pub.dev.

Bare staging prepares every unit in dependency order. A named command prepares
exactly that unit; it never builds or publishes a sibling.

## Dependencies

A package is staged the way its consumers will resolve it. Pub resolves it
in a scratch mirror of the commit, as a root of its own, with no lockfile and
through its normal cache. rk writes the mirror's `pubspec_overrides.yaml`,
which replaces any tracked override. In a workspace it also takes the package
out of the workspace's resolution.

That file overrides only this repository's packages that cannot come from
pub.dev yet:

- a package it needs at runtime, directly or through such packages, whose
  version here satisfies what is asked of it and is not published yet;
- a package only its development needs, whose consumers never resolve it.

Everything else comes from pub.dev. Once a version is published there, Pub
takes it from there, as consumers do, even when this source has unreleased
changes at that version. Pub leaves overrides files out of archives, so these
paths never change what is published.

`rk release` publishes providers before consumers. A consumer's upload waits
until each version it needs is public. A named release whose package needs a
version no unit in it publishes asks for that version to be published first.
Development-only dependencies never become publication prerequisites.

## Preparation, review and publication

For `core 0.2.0 -> cli 0.1.0`, a repository release:

1. inspects source, public destinations, monotonicity and recovery requirements;
2. prepares every required private stage, `cli` against `core`'s source from
   the same commit;
3. reviews all remaining targets, receipts, signing identities, first claims,
   warnings and effective endpoints;
4. asks once, then acquires publication sessions and publishes in dependency
   order, checking each operation again before acting.

A failure during preparation or review causes no publication session acquisition
or public mutation. Completed private stages remain available for retry. Local
build/signing credentials are separate from publication sessions.

`--yes` accepts this invocation's disclosure. It does not bypass preparation,
inspection or refusal, and it is not a reusable approval of an earlier JSON
report. Only `y` or `yes` accepts an interactive prompt; No, empty input and EOF
refuse. Stage, local-only work and an entirely exact public scope need no
publication confirmation. `rk stage --yes` remains a usage error.

Consent binds exact receipt content and stage identity, authenticated public
recovery bindings, disclosed signing and warnings, and each remaining target and
first-name claim. The work may shrink
when another actor completes a target. Changed or expanded inputs/disclosures
refuse instead of asking a second, broader question. Already-public targets,
including whole no-op units, remain under repository-wide exactness checks
before consent, sessions and public acts. A disappeared target cannot become
new work under the previous review. Selected local-only outputs remain under
receipt/context checks too, without adding a publication prompt or target.

## Ordering and recovery

Preparation and publication diagnose their dependency graph before serial unit
execution. An acyclic package/producer graph that requires units to interleave
gets an explicit regrouping refusal. Public acts are not a transaction; a
failure preserves earlier public truth and saved stages.

A partial release with built assets, or a package-only unit with an exact
configured Git tag, needs its original stage when remaining targets need those
bytes (`RK-STAGE-005`). The tag is a conservative unit-progress marker. One
independently public package does not establish prior staging of its
siblings: a tagless mixed package-only unit may prepare fresh on either command
when no saved stage exists. Existing public archives must still match any
staged archive used for comparison. Unread public targets refuse before fresh
preparation.

Before release, a fresh stage's archive must match an already-public archive of
the same package version. Native tar mtimes can make a fresh archive differ
despite unchanged source contents; in that case release refuses before
consent. Preserve or restore the original matching stage to finish the unit.
If the public package never had an rk stage in a fresh tagless setup, regroup it
into its own fully-public unit and prepare the remaining members separately.

A remaining moving target may recover entirely from authenticated public inputs.
That narrow path does no package production, and its recovery binding is
checked again before consent and acting. An absent package upload is never such
a recovery target. Completely public units need no local stage but remain
covered by the no-op growth guard.

## Evidence

The existing JSON schema reports per-unit verdicts/actions, issues, warnings and
attachments; no repository journal or new release group is introduced.
`authorization-disclosures/run` retains the aggregate disclosure, and each pub
package's attachment records how Pub resolved it and which packages it took
from this source.

Focused tests cover all-selected preparation before consent, no-public-action
failure boundaries, immutable consent, no-op drift, providers publishing before
consumers, and the overrides each staged package resolves with.
