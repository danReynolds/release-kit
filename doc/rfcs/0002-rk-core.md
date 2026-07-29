# RFC 0002: rk core

- Status: Approved for implementation
- Revision: 3 (2026-07-29) — local-only scope; consolidates eight
  adversarial reviews
- Supersedes: RFC 0001 as build authority; 0001 remains the threat catalog
  and assurance ladder
- MVP scope: Dart packages and Dart CLIs, released **from the operator's
  own machine**, to pub.dev, GitHub Releases, and Homebrew
- CI: designed for, deferred from the MVP. See "CI readiness" — its
  constraints are binding on the MVP.
- First demo: keybay

## What rk is

rk is a checklist compiler. It reads what native manifests already say plus
one small file of release intent, derives the complete ordered checklist for
a release, and executes it with three behaviours a human cannot sustain: it
validates everything before acting, it inspects reality before every step so
re-running is always safe, and it refuses to guess.

rk manages the release steps and defers authentication to the native tools
that own it — `dart pub`, `codesign`, `notarytool`, `gh`, `git`. It stores
no secrets, keeps no state, and creates no git objects.

## Principles

1. **One source of truth per fact.** Native manifests own names, versions,
   executables, and dependencies. `release.toml` owns intent. Published
   reality owns identity. The machine owns credentials.
2. **Reality is the database.** Destinations are inspected, never mirrored
   into records.
3. **Inspect, act, verify.** Every step checks reality before acting and
   confirms it afterward. Effects are idempotent; resume is re-run.
4. **Auth defers to native tools.** rk never stores, receives, or prompts
   for a secret value; it arranges context and lets the native tool work.
5. **Identity, not acceptability.** An artifact is reusable only when an
   external authority can confirm it is *the* artifact. "It looks valid" is
   not identity.
6. **Fail closed, and fail early.** Ambiguity, mismatch, and unknown state
   stop before any effect — and a release rk cannot finish is refused
   before the work, not at the last step. No hooks, no templates, no
   `--force`.
7. **Verify public state.** Everything published is re-downloaded and
   compared against what was built.
8. **Complexity must name its failure.** A mechanism enters only by naming
   the failure it prevents and showing that failure matters for this fleet.
   RFC 0001 is the priced ladder of everything deferred.

## The failures v1 addresses

Ranked by probability times cost:

1. **Human error** — wrong version, wrong package, missing changelog,
   publishing a back-version. Near-certain over years; registry mistakes
   are permanent.
2. **Partial releases** — an interrupted run, and a resume that rebuilds or
   republishes the wrong thing.
3. **Fleet drift** — bespoke per-repository release code rotting
   independently.

Identity misuse and exotic threats are RFC 0001's domain and are not
addressed here beyond fail-closed defaults.

## Terminology

- **Release** — one unit at one moment, identified by its tag when one
  exists. Never called a workflow or pipeline.
- **Unit** — a named set of projects released together under one tag
  pattern. The tag names the release; each project's version comes from its
  own manifest. Projects in a unit normally move together but are not
  required to be identical — after a partial publish they cannot be, and
  recovery must stay possible.
- **Checklist** — the deterministic ordered set of steps rk derives. Pure
  data, identical on every machine.
- **Step** — one checklist entry with a stable id
  `<unit>/<adapter>/<coordinate>`. Every step implements inspect, act,
  verify.
- **Verdict** — `absent`, `exact`, `conflict`, or `unknown`.
- **Workspace** — the per-release cache of intermediates under `.rk/work/`,
  keyed by release and commit. Disposable; only self-authenticating
  artifacts are reused from it.
- **Draft** — the pre-publication GitHub release: staging area, aggregation
  point, and the durable memory that lets a release resume.
- **Adapter** — a closed module: ecosystem, build, transform, or
  destination.

## Configuration

One file, `release.toml`, at the repository root. Keybay's complete
configuration:

