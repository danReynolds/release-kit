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

Bare staging prepares every unit: each is checked, and its signing settled, in
dependency order, then every unit that needs a stage builds at once. A named
command prepares exactly that unit; it never builds or publishes a sibling.

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

1. inspects source, public destinations, monotonicity and recovery
   requirements, once;
2. prepares every required private stage, `cli` against `core`'s source from
   the same commit;
3. shows every unit's remaining targets, signing identities, first claims and
   warnings, from that one snapshot of public state;
4. asks once, then acquires each publication session once and publishes in
   dependency order; right before each act it reads that target again and
   checks the staged bytes it publishes.

A failure during preparation or review causes no publication session acquisition
or public mutation. Completed private stages remain available for retry. Local
build/signing credentials are separate from publication sessions.

`--yes` accepts this invocation's disclosure. It does not bypass preparation,
inspection or refusal, and it is not a reusable approval of an earlier JSON
report. Only `y` or `yes` accepts an interactive prompt; No, empty input and EOF
refuse. Stage, local-only work and an entirely exact public scope need no
publication confirmation. `rk stage --yes` remains a usage error.

The yes covers exactly each unit's remaining targets, by step, and nothing
else. The work may shrink when another actor completes a target: right before
each act rk reads that target again and skips one already published. A target
that was already public when asked, including every target of a no-op unit,
never becomes work under that yes, even if it has since disappeared; a later
run asks about it. Local-only outputs are staged and checked like any other,
without adding a publication prompt or target.

## Ordering and recovery

Preparation and publication diagnose their dependency graph before unit
execution: units stage side by side and publish one at a time, in dependency
order. Only a cycle refuses (`RK-DEP-003`, `RK-DEP-004`). Public acts are not a
transaction; a failure preserves earlier public truth and saved stages.

A version on pub.dev is published: rk does not compare an archive with one
already there, and a published package binds nothing to its stage. After its
own upload, rk still reads the archive back and requires the one it staged.

A partial release needs its original stage only while a unit's built release
assets are partly public (`RK-STAGE-005`): the assets on a GitHub release, a
Homebrew formula that names their hashes, or the release manifest whose hash a
pushed tag records for them. Otherwise a fresh stage publishes what remains,
even after the tag is pushed. Unread public targets refuse before fresh
preparation.

A remaining moving target may recover entirely from authenticated public inputs.
That narrow path does no package production. Homebrew renders the formula from
the archives the GitHub Release serves and requires it to match the formula the
tag-bound release manifest names; right before acting, rk reads the target
again and refuses (`RK-STAGE-005`) if its public inputs no longer allow that. An
absent package upload is never such a recovery target. Completely public units
need no local stage, and nothing in them is acted on.

## Evidence

The existing JSON schema reports per-unit verdicts/actions, issues, warnings and
attachments; no repository journal or new release group is introduced.
`authorization-disclosures/run` retains the aggregate disclosure, and each pub
package's attachment records how Pub resolved it and which packages it took
from this source.

Focused tests cover all-selected preparation before the one question,
no-public-action failure boundaries, a yes that covers only what it asked
about, targets published or gone since the snapshot, staged bytes changed after
the yes, providers publishing before consumers, and the overrides each staged
package resolves with.