```toml
schema = 1

[release.core]                 # tag keybay-v{version}
path = "packages/keybay"
publish = ["pub.dev"]

[release.cli]                  # tag keybay_cli-v{version}
path = "packages/keybay_cli"
publish = ["pub.dev", "github-release", "homebrew"]
binary_platforms = ["linux-x64", "linux-arm64", "macos-arm64"]
```

Rules:

- `schema` is exact; unknown versions and unknown fields anywhere are
  errors.
- A unit with one project declares it inline; a unit with several uses
  `[[release.<unit>.project]]` rows. Both is an error. No empty headers.
- `tag` is optional for a single-project unit and derives from the
  publication target's documented convention — for pub.dev, `v{version}`
  when the repository publishes one package and `<package>-v{version}` when
  it publishes several. A multi-project unit must declare it, because a set
  of packages has no canonical name. An explicit `tag` always wins.
- Project paths are canonicalized; duplicates and nesting fail. No
  recursive discovery: a project releases only if listed.
- `publish` is an unordered set of closed channel names; duplicates fail.
- `binary_platforms` is required by platform-bearing channels and rejected
  without one. Its vocabulary is closed and enumerable; identifiers match
  the public asset names (`linux-x64`, not `linux-gnu-x64`), since Dart
  offers no libc selection and the glibc floor is a recorded fact rather
  than an authoring choice. It is declared rather than defaulted because
  the set is a product promise.
- Archive contents are conventional and not configurable: the executable,
  LICENSE, and README.
- System runtime dependencies are not declared; an application that needs a
  system tool reports that itself.
- The toolchain is not declared. rk resolves it from the ecosystem's own
  files — for Dart, the pubspec SDK constraint, since no exact version is
  recorded anywhere by design — verifies the resolved toolchain satisfies
  that constraint, and records which one built each artifact.
- Native vetoes are absolute: `publish_to: none` vetoes pub.dev, not the
  release.
- **Monotonicity:** a project's version must exceed every version already
  published for that package, and a release tag must exceed every earlier
  tag in the unit's namespace — excluding the tag authorizing this release,
  so a partially published unit can resume. A project already live at its
  manifest version inspects as `exact` and is skipped.

### Identity

Identity facts are derived, not declared, so the check becomes "this
release matches the last one" — impossible to typo and self-maintaining:

| Fact | Derived from |
|---|---|
| Apple team, code identifier | the designated requirement of the macOS binary in the current published release |
| Tag signer | the signature on the previous release's tag |
| Homebrew tap | `<repository owner>/homebrew-tap`, Homebrew's convention |

An optional `[identity]` block overrides any of them, and matters in two
cases. A **deliberate migration** — a new tap or team — overrides a
`conflict` on purpose. A **first release** has no baseline: the Apple team
comes from the keychain, filtered to `Developer ID Application` identities
(one is unambiguous; several fail closed with the list; none reports that a
certificate must be installed), and rk does not read `.xcodeproj` files,
which in practice belong to example apps with unrelated identities. The
code identifier has no source, because it is a name a human chooses and
cannot change without breaking Keychain continuity for existing users; rk
proposes reverse-DNS and requires confirmation once. A tag signer, where
earlier tags are unsigned or absent, is the key about to sign, confirmed
once. Keybay needs none of this: its 0.1.0 release supplies every baseline.

## The four verbs

`rk init` · `rk status` · `rk release` · `rk verify`. Bare `rk` runs
`status`.

Every verb takes **one optional positional**: a unit name or a tag. Bare
invocation works in a single-unit repository and, in a multi-unit one,
lists the units and stops — choosing what to publish permanently is not an
arrow key.

- **`rk init`** — write `release.toml`. Reads the repository, shows the
  config it proposes, writes it on confirmation. No network, no settings,
  nothing irreversible, no questions. It never edits an existing config,
  never adds a project silently, scans **git-tracked manifests only**, does
  not prefill `binary_platforms` without a platform-bearing channel, and
  never infers a binary channel from an `executables:` block — declaring an
  executable means `dart pub global activate` works, not "ship a signed
  tarball." A repository with nothing releasable exits 0.
- **`rk status`** — read-only; the only verb that changes nothing. Compares
  local state against published reality: live version and date per
  destination, manifest version, whether local is ahead, in-flight
  progress, and anything blocking. Prints the next command. `--watch`
  follows an in-flight release; `--exit-code` makes blocked non-zero.
- **`rk release`** — execute. Refuses at the start anything it cannot
  finish; re-validates independently rather than trusting `status`;
  verifies the authorizing tag's signature where one exists; then inspects
  before acting at every step. Halts on `conflict` or `unknown`; safe to
  re-run at any point.
- **`rk verify`** — takes a tag and resolves `release.toml` and sources **at
  that tag**, so an old release is never checked against today's config.
  With no argument, verifies each unit's latest published release. On
  success it prints provenance — when each destination received it, from
  which commit, signed by whom — and names what is not knowable rather than
  omitting it.

### Authorization

A local release is authorized by the operator's presence: publishing
requires their credentials, and rk prompts with the full consequences.
Where the act is permanent, the confirmation is **typing the version**, not
a keystroke — "wrong version" is the highest-ranked failure and this is the
only defence that targets it. Without a human present, rk refuses.

A signed tag is not required for a local release, but where one exists rk
verifies its signature against the expected signer and records it. Creating
tags remains the user's own tool; `rk status` prints the exact command, and
first checks that git signing is configured, since `gpg failed to sign the
data` is otherwise a dead end with rk's name nowhere in it.

There is no `--yes` and no `--force`. Every classic use has a real path: a
permanent registry conflict cannot be forced because the permanence is
server-side, `unknown` needs a retry which is free, and a wedged draft is
unblocked by a command rk prints for the human to run.

## Output

**Collapse.** Anything already true collapses; only what needs a human
expands. A level with one child collapses onto its parent; a level whose
children agree collapses to their shared fact — three channels at one
version are one line, not three.

**Terseness.** rk does not narrate itself. Timings, check counts, and
per-step detail belong to `-v`. A line that reads the same on every
successful run is noise.

**Attention.** The verdict leads the line, in a gutter: `+` will create ·
`·` already satisfied · `~` in progress · `✓` proven · `!` needs a human ·
`✗` blocked or conflicting · `?` unknown · `–` expected absent · `→` your
next move. Glyphs always accompany a word; `NO_COLOR` and non-TTY are
honoured; progress lines are transient and suppressed when stdout is not a
TTY.

**Every halt opens with a plain sentence** answering the only two questions
an operator has, before any verdict noun: did anything happen, and is
re-running safe. Three cover every case — "rk stopped before acting.
nothing changed. safe to re-run." / "rk acted, then lost sight of the
result. an effect may exist. still safe to re-run." / "rk did not act. this
cannot be fixed by re-running." A halt states what is **already permanent**
before its remediation.

**Every conflict prints the difference**, not the fact of one: differing
files and digests, a formula line diff, a per-object asset table. "A human
decides" is only true if the human is given the evidence.

**Refusing to act is not refusing to instruct.** Where rk will not perform
a destructive step, it prints the exact command with identifiers filled in
and the one-line reason rk will not run it.

All problems are reported in one pass, each naming its source location and
remediation. Grouping follows the configuration — unit, project, channel,
platform — subject to collapse. `--json` is the named machine surface,
stable, keyed on step id, surviving non-zero exit and carrying
`safe_to_rerun`. Exit codes: `0` clean, complete, or blocked; `1` refusal;
`2` usage.

**Diagnosis.** Reality records what exists and nothing about why a run
failed. On any non-clean exit rk writes a diagnosis directory inside the
workspace with the resolved checklist, per-step verdicts and durations,
redacted provider request metadata, and native tool stderr. rk never reads
it back; deleting it is always safe.

## Execution

Three phases: **parse** (strict subset parsers, no I/O beyond reading
files), **derive** (units, tags, versions, dependency order, prerequisites,
the checklist — deterministic and offline), then **probe** (read-only
reality).

Ordering comes from native dependencies: within a unit, publication follows
first-party dependencies; across units, a first-party dependency becomes a
public-reality prerequisite whose required version comes from the
depended-on project's manifest — never from the pin's form, since deriving
only from exact pins misses the ordinary caret pin most packages use.

### Verdicts

- `absent` — proceed. Concluded only from a definitive provider negative,
  never from a timeout.
- `exact` — verified equal; skip.
- `conflict` — halt; a human decides, with the evidence.
- `unknown` — rk could not determine state. Never collapsed into `absent`.
  Two shapes needing different guidance: **pre-act**, where rk never wrote
  and the world is unchanged; **post-act**, where rk wrote and lost the
  response, so the next run must classify what it finds rather than blindly
  retrying.

After rk's own act on a coordinate, inspection polls to a bounded deadline
before concluding anything — destination APIs lag their own writes.

### Reuse

Only self-authenticating artifacts are reused: a **signed** macOS binary
(`codesign` verification plus team and designated requirement — forging one
requires the certificate, and an older correctly signed binary fails the
embedded version check), an artifact **staged at a destination** (identity
is the digest the destination reports), and **notarization state**
(confirmed with Apple). Everything else — unsigned binaries, unstaged
archives, package archives — is rebuilt. A file on disk is not evidence of
itself, and rk mints no signatures of its own.

The workspace is keyed by release and commit, so successive runs of the
same release share one, but a workspace is never seeded from a different
run: a tag deleted and re-pushed at another commit would otherwise let rk
sign and publish binaries from the wrong source while every acceptability
check passed.

### The draft

- **Adoption.** REST lookup by tag returns published releases only, and the
  forge permits multiple drafts sharing one tag name. Adoption lists all
  releases, filters by tag, and requires exactly one candidate: zero →
  create, then re-list and `conflict` if a twin appeared; two or more →
  `conflict`, naming both ids for human deletion.
- **Staging is hash-idempotent** — assets expose a digest, so `exact` is
  name plus digest with no download.
- **Repair, narrowly.** While still a draft, an asset not in state
  `uploaded`, or whose digest is not this release's, may be deleted by
  asset id and re-uploaded. Interrupted uploads leave corpses and same-name
  re-upload is rejected, so without this the most probable failure wedges
  the release permanently. This is repair of staging, not cleanup of
  product; rk still never deletes a draft, tag, or published release.
  Repair is always announced.
- **The flip re-verifies against reality.** Immediately before publishing:
  enumerate the draft's assets, require the exact inventory, confirm every
  digest, recompute the checksums file and formula from those digests and
  compare against what is staged. Only then publish once, then verify the
  release reports immutable.
- **After publishing, verification failure is terminal.** Immutable
  releases cannot be edited and deleting one permanently burns the tag
  name. rk retries verification to a bounded deadline, then states the only
  honest remedy: ship the next version.

### Mutable pointers

The Homebrew formula updates compare-and-swap: inspect (absent / exact /
older-clean-base / conflict), apply only if the inspected blob is still
current, re-read, then install from the public tap as a final check. "Older
clean base" is derived from reality — the tap formula must byte-equal the
formula asset of the release it names — so a hand-edited formula correctly
yields `conflict`. Reads use git fetch, never a CDN path.

### Cleanup

Published assets are the product and are never cleaned up. The workspace is
deleted by the run that completes its release; a failed step or non-clean
verdict keeps it for diagnosis. Residue from an abandoned release is
surfaced by `status` with sizes and deleted only by a human.

## Credentials

Two rules. **Facts** come from the manifests, published reality, or an
explicit `[identity]` override — never from the environment. **Secrets and
sessions** resolve from the platform's native store under a conventional
name, with no mapping file, no ambient pickup, and no interpolation; every
resolved credential is checked against the declared facts before use, so a
wrong credential fails as loudly as a missing one.

| Need | Local source |
|---|---|
| pub.dev publish | `dart pub login` session |
| GitHub release | `gh auth` session |
| macOS signing | keychain identity matching the derived team |
| Notarization | `notarytool` profile `rk-notary` |
| Tap update | normal git auth to the tap |
| Tag signing | operator SSH signing key |

Native login commands are named by diagnostics, run by the user, and never
read by rk. Publishers run attached to the terminal so registry MFA prompts
pass through.

## Adapters

Every step implements inspect, act, verify; destinations share one
interface:

```text
inspect(coordinate) -> absent | exact | conflict | unknown
stage(final asset)          # only where a staging area exists
publish()
verify(public vs expected)
```

- **`dart`** (ecosystem): parses pubspec, workspace, lockfile, and any
  `pubspec_overrides.yaml`; validates version↔tag agreement, changelog
  entry, and a publish dry-run; derives ordering and prerequisites. Two
  rules learned from real repositories: lockfile enforcement applies to
  **compiled-binary units only**, because Dart's own guidance tells library
  authors not to commit one and requiring it would refuse the most common
  package shape; and a **consumer resolve** — resolution with development
  overrides disabled — is mandatory before publishing, because pub excludes
  `pubspec_overrides.yaml` from the archive but honours it locally, so a
  dry-run can pass while the published package is unresolvable for everyone
  else.
- **`dart-cli`** (build): `dart compile exe` per platform, then smoke-runs
  what it produced. Capability is resolved per platform and reported:
  **native** for the host; **cross-compiled** for Linux targets, which
  `dart compile exe` supports and which requires the project to have no
  native assets, since the SDK ships no C cross-toolchain; **emulated
  execution** through a container runtime for smoke-testing a
  cross-compiled binary; **blocked** otherwise, naming the missing
  capability. An x64 macOS binary can be neither cross-compiled nor built
  natively on Apple Silicon. Capabilities are discovered, never declared:
  which platforms to ship is a product decision, where a binary can be
  produced is a fact about the machine.
- **`macos-sign`** (transform): ephemeral keychain with
  `set-keychain-settings -lut`, `import -T /usr/bin/codesign`, and
  `set-key-partition-list` (without which codesign hangs on a UI prompt),
  `--keychain` passed explicitly; verifies its output against the published
  release's designated requirement, not against its own input.
- **`macos-notarize`** (transform): `notarytool submit --wait`; the notary
  log ships as a release asset. Resume resubmits by default — identical
  bytes are accepted and cost minutes. History-based adoption is legal only
  when a per-submission log reports a digest equal to the exact bytes rk
  holds; name and recency are not evidence. `codesign --check-notarization`
  remains the binding verification.
- **`archive` + `checksums`** (transforms): deterministic tar.gz per
  platform — fixed entry order, zeroed mtimes, normalized modes, no gzip
  timestamp — containing the executable, LICENSE, and README, with frozen
  public asset names; plus `SHA256SUMS`. Determinism is a requirement, not
  polish: without byte-reproducibility, "is this the artifact I would have
  made" is undecidable and reuse degenerates into acceptability.
- **`pub-dev`** (destination): inspection via the pub.dev API; publish via
  `dart pub publish` against the operator's session; post-publish
  re-download and logical content compare, since pub rewraps archives —
  name, type, mode, size, content, ignoring archive timestamps. A package
  that has never existed yields `first-publish`, which prints the ordered
  interactive bootstrap commands and refuses to act, because pub.dev
  accepts a first version only from an interactive publish.
- **`github-release`** (destination): adoption, staging, repair, flip, and
  verification as above.
- **`homebrew-tap`** (destination): formula from a closed template plus
  staged digests plus derived identity; compare-and-swap update; public
  install check, run without any credential present, since a formula is
  executable Ruby.

A proposed destination adapter must document verdict semantics, terminal
act atomicity, post-crash inspectability (a platform that cannot be
classified after a partial submit fails the proposal), whether a
pre-publication area exists, and its native auth flow.

## Agents

rk is used by people at terminals and by agents acting on their behalf, and
both use **the same CLI**. There is no second surface: an agent-specific
server would shell out to this engine anyway, so it would add drift between
two interfaces, a runtime dependency the signing path must not have, and a
long-running process holding publish authority. If a particular agent host
needs a protocol adapter later, it belongs in a separate package wrapping
the CLI, never in rk core.

What makes the CLI sufficient is already required for other reasons:

- **`--json` on every command**, stable, keyed on step id, surviving a
  non-zero exit and carrying `safe_to_rerun`. An agent decides whether to
  retry from data rather than by parsing prose.
- **Read-only verbs are always safe.** `status` and `verify` change
  nothing, so an agent may run them freely, including across a fleet by
  invoking rk once per repository.
- **Idempotence.** Re-running is the resume, so an agent that loses track
  of a run recovers by running the same command again.
- **Next actions are data.** `status --json` names the command that would
  advance the release, so an agent can chain without inferring intent from
  formatting.

**Authorization is unchanged for agents.** An agent is a non-interactive
caller, so the confirmation rule applies as written: without a human at the
terminal, a release proceeds only when an authorizing tag exists and its
signature verifies. That is the same path CI will take, and it is the point
of having a durable authorization carrier at all — the human signs, the
machine executes. There is no agent exemption and no `--yes`: an agent
running unattended is precisely the case that must fail closed. In
practice the division is: the agent reports what is ready and why, the
human authorizes by tagging, and the agent executes and verifies.

## CI readiness

CI is deferred from the MVP, not designed out. Releasing locally first is
the right order — it needs no provisioning, no stored secrets, and no
settings changes, so the engine can be proven end to end against a real
release before any of that exists. But CI is where this fleet ends up, and
the MVP's job is to make it a bolt-on rather than a rewrite.

**What CI adds when it arrives.** OIDC trusted publishing, so no registry
token is stored anywhere; GitHub Actions environments as credential
contexts, one credential per context; a reusable release workflow plus a
thin caller workflow rk emits and byte-diffs; provider-side provisioning
under a separate verb; deployment tag policies and tag rulesets; build
attestations binding artifacts to a workflow and commit; and a probe that
stops a local run from racing a CI run on the same tag. It also promotes
authorization: locally the operator's presence authorizes a release, while
in CI a signed tag becomes mandatory — both because the human is absent and
because trusted publishing binds to a tag pattern.

**The seams the MVP must preserve.** These cost nothing now and are binding
on the implementation:

1. **No state between steps.** Every step must be executable in isolation
   from the checklist, its step id, the workspace, and destination reality
   alone. In CI a step is a separate process on a separate machine; if the
   MVP passes state in memory from one step to the next, CI cannot split
   them. This follows from "reality is the database" and must be honoured
   literally rather than incidentally.
2. **One credential chokepoint.** Every credential is obtained through a
   single resolution function keyed by need, never looked up inline by an
   adapter. The MVP ships one implementation — native stores — and CI adds
   a second without touching an adapter.
3. **The workspace is an interface, not a path.** Artifacts are stored and
   fetched by name through a narrow accessor. Locally it is a directory; in
   CI it is the run's artifact store.
4. **Assurance is a recorded fact, not a branch.** How a release was
   produced — which credentials, which host, whether an attestation
   exists — is data attached to the release and reported, never a
   conditional threaded through adapter logic.
5. **Authorization is a signal with carriers.** The MVP implements operator
   presence and verifies a signed tag when one exists. Adding "a tag is
   required here" must be a policy check at one place, not a new code path.
6. **Optional evidence degrades honestly.** `verify` already distinguishes
   expected-absent from missing, so attestations attach later as one more
   evidence type rather than a new concept.

**What CI must not require.** Reshaping the checklist, changing a verdict,
altering an adapter's inspect/act/verify contract, or introducing state
that outlives a run. If adding CI needs any of those, the MVP got a seam
wrong and the seam is the thing to fix.

## Deferred by principle 8

On RFC 0001's priced ladder: the Release Registry in every tier, the
protected policy document and policy key, claim/envelope identities and
DSSE receipts, capability fencing, the multi-party tag ceremony, plan
admission by a separate control plane, toolchain content-addressed
materialization, the credential mapping file, global identity with
overrides, and cross-run workspace warming. Any returns only by naming the
concrete failure it prevents.

## Keybay demo plan

1. **Engine + `dart` + `pub-dev`.** Release keybay core from the operator's
   machine: `rk init`, `rk status`, `rk release core`, `rk verify`. First
   production use of every verb, with no binaries, signing, draft, or tap.
2. **Binary chain + `github-release` + `homebrew-tap`.** Release keybay
   cli: three platforms — macos-arm64 native, both Linux targets
   cross-compiled and smoke-tested in containers — signed, notarized,
   archived, staged, published, formula updated, then installed and
   smoke-tested from the public tap.
3. **Fleury**, after its five packages are bootstrapped by hand, exercising
   multi-project units and derived ordering.

Keybay compatibility: public asset names are frozen; archives contain the
executable, LICENSE, and README; Apple team `5AHFA9FUZG` and code
identifier `io.github.danreynolds.keybay.cli` are enforced against the
published release's designated requirement; the CLI tag namespace is
unchanged and core migrates to the derived `keybay-v{version}`;
`macos-x64` is dropped, taking the release to six assets.

## Module layout

```text
release-kit/
  bin/rk.dart
  lib/src/engine/        # toml, pubspec, checklist, verdicts, output, diagnosis
  lib/src/ecosystems/dart/
  lib/src/builds/dart_cli/
  lib/src/transforms/    # macos_sign, macos_notarize, archive, checksums
  lib/src/destinations/  # pub_dev, github_release, homebrew_tap
  doc/rfcs/
  test/                  # black-box fixtures: keybay-, fleury-, dune-shaped
```

rk has **no runtime dependencies** — `dart:*` and its own sources only,
enforced by a test over the import graph and an empty `dependencies:`
block. This keeps third-party code away from the signing path and makes
rk's own bootstrap trivial.

## What rk is not

Not a version bumper, changelog generator, CI system, test runner, task
runner, or plugin host. No hooks, no templates, no `--force`, no recursive
discovery, no override of native vetoes.

## Open items

1. Port `tool/compare_pub_archives.py` into the `pub-dev` adapter.
2. Verify container smoke tests for cross-compiled Linux binaries, and that
   cross-compiled and natively built binaries carry the same glibc floor,
   since the platform profile fixes that floor as a compatibility contract.
3. Publish a JSON Schema for `release.toml`.
4. `rk doctor` — fleet-consistency checker; build only when drift is real.
5. Final name.

## Relationship to RFC 0001

RFC 0001 remains authoritative for the threat model and residual-risk
analysis, the peer survey with pinned evidence, the Dune admission
criteria, and the assurance ladder. It is no longer the build plan.

## Review history

Revision 3 narrows scope to local releases and consolidates eight
adversarial reviews across two rounds: security, reliability, developer
experience, and platform realism; then CLI design, a first-run newcomer, an
operator debugging under pressure, and other project shapes. Findings
adopted include identity-not-acceptability, draft adoption by enumeration
with narrow staging repair and pre-flip re-verification, deletion of
cross-run workspace warming, monotonicity that excludes the authorizing
tag, per-project versions within a unit, prerequisite derivation from the
configured project rather than pin form, conditional lockfile enforcement,
the consumer-resolve check, external verification of the code identifier,
the halt sentence, conflict evidence, collapse and terseness rules, the
`unknown` verdict, tag-anchored verification, and the diagnosis bundle. No
finding required restoring a mechanism from RFC 0001's ladder.
