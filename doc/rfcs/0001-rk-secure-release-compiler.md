# RFC 0001: RK, an austere secure release compiler

- Status: Superseded as build authority by RFC 0002 (rk core, 2026-07-28);
  retained as threat catalog and assurance ladder
- Production implementation: Blocked
- Schema 1: Not frozen
- Date: 2026-07-26
- Last revised: 2026-07-27
- Revision: 10
- Working name: RK
- Initial scope: Dart packages and Dart command-line applications
- Incubation repository: `~/Coding/release-kit` (this RFC is mirrored there
  as reference)

## Summary

RK is a provider-neutral release-intent compiler backed by a protected logical
Release Registry.

A repository declares a narrow release intent in `release.toml`. RK combines
that untrusted intent, immutable native facts, and an effective projection of
separately protected operator policy into a canonical semantic plan. The
Release Registry admits one semantic plan per release coordinate, selects one
accepted identity per artifact node, reserves each immutable public destination
for one selected identity, records operation attempts, and preserves revocation
and anti-rollback facts. Isolated authority principals consume only admitted
plans and selected inputs. Independent observers verify public state.

The resulting system produces:

- a deterministic, typed `plan.json`;
- immutable artifact nodes;
- linearizable source-coordinate, immutable-destination, and output-selection
  commitments;
- isolated authority operations; and
- authenticated claims and envelopes, with public reconciliation for claims
  about public destinations.

The Release Registry is a logical consistency and authorization contract, not
a requirement to build a new hosted service. A local database, an existing
trusted controller, or provider infrastructure may implement it only if the
same compare-and-swap, audit, capability, and anti-rollback contracts hold.

The author-facing configuration says which exact projects may be released,
which public channels should receive them, and which binary platforms are
supported. It does not describe jobs, runners, commands, secrets, credentials,
signing identities, artifact IDs, or publication order.

If Phase 0 selects RK, the first production implementation should support only:

- Dart package publication to pub.dev;
- Dart CLI archives for Linux and macOS;
- macOS Developer ID signing and notarization;
- GitHub Releases as an immutable binary host;
- Homebrew formulas that reference accepted GitHub assets; and
- hashes, provenance, public verification, and resumable receipts.

The architecture and authoring principles are intended to extend to closed
Cargo, npm, PyPI, and OCI adapters later. Schema 1 is Dart-only. A later
ecosystem may require a new schema version or a concrete selector; v1 must not
pretend otherwise before each adapter has passed its own threat review.

This revision authorizes only Phase 0 comparison and contract prototyping if
accepted. It does not authorize production credentials, production migration,
or schema freeze. The real build decision remains conditional on the
build-versus-adopt gate.

## Document scope

This single document contains both proposed normative architecture and
informative evidence:

- the threat model, author boundary, semantic-plan contract, Release Registry,
  authority separation, and Phase 0 decision rules are proposed normative
  material for the RK candidate;
- the Keybay, Fleury, and Dune sections are informative case studies that test
  the proposed rules; and
- the peer matrix and repository snapshots are refreshable evidence, not
  permanent architectural truth.

The threat outcomes and build-versus-adopt stopping rule are common comparison
criteria. The semantic-plan, claim, and Release Registry protocols are RK's
candidate solution, not infrastructure that adopted tools must implement.
Alternatives may satisfy the same black-box outcomes through native provider
state, their own ledgers, or a central controller; every mechanism and its cost
remain visible in the scorecard.

Later revisions may reorganize sections, but Phase 0 does not require creating
additional RFCs or committing to an RK product. If genericity does not reduce
the complete trusted system, the typed kernel may remain internal to a
Keybay-specific controller.

## Background

Keybay now has a secure release process, but the implementation is bespoke:

- `.github/workflows/publish.yml` publishes the core Dart package;
- `.github/workflows/release_cli.yml` is 806 lines and 13 release jobs;
- `tool/release.dart` prepares the shared version and authorizes one of the
  paired core/CLI tags per command;
- more than a dozen scripts validate packages, binaries, archives, signing,
  notarization, Homebrew, and public-channel behavior; and
- `doc/cli-release.md` carries a detailed operator runbook.

That machinery contains useful security decisions:

- the release tag is a human authorization boundary;
- source, build, signing, notarization, and publishing authority are separated;
- credentialed jobs do not execute candidate binaries;
- macOS signing identity is frozen because it is part of Keychain continuity;
- a candidate is accepted before it is promoted;
- immutable public coordinates are classified as absent, exact, or
  conflicting, while mutable channel pointers use an authorized
  compare-and-swap transition;
- published bytes are redownloaded and independently verified; and
- an incomplete multi-channel release is reported honestly rather than
  repaired by mutating an existing version.

Those decisions are valuable beyond Keybay. Fleury has several related Dart
packages plus command-line products. Dune CLI will eventually need a signed
multi-file native bundle. Future tools may need Cargo, npm, PyPI, or OCI
publication.

Copying Keybay's workflow would also copy Keybay-specific policy, GitHub YAML,
and hundreds of lines of orchestration into every repository. That is hard to
review, hard to keep consistent, and likely to drift.

## Problem statement

In a survey of current official documentation completed on 2026-07-26, no
surveyed no-cost or open-source offering met all of these requirements through
closed built-in contracts. An arbitrary hook or custom command does not count
as secure support:

1. It must publish both native ecosystem packages and cross-platform binaries.
2. It must support macOS signing and notarization without giving the signer
   source-build or publication authority.
3. It must promote accepted artifact nodes rather than rebuilding downstream.
4. It must work locally, in GitHub Actions, or in another CI system through the
   same engine.
5. It must use a small, non-executable repository configuration.
6. It must fail closed on unknown projects, destinations, identities, fields,
   and ambiguous inference.
7. It must preserve enough evidence to resume safely after partial
   publication.
8. It must not become a general workflow language or plugin host.

The closest peers each solve only part of the problem:

- [dist/cargo-dist](https://axodotdev.github.io/cargo-dist/book/) demonstrates
  native-manifest inference, plan/build/host/publish phases, and generated CI,
  but its configuration and custom-job surface are much broader than RK's
  intended security boundary.
- [GoReleaser](https://goreleaser.com/customization/general/artifacts/)
  demonstrates a useful artifact ledger and strong defaults, but executable
  hooks and custom publishers broaden privileged execution, while pervasive
  templates broaden data-dependent behavior.
- [JReleaser](https://jreleaser.org/guide/latest/reference/distributions.html)
  explicitly separates distributions, artifacts, and packagers, but exposes a
  large typed configuration and inheritance model.
- [Conveyor](https://conveyor.hydraulic.dev/22.1/) demonstrates unusually broad
  cross-platform packaging and cross-OS signing/notarization, but its
  implementation is proprietary, its documented in-CI release path can
  co-locate signing keys and notarization/publishing credentials, and its
  configuration can execute external commands and custom
  signing/notarization scripts.
- [Fastforge](https://fastforge.dev/) demonstrates approachable Flutter
  packaging and publishing across desktop and mobile formats, but package hooks
  execute repository shell commands and its documented macOS packaging does
  not provide RK's isolated notarization and accepted-artifact promotion lane.
- [Melos](https://melos.invertase.dev/commands/publish) has good Dart workspace
  and dry-run-first publishing ergonomics, but it does not provide a secure
  cross-platform binary, signing, notarization, and exact-promotion kernel.
- [Release Please](https://github.com/googleapis/release-please),
  [Changesets](https://github.com/changesets/changesets),
  [release-plz](https://release-plz.dev/docs/usage/release), and
  [semantic-release](https://semantic-release.gitbook.io/semantic-release/usage/plugins)
  span release preparation and ecosystem publication to different degrees.
  For example, release-plz publishes Cargo crates, Changesets can publish npm
  packages, and semantic-release plugins publish to npm and GitHub. None of the
  surveyed configurations supplies RK's closed cross-platform artifact,
  isolated authority, and resumable-promotion contract.

RK should copy the peers' good internal ideas—native inference, typed plans,
artifact ledgers, and outcome-oriented commands—without copying their
extension surfaces into the trusted release path.

## Threat model

Repository intent, source bytes, native manifests, candidate artifacts,
provider responses, caches, and transport storage are untrusted until a fixed
trusted implementation validates the specific fact it consumes. Protected
policy, registry commitments, and authority credentials are trusted only
within their explicit principal and capability boundaries.

| Threat | Required invariant | Phase 0 qualification evidence | Residual risk |
|---|---|---|---|
| Malicious repository revision | Source is bounded data, never authority; fixed trusted parsers execute no repository command | traversal, ambiguity, parser-limit, Git-config, hook, submodule, and command-injection fixtures | A vulnerability in a privileged parser remains a trusted-code compromise |
| Compromised candidate build or test | Workloads have no release authority; outputs are rehashed and selected outside their reach | sandbox configuration evidence plus negative secret, network, descendant-persistence, output-swap, and forged-claim probes | Negative probes do not prove absence of sandbox vulnerabilities; kernel, hypervisor, or trusted control-plane compromise is not contained by job separation alone |
| Malicious artifact targeting a privileged parser | Every consumer verifies identity first and uses bounded, traversal-safe, duplicate-aware parsing | archive bombs, duplicate paths, symlink escapes, malformed Mach-O, formula-token, and media-type fixtures | Bugs in the closed privileged parser remain in the trusted computing base |
| Stale, replayed, or re-signed valid evidence | Semantic claim IDs, issuer policy, admission status, and attempt identity are reverified; envelope identity is audit metadata | replay across repository, coordinate, plan, node, policy, and issuer test vectors | Compromise of an accepted issuer can create valid-looking claims within that issuer's capability |
| Mutable or compromised handoff storage | Selected inputs are retrieved by digest and length from immutable/content-addressed storage and reverified | blob replacement, truncation, cache poisoning, metadata mismatch, and replica-recovery tests | Loss of every exact replica can permanently strand a byte-exact release |
| Concurrent release, destination, or output attempts | External source tags, immutable destinations, and accepted outputs each have one linearizable commitment plus durable tombstones | simultaneous source-coordinate reservation, immutable-destination reservation, output selection, tap update, and retry tests | Compromise of the candidate's authoritative state root can violate uniqueness |
| Partial or ambiguous provider success | Durable intent precedes mutation; exact provider-specific reconciliation classifies absent, exact, conflict, or incident | lost response, timeout, duplicate draft/submission, provider-ID loss, and rerun fault injection | A provider without sufficient correlation may force a permanent partial release |
| One compromised authority credential | Principals receive one capability class; any credential spanning two mutually exclusive authority classes is disqualifying | credential-use matrix, permission-negative tests, impersonation, residual-provider-permission, and confused-deputy probes | Excess permission within one authority class may remain only when bounded, mitigated, and explicitly reported |
| Moved, deleted, or re-signed Git tag | Coordinate tombstones bind the canonical name/version to one tag object and semantic plan | deletion, movement, object substitution, and recreation tests | Full compromise of the repository and registry roots is not prevented |
| Policy rollback, revocation, or in-flight race | Monotonic policy/admission facts and fenced single-use operation capabilities block new work; landed remote effects are reconciled | stale policy, restored status, capability replay, expiry, and revocation-during-request tests | An external request started before revocation may still land and must be reported as fact |
| Authoritative-state rollback or stale restore | Authenticated state/checkpoints and disaster recovery never forget a source coordinate, destination reservation, selection, policy/admission fact, revocation, attempt, or tombstone | restore-from-old-backup, split-brain, missing-index, and checkpoint-verification drills | Full simultaneous compromise of bootstrap trust and the candidate's authoritative state can violate safety |
| Dependency or toolchain substitution | Credential-free materialization verifies lock/content identities into CAS before a network-disabled build | hostile mirror, user-config injection, lock mismatch, SDK/image substitution, and offline rebuild tests | An authorized but malicious upstream artifact remains an ecosystem trust risk |

Every candidate must name its bootstrap and authoritative-state roots of trust.
For RK, those include the bootstrap trust root and authorization quorum for the
Release Registry. The comparison requires rollback detection, scoped writers,
recovery drills, and independently auditable state evidence; it does not claim
to preserve safety after the relevant roots' complete, simultaneous compromise.
A public provider compromise may also mutate its own state. Independent
verification must expose the mismatch, but cannot undo an already consumed
external release.

This fleet currently has one human operator. That operator is simultaneously
repository administrator, organization owner, policy administrator, registry
root, and signer custodian, and every provider-side protection—environments,
rulesets, tag protection, secret scoping—remains mutable by that same root.
Separation claims in this document are therefore defined relative to the named
roots: they defend against compromised workloads, malicious dependencies,
malicious revisions, and stolen scoped credentials, not against compromise of
the operating root itself. Every separation predicate in this RFC and in
Phase 0 scoring must be decidable relative to those named roots; a predicate
that no candidate can satisfy against its own operating root is a
specification error, not a finding.

## Build-versus-adopt decision gate

A small `release.toml` does not prove that the complete trusted system is
small. Authorization freshness, unique-coordinate/output state, immutable
handoff, provider recovery, and evidence verification all have real operational
cost. RK proposes policy admission and a Release Registry for those outcomes;
alternatives may use other mechanisms, whose costs are counted. This RFC
authorizes a comparison prototype, not an assumption that RK must be built.

An adopted release tool or orchestration service must support the current
open-source projects without a paid tier or paid-only critical feature. This
does not pretend unavoidable destination fees—such as Apple's developer
program—can be removed. A proprietary tool that is free for open source is not
excluded automatically, but unavailable source, audit limits, vendor
availability, and exit work count explicitly. It may run only as an untrusted,
credential-free producer unless its privileged behavior can be independently
reviewed and constrained.

Phase 0 first performs a documented, uniform screen of every surveyed candidate
and complete composition against the same product constraint and hard
invariants. It classifies each as:

1. eligible to win as a complete composition;
2. a bounded component/DX benchmark that cannot win by itself; or
3. eliminated by a named, evidenced failure.

A tool with a hard gap advances as a potential winner only when a named closed
component plausibly supplies the missing outcome and all surrounding glue is
counted. A bounded benchmark advances only for an explicit question and budget;
it does not receive favorable scoring merely for being prototyped.

At minimum, the screen considers these compositions. A non-production prototype
is required only while the composition remains eligible to win or is approved
as an explicit bounded benchmark:

1. a centrally maintained, pinned controller using native destination tools,
   owning protected environments, and treating the candidate repository only
   as source input;
2. the native destination tools plus a credential-free `dist` v0.32.0 spike
   for planning, build, archive, and formula work, with executable extension
   points disabled and all remaining glue counted;
3. a constrained Conveyor 22.1 packaging spike;
4. the proposed RK planner/contracts with only the GitHub production-provider
   shape prototyped.

The refreshed screen must apply the same advancement rule to JReleaser,
GoReleaser OSS, and Fastforge. Any non-dominated complete composition advances;
any bounded component benchmark states why it is worth running and cannot be
mistaken for a candidate that satisfies the full gate.

Candidates share black-box source fixtures, expected semantic outcomes, fault
cases, and evidence predicates. They do not share an RK semantic-plan
implementation before the decision; doing so would prepay RK's architecture
and bias the comparison.

`dist` is the closest free general releaser worth spiking: it has generic
projects, target matrices, GitHub Releases/attestations, archives, and
Homebrew. Its generic build command is experimental executable configuration,
GitHub is its only CI backend, and it has no pub.dev or documented notarization
lane. If it cannot remain a no-credential producer while closed native lanes
handle Apple, publication, and Homebrew compare-and-swap, it fails this gate.

[Conveyor](https://conveyor.hydraulic.dev/22.1/) is a serious
packaging-first candidate: it supports command-line and Flutter applications,
desktop packages, GitHub Releases, and cross-OS signing/notarization. Its
open-source use is free with attribution, but the normal binary uses a
proprietary license and source access is a paid offering; its configuration
also includes executable extension points. It therefore must prove useful as a
constrained credential-free producer rather than be dismissed or trusted by
default.

[Fastforge 0.6.10](https://pub.dev/packages/fastforge/versions/0.6.10)
is a free, open-source Flutter packaging/publishing candidate with macOS and
Linux output formats and GitHub distribution. Its repository-controlled hooks,
platform-local packaging requirements, and co-location of packaging and
publishing inputs appear incompatible with RK's privileged boundary, and its
Flutter focus does not cover pub.dev plus Dart CLI releases. The spike must
not be mandatory on that basis. Run it only as a time-boxed Flutter-DX or
packaging-component benchmark if the uniform screen identifies a material
question not answered by a stronger candidate.

GoReleaser's prebuilt import and native Apple lane are paid features, so those
features violate the no-paid-dependency constraint. JReleaser and GoReleaser
OSS receive the same composition and domination screen as every other tool;
neither is held back or advanced by a special rule.

A GitHub `workflow_call` is code reuse, not by itself an authorization
boundary: the caller controls its own workflow and passes permissions/secrets.
The central alternative must either initiate the trusted run itself or prove
protected caller code plus identity binding such as `job_workflow_ref`.

The scorecard inventories the whole system, not merely the author file:

- all repository-owned and centrally maintained trusted code/configuration,
  measured separately and in total;
- every privileged third-party binary, action, and service, with its pinned
  version or digest and the authority it receives;
- every stateful backend, schema, backup, availability, and recovery duty;
- happy-path operator actions plus each human decision needed for setup,
  upgrade, revocation, crash recovery, and partial release;
- every privileged identity, credential, and co-located authority;
- provider-specific glue;
- auditability/vendor/exit exposure, measured as closed-source components,
  required vendor/license/availability services, and the trusted code plus
  operator steps required to replace them;
- one-time migration cost, annual central maintenance, and marginal
  per-repository maintenance at one, three, and ten repositories, expressed as
  ranges with confidence rather than false precision;
- security-critical trusted code/configuration separately from ordinary
  integration code/configuration;
- intended authority, provider-enforced authority, residual ambient authority,
  and mitigating controls for every privileged principal;
- local dry-run/build parity; and
- security invariants satisfied natively versus by new bespoke code.

Centralizing code counts as moving complexity until the total-system inventory
shows that it was removed. Generated code and provider configuration count
when they are trusted or maintained.

Before any comparative ranking, every candidate must pass:

- zero authority-bearing environments that execute candidate-controlled code or
  repository-defined commands; fixed trusted implementations may parse bounded
  canonical source bytes;
- principal/capability separation for every forbidden authority combination;
  separate jobs without distinct credentials and provider-enforced capabilities
  do not count;
- zero candidate-controlled executable hooks in privileged paths;
- zero rebuilds after accepted-output selection;
- digest and byte-length verification at every handoff; and
- fail-closed tests for exact/conflicting destinations, evidence loss, upload
  interruption, notary timeout, draft collision, tap concurrency, and rerun.

The complete pass suite also covers stable evidence identity across re-signing,
routine implementation upgrades during a partial release, explicit revocation
and fencing, non-rollback state/disaster recovery, provider ambient privilege,
exact dependency/toolchain materialization, and the candidate's own
bootstrap/update authorization. These are observable outcomes, not a
requirement that an adopted candidate implement RK claims or a Release Registry.
The Phase 0 scorecard must give every R1–R8 row an observable predicate,
required evidence artifact, and disqualifying result. `P` advances a candidate
to investigation; only evidenced satisfaction of the complete composition can
pass the final gate.

Mocks and interface shapes may price a candidate, but they cannot pass these
provider invariants. After credential-free prototypes narrow the field, every
candidate still eligible to win must use separately scoped canary identities
and non-consumer destinations to exercise real provider state and deterministic
fault injection. A failed or unavailable qualification removes that candidate
and reopens the comparison; it is never converted into an exception.

Here, an execution provider is a CI/control-plane host; GitHub Releases,
pub.dev, Apple, and Homebrew are destination/authority adapters. An RK v1 may
ship maintained production glue for only one hosted execution provider,
initially GitHub Actions. To pass portability rather than merely claim it, the
same engine and formats must also complete planning, materialization, build,
acceptance, and provider-interface conformance in a second independent
execution environment with no product credential. That second environment
should be a plain self-hosted runner—an ordinary Linux or macOS box driving
the engine CLI—so the proof shows the engine needs nothing from any hosted CI
brand. That proves portability of the engine, not a promise to maintain two
production CI integrations.

The stopping rule is deliberately biased toward adoption:

1. Discard candidates that fail a hard invariant, the no-paid-dependency
   constraint, real-provider qualification, or complete coverage of
   requirements 1–8 for the Keybay slice plus at least one Fleury shape,
   recording the exact failure and evidence. A partial packaging tool remains
   only as a component of a fully inventoried composition; it cannot win by
   itself.
2. Remove candidates dominated by another candidate across total maintained
   trusted code/configuration, stateful services, operator actions and recovery
   decisions, privileged third-party dependencies, and
   auditability/vendor/exit exposure.
3. If any non-RK candidate remains, RK may proceed on simplicity grounds only
   if it is no worse than every remaining candidate in all five dimensions and
   materially better in at least one. Estimates with overlapping uncertainty
   ranges are equal/incomparable, not a strict win. A material win means at
   least one fewer privileged service/dependency, one fewer required human
   recovery decision in a frozen fault case, or a non-overlapping reduction in
   total maintained trusted code/configuration. A trade-off is not silently
   converted into a favorable weighted score.
4. RK may otherwise proceed only to satisfy a named hard invariant that no
   existing candidate can meet, and the prototype must demonstrate that
   invariant without weakening another one.

In either RK path, it must work for Keybay and at least one Fleury shape, reduce
per-repository trusted release code/configuration by at least 50% from
Keybay's measured baseline, and not increase the number of third-party
components receiving credentials. If it misses any condition and a compliant
existing composition remains, stop RK and choose among the
Pareto-undominated existing options through explicit project governance; an
incomparable trade-off is not a reason to build a new tool. If no candidate
remains, select nothing: production migration stays blocked, and any existing
process continues only under its own explicit risk decision, not an endorsement
from this gate. Revisit the constraint or design with new evidence. Sunk
implementation effort is not a reason to pass the gate.

If a typed semantic-plan/kernel library helps the Keybay controller but
genericity does not improve this whole-system result, keep it internal to that
controller. Reuse alone does not justify an RK product.

## Goals

### Authoring

- Keep `release.toml` small enough to review in one screen for a typical
  project.
- Require one explicit row for every project authorized to release.
- Infer native facts from native manifests instead of duplicating package
  name, version, dependency graph, or executable declarations.
- Make common cases work without artifact IDs, dependency references,
  `kind` declarations, or release-stage configuration.
- Produce useful fail-closed errors that identify the project, native fact,
  requested destination, and correction.

### Security

- Treat repository configuration and source as untrusted input to a privileged
  deputy.
- Intersect repository intent with separately protected operator policy.
- Give each authenticated principal one narrowly defined capability class;
  authority classes are mutually exclusive except for an explicitly specified
  atomic bundle, and any broader ambient provider privilege is recorded.
- Freeze one accepted output identity per canonical artifact node and never
  rebuild that accepted identity downstream.
- Authenticate every claim used to authorize promotion or resume, separately
  from the envelope carrying its signatures.
- Preserve coordinate, selection, revocation, and tombstone facts across
  disaster recovery without rollback.
- Make publication idempotent through absent/exact/conflict inspection.
- Reverify public state before dependent publication proceeds.
- Keep local and CI execution logically equivalent while reporting their
  different assurance levels.

### Portability

- Keep the release engine independent of GitHub Actions.
- Generate or invoke thin provider glue rather than embedding provider concepts
  in `release.toml`.
- Use portable semantic-plan, claim, envelope, and registry protocols.
- Permit a local dry run and local artifact build without pretending that a
  local machine has the same builder identity as isolated CI.

## Non-goals

RK v1 is not:

- a semantic-version bump or changelog generator;
- a replacement for all product CI and test selection;
- a generic task runner;
- a shell-hook or plugin system;
- a CI runner or workflow language;
- a credential manager;
- an atomic cross-registry transaction;
- a rollback system for immutable package versions;
- a recursive "publish every changed package" tool;
- a way to override native `publish_to: none`, `private`, or equivalent vetoes;
  or
- a promise of immediate Cargo, npm, PyPI, OCI, desktop-app, mobile-store, or
  Windows support.

Version preparation may remain in project-native tools such as Keybay's
`tool/release.dart`. Product-specific tests remain normal CI. RK owns the
release boundary: resolving a reviewed source snapshot, producing and accepting
release artifacts, applying isolated authorities, publishing, reconciling, and
recording evidence.

## Design principles

### One project declaration, one meaning

An author declares:

> Release this exact project to these channels, with binaries for these
> platforms.

The author does not manually partition pub.dev, GitHub Releases, and Homebrew
into separate "artifact families." The planner derives that graph.

### Native manifests provide facts, not authority

A native manifest owns facts such as:

- package name and version;
- workspace relationships;
- dependency constraints;
- executable entry points;
- registry restrictions; and
- package contents according to the native tool.

Being publishable does not authorize publication. Only an explicit project row
requests authority, and protected operator policy must independently allow the
resolved identity and destination.

### Configuration is data, never executable policy

Repository configuration may not contain:

- commands or shell fragments;
- hooks;
- environment interpolation;
- templates other than the single `{version}` tag token;
- secret names;
- credential references;
- URLs for privileged destinations;
- workflow or runner names;
- remote includes;
- downloaded adapters;
- globs or regex package selection; or
- inheritance and override chains.

Unknown fields are errors rather than ignored forward compatibility.

### The generated plan carries the complexity

The author configuration remains small. `plan.json` is allowed to be explicit
and verbose. It contains typed artifact nodes, source/input hashes, output
contracts, transformations, required authority classes, dependencies, and
platform expansion. Produced output identities belong to authenticated claims
and Release Registry selections, not a mutable plan.

JReleaser-style distribution types and GoReleaser-style artifact IDs may be
useful inside the generated plan. They are not automatically useful in the
human schema.

### Semantic identity is not implementation identity

The canonical semantic plan describes what must happen and what must be true.
It includes adapter and platform contract versions, but not the digest of the
particular RK binary, adapter implementation, workflow, or signature envelope
that compiled or executed it.

Admission and operation claims record those actual implementation identities
and protected policy authorizes them. A patched implementation may recompute
or continue the same semantic plan only when current policy permits it and the
canonical plan is byte-identical. Any changed graph, destination, contract, or
product requirement produces a different plan ID and conflicts at the existing
release coordinate.

### One logical registry, capability-separated writers

Coordinate admission, output selection, operation attempts, policy/admission
status, revocations, and tombstones share one logical Release Registry
protocol. That reduces databases and recovery mechanisms without granting one
process every authority. Each mutation remains scoped to a distinct
authenticated principal and provider-enforced capability.

### Facts are authoritative; status is a projection

Plans, claims, registry commitments, and independently observed provider facts
are authoritative. A friendly state such as “partial” or “verified” is a
rebuildable projection for operators, not a universal mutable enum that can
contradict the evidence.

## Terminology

### Release unit

A named set of explicitly listed projects that share one tag pattern and one
logical release version. Examples are Keybay `core`, Keybay `cli`, and a
lockstep Fleury framework release.

Independently versioned projects belong to different release units.

### Project

One exact Git-root-relative directory containing one unambiguous supported native
manifest. A project row is an authorization request; native workspace
membership is not.

Manifest discovery is limited to the authorized project directory. After
selecting that manifest, a native adapter may inspect ancestor workspace files,
lockfiles, and local dependency source within the same immutable source root.
Those files become explicit hashed build materials; they do not gain
publication authority.

### Channel

A public destination requested by the repository, such as `pub.dev`,
`github-release`, or `homebrew`. A channel name selects a closed adapter
contract, not an arbitrary URL or command.

### Artifact node

One canonical output or transformation in the generated plan. Separate
platform builds, signed binaries, archives, formulas, and native packages are
different nodes.

### Operator policy

Protected authorization data that binds repository intent to exact identities,
destinations, signers, builders, and credentials. Repository commits cannot
modify it.

### Semantic plan

The canonical, implementation-independent graph of source identities, author
intent, effective policy projection, contracts, destinations, artifact nodes,
output contracts, dependencies, and required authority classes. Its
domain-separated SHA-256 digest is the `plan_id`.

### Claim

A canonical unsigned statement asserting one typed fact about a plan,
admission, operation, selection, provider result, or public observation. Its
domain-separated digest is the stable `claim_id`.

### Envelope

One authenticated carrier for a claim, such as DSSE/in-toto, including its
signatures, certificates, and transparency evidence. Its digest is the
`envelope_id`. Re-signing may change the envelope ID without changing the claim
ID.

### Receipt

The portable bundle of a claim and one or more acceptable envelopes plus
verification material. Downstream authorization binds the claim ID and issuer
policy, not merely the mutable serialization of one envelope.

### Release Registry

The logical linearizable authority for unique source-coordinate admissions,
immutable public-destination reservations, accepted output selections,
operation attempts/dispositions, policy and admission status, revocations,
tombstones, and authenticated checkpoints. Artifact bytes live in
content-addressed storage outside this state authority.

## Proposed author configuration

The examples below use the candidate `schema = 1` shape so it can be tested
concretely. Phase 0 may change or reject that shape; this RFC does not freeze it.

### Keybay

```toml
schema = 1

[release.core]

[[release.core.project]]
path = "packages/keybay"
publish = ["pub.dev"]

[release.cli]

[[release.cli.project]]
path = "packages/keybay_cli"
publish = ["pub.dev", "github-release", "homebrew"]
binary_platforms = [
  "linux-gnu-x64",
  "linux-gnu-arm64",
  "macos-x64",
  "macos-arm64",
]
```

Both tags derive from the packages' native identities: `keybay-v{version}`
and `keybay_cli-v{version}`.

### Why TOML for intent and JSON for plans

`release.toml` is a small, human-reviewed request. The candidate schema uses
only integers, strings, arrays of strings, named unit tables, and repeated
project tables. TOML expresses that shape without YAML tags, anchors, merge
keys, or implicit scalar typing, and without JSON's punctuation noise. RK still
accepts only the strict subset defined here; choosing TOML does not make every
TOML construct part of the schema.

`plan.json` and receipts are generated protocol objects, not authoring
surfaces. JSON has broad library and signing-envelope interoperability. RK must
freeze one canonical JSON profile before production so every implementation
hashes identical bytes; ordinary parser equivalence is not sufficient. The
default candidate profile is RFC 8785 (JCS) restricted further to UTF-8 and
integers within the IEEE 754 exact range, with no floating-point values.
Phase 0 keeps that default unless it finds a disqualifying defect; the frozen
cross-implementation test vectors are required either way.

The release file does not become a second native manifest. Project versions,
package names, executables, and dependency facts remain in `pubspec.yaml` and
other supported native manifests.

### Field semantics

| Field | Meaning |
|---|---|
| `schema` | Exact author-schema version. Unknown versions fail. |
| `release.<name>` | Stable release-unit identifier. Protected policy binds it. `<name>` is a lowercase ASCII bare key matching `^[a-z][a-z0-9-]{0,62}$`. |
| `tag` | Exact pattern containing `{version}` once; not a general template language. Optional for a single-project unit, defaulting to `<package>-v{version}` from the native package identity. Required for a multi-project unit. |
| `project` | Repeated table, one per exact project authorized in this unit. |
| `path` | Directory relative to the required Git-root `release.toml`; omitted means that immutable Git root, never the process working directory. |
| `publish` | Unordered set of closed channel names. Order never controls execution. |
| `binary_platforms` | Explicit platform-bearing binary outputs. It does not apply to a pub.dev package. |

The unit header grammar is deliberately narrower than TOML. A unit must use
the exact two-segment form `[release.<name>]`. Quoted keys, Unicode keys,
additional dotted segments, inline tables in place of unit tables, and names
outside the grammar are errors even when a general TOML parser could represent
them. Unit names are policy identities; RK does not normalize or alias them.

The root must contain at least one release unit, every unit must contain at
least one project row, and every project row must request at least one
publication channel. Release-unit and project declaration order has no
execution meaning. `publish` and, when present, `binary_platforms` must be
non-empty; both are semantic sets, and duplicate entries are errors. The
canonical plan sorts unit IDs, canonical project paths, channel names, and
normalized platform IDs so declaration order has no graph or execution meaning.
The exact source snapshot and raw configuration hash still record any committed
byte change, including a formatting-only edit; plan diff must distinguish that
source change from an unchanged canonical intent graph. A project row is
identified only after its path is canonicalized; duplicate and overlapping rows
fail rather than merge.

`tag` is a literal prefix/suffix around exactly one `{version}` token. No other
template syntax, escaping, or interpolation exists. The resolved tag must be a
valid Git tag, must equal the authenticated invocation tag, and must match
exactly one unit in the entire file; overlapping unit patterns fail even when
the caller names a unit explicitly.

An omitted `tag` derives the pattern `<package>-v{version}` from the unit's
single project after manifest resolution; a unit with multiple project rows
must declare `tag` explicitly, because a set of packages has no canonical
name. Derived and declared patterns participate identically in the
exactly-one-unit rule, and any overlap fails.

### Version semantics

The proposed schema-1 adapter contract would freeze a
`dart-pub-semver/v1` contract based on SemVer 2.0.0 and Dart's documented
[three-component package version](https://dart.dev/tools/pub/pubspec#version)
with optional prerelease and build suffixes:

- major, minor, and patch are ASCII decimal integers with no leading zero
  unless the component is exactly `0`;
- prerelease and build identifiers use the SemVer ASCII grammar;
- whitespace, a leading `v`, omitted components, and normalization are
  rejected;
- the extracted version scalar's string value must already be canonical;
  parsing and canonical serialization of that scalar must reproduce the same
  string exactly; and
- the full canonical string, including build metadata, is coordinate identity.
  SemVer precedence does not make two different coordinate strings equal.

The version extracted from the tag must equal every selected project's native
manifest version exactly. RK records frozen parser/comparator test vectors in
the adapter contract rather than inheriting whatever a future SDK happens to
accept. Pub.dev and GitHub Release may accept the full contract when their
native validators agree. The schema-1 Homebrew adapter intentionally accepts
only stable `major.minor.patch`, giving its monotonic compare-and-swap rule one
unambiguous numeric ordering. An incompatible channel/version combination
fails before plan admission; there is no author override.

### Project resolution

For every project row, RK must:

1. Require schema 1's `release.toml` at the immutable Git root.
2. Resolve and canonicalize `path` inside that immutable Git tree.
3. Reject every duplicate or ancestor/descendant relationship among all
   declared canonical project paths in `release.toml`, including across
   release units.
4. Discover a native manifest only in that exact project directory.
5. Require exactly one compatible supported native manifest there.
6. Read native identity, version, dependencies, executables, and publication
   vetoes.
7. Reject duplicate native package/product identities across all declared
   project rows.
8. Resolve the native workspace, lockfile, local dependencies, and other build
   materials as a separate source-closure operation.
9. Require every local closure member to remain inside the immutable source
   root and record its path and hash. External or mutable closure members fail.
10. Do not grant a workspace or dependency publication authority unless it also
   has an explicit project row.
11. Intersect project capabilities with the requested channels.
12. Require exactly one compatible closed adapter resolution.
13. Record the manifest path and hash, resolved closure, identity, and
    adapter-contract version in `plan.json`.
14. Require protected policy to authorize that exact resolution.

RK must not recursively discover release projects. Native closure resolution is
allowed only after exact project authorization and may never expand the
publication allowlist.

### Repository-wide first-party identity map

The complete set of explicit project rows in `release.toml`, across every
release unit, is also the repository's first-party identity map. Selecting one
unit does not authorize another unit, but dependency classification uses this
complete map so that an exact sibling identity cannot be mistaken for an
ordinary third-party package.

This has intentional file-wide semantics: adding, removing, or changing an
otherwise unselected project row may change another unit's dependency from an
ordinary hosted dependency into an exact first-party verification
prerequisite. That is a reviewed release-model change, not inert metadata. RK
must make it visible:

- `plan.json` records and hashes the canonical full identity map;
- every derived dependency edge names the declaring row, native identity,
  exact manifest version, constraint check, and whether it is ordering or
  verification-only; and
- planning diagnostics retain the declaring file, line, column, and pointer and
  explain the match before admission; and
- semantic plan diff reports when a row changes an ordinary hosted dependency
  into a first-party ordering or verification prerequisite.

For example:

```text
dependency: fleury_mcp -> fleury ^0.1.0
matched: release.framework project packages/fleury version 0.1.0
edge: verify pub.dev/fleury/0.1.0 before hosted fleury_mcp publication
```

The map grants no publication authority by itself. Removing the framework row
would remove that first-party guarantee and change the plan; protected plan
admission must therefore review the resulting `plan_id`. This explicit
file-wide trade-off avoids a second author-maintained `requires` graph.

Schema 1 also rejects Git submodules, Git LFS pointer-backed release materials,
case-colliding paths, symlinked project directories, and unsupported symlink
types. A later adapter may admit one only after defining an independently
authenticated material and safe extraction contract.

If a future real project contains two supported manifests in one directory, v1
should reject it. A later schema may add a concrete selector such as:

```toml
manifest = "pubspec.yaml"
```

It should not add an abstract `kind = "dart-cli"` merely to work around
ambiguous repository layout.

### Why there is no `kind`

The v1 support matrix is deterministic:

- Dart + `pub.dev` resolves to a Dart package.
- Dart with exactly one executable + `github-release` resolves to platform CLI
  archives.
- Accepted hosted CLI archives + `homebrew` resolve to a formula referencing
  those exact assets and hashes.
- Zero or multiple resolutions are errors.

`kind = "cli"` would add author taxonomy but would not resolve the most likely
real ambiguity: two executables in one manifest. If that case occurs, a future
concrete `executable = "name"` selector is more useful.

GitHub Releases is deliberately CLI-only in v1. RK must not guess whether a
repository meant source archives, desktop bundles, installers, or arbitrary
files.

### V1 compatibility rules

| Requested channel | Native requirement | Other requirement | Derived result |
|---|---|---|---|
| `pub.dev` | Dart package not vetoed by `publish_to` | Tag version equals package version; package already exists and its automated publisher matches protected policy | Accepted package archive or content inventory, OIDC publication, public reconciliation |
| `github-release` | Exactly one Dart executable | Explicit `binary_platforms` and protected release-immutability policy | Per-platform binaries, macOS signing/notarization where applicable, fixed archives, manifest-bound digests, build metadata, and a verified immutable release |
| `homebrew` | Same executable used by `github-release` | `github-release` also explicitly requested | Formula generated from publicly verified immutable archive URLs and hashes |

Additional rules:

- `binary_platforms` with only platform-independent channels is an error.
- A platform-bearing binary channel without `binary_platforms` is an error.
- Homebrew does not silently grant GitHub publication authority. Both channels
  must be explicit.
- `publish` entries are canonicalized and duplicates are errors.
- Unknown destinations and unsupported combinations are errors.
- Schema 1's pub.dev adapter publishes subsequent versions only. Creating a
  package is an explicit out-of-band bootstrap because pub.dev requires
  interactive first-version publication; RK does not add a general
  long-lived-credential path for that exceptional case.
- Native dependency inspection may order explicitly listed projects. It may
  never add a project to the release.
- Schema 1 derives a release/public-availability prerequisite only when the
  dependency identity matches another explicit project row in the same
  `release.toml`. The exact prerequisite version comes from that immutable
  project's manifest and must satisfy the dependent's native constraint; a
  registry solver never chooses it.
- Within a unit, that relationship orders only publication nodes that require
  public dependency availability. Across units, it creates a verification-only
  external prerequisite for the exact coordinate and accepted public contents;
  it does not publish the dependency or grant authority to the other unit.
- Ordinary third-party hosted dependencies never become release prerequisite
  nodes. A CLI build consumes its lockfile-pinned dependency materials; a
  published library retains and validates its native constraints. Mutable
  registry resolution does not alter the plan.
- Only the dependent nodes that actually require hosted availability wait for
  the prerequisite public-verification claim. Local-source binary production
  does not wait
  merely because a sibling package will later be public.
- At most one project in a release unit may request any platform-bearing
  channel in schema 1. Multiple pub.dev projects remain allowed. Multiple
  binary product families under one tag require a future concrete hosting and
  formula contract, not implicit grouping.
- All projects in one unit must resolve to the tag version. Version divergence
  requires separate release units.

Signing, notarization, manifest digests, build metadata, policy-authorized provenance,
public acceptance, and formula generation are derived security stages. They are
not author-selectable destinations or optional flags.

For GitHub, ["immutable
release"](https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/establish-provenance-and-integrity/prevent-release-changes)
is a verified policy claim, not a property of every Release object. The adapter
requires protected repository immutability settings, stages the complete
accepted payload in a verified draft, publishes once, then verifies GitHub
reports the release immutable and verifies its release attestation. Without
that evidence, `github-release` cannot issue an immutable-host receipt.

A GitHub Release also carries consumer-visible metadata that is not an asset:
the title, body, and prerelease flag. The current Keybay workflow generates
the body with `--generate-notes`, which derives content from mutable GitHub
data at publication time, outside the accepted payload and every claim.
Schema 1 must decide the source of that metadata—a closed changelog
extraction, a fixed template, or an empty body—and Phase 0 must verify and
record whether GitHub permits editing the body of an already immutable
release. Release-notes generation never becomes repository-configurable
template input.

RK itself produces build metadata. It is called authenticated provenance only
when a policy-authorized builder control plane attests the subjects, source,
build type, external parameters, and resolved materials. `local/unisolated`
metadata must not claim the assurance of an isolated CI builder.

A Homebrew formula is executable Ruby. The closed adapter emits one fixed
formula structure from strictly validated tokens, accepts and tests the exact
formula blob without tap credentials, and passes only that accepted blob to the
publisher. The tap publisher commits it against an inspected parent/blob; it
does not render or execute Ruby.

## Protected operator policy

`release.toml` is an untrusted request to a privileged deputy. The effective
plan is the intersection of that request and protected operator policy.

At minimum, policy must bind:

```text
source repository identity
+ release-unit name
+ canonical project path
+ resolved native manifest and package/product identity
+ allowed tag namespace and version rule
+ allowed human release-authorization mechanism and identity
+ adapter and adapter-contract version
+ exact remote repository, registry package, or tap destination
+ allowed signing and notarization identity
+ acceptable builder/attester identity
```

Repository configuration may request `homebrew`; it may not choose a tap,
branch, formula path, or token. It may request `github-release`; it may not
redirect publication to another repository. It may request a macOS build; it
may not choose the Developer ID identity.

Release authorization is distinct from source CI, build provenance, and
artifact signing. Policy may require, for example, a tag signed by one allowed
key or an authenticated approval issued by an allowed provider subject.

A production release requires an authenticated release-invocation claim
binding:

- canonical repository identity;
- canonical tag name and parsed version;
- immutable tag object ID and tag payload;
- peeled commit and tree;
- release-unit name; and
- the policy-authorized tag signer or provider-event identity.

`--tag` is only a selector. A matching string, local remote URL, lightweight
tag, or caller-supplied checkout is not authorization unless protected policy
explicitly accepts equivalent authenticated source provenance. The semantic
plan records the canonical release-unit/tag/version and peeled source identity
established by the invocation, but not the signed tag object, invocation
`claim_id`, envelope, approver, or provider event. The source-coordinate record
and plan admission bind the exact tag object and invocation claim to the
resulting `plan_id`. This avoids both a circular signature and a different
semantic plan when equivalent authorization evidence is reissued.

The policy syntax and storage backend are intentionally separate from the
author schema. A production implementation must define them before the first
privileged release. The policy must not be fetched from the source revision
being released.

Policy is approved, not hand-authored. The operator workflow is a
release.toml-driven approval command: it diffs the repository's current
request against the current policy generation, displays the complete
effective delta in plan-diff form, prompts only for the operator-only facts
no manifest can supply—a tap repository, a signing team—and then signs and
records the next generation with the policy key. Policy remains an
out-of-repo, independently keyed statement with its own freshness; only its
authoring is generated. Approval must always display the full semantic
delta; a yes/no prompt without the delta invites rubber-stamping and does
not qualify.

### Policy bootstrap

Hashing an attacker-selected policy into `plan.json` does not make it trusted.
Production executors must verify an authenticated policy envelope against
bootstrap trust configured outside the invocation and source revision.

- Invocation input may locate a policy envelope; it may not select the trust
  root that validates it.
- Policy binds the allowed RK executable digest or signing identity, built-in
  adapter implementation digest, and provider workflow/glue identity—not only
  their self-reported version strings.
- Policy has explicit generation, validity, and revocation semantics.
- Authenticated monotonic policy/admission records in the Release Registry name
  current generations and explicit revocations. Possessing an older correctly
  signed envelope is insufficient to obtain new authority.
- Routine policy evolution may authorize a patched implementation or rotated
  credential without invalidating an identical admitted semantic plan.
  Existing selected outputs and observed public facts remain immutable.
- Revocation is an explicit monotonic fact targeting an admission, invocation,
  source, signer, implementation, principal, policy generation, or coordinate.
  It blocks new operation capabilities according to its scope; it is not
  inferred merely because another policy generation exists.
- Initial admission and every authority-bearing operation verify the current
  policy envelope, admission status, and revocation facts. Schema 1 never
  substitutes a different semantic plan at an existing coordinate.
- The freshness check produces execution evidence. It does not inject current
  time or mutable policy state into the deterministic plan graph.
- Local policy bootstrap may use a separately installed trust root, but
  repository files and command-line flags cannot replace it.

Authority requests are not one universal token with optional fields. Four
closed capability families avoid circular authorization:

| Capability family | Required binding and CAS precondition |
|---|---|
| Policy/status change | Policy namespace, proposed generation/status or revocation, prior generation and registry checkpoint, administrator/quorum, one-time ID, and fence/expiry. Genesis is a separate bootstrap-root ceremony; it is not authorized by the state it creates. |
| Pre-plan source operation | Canonical repository/full tag ref, unit/version, commit/tree, operation-specific unsigned tag-payload digest or exact signed tag object, current policy/status claims, principal, attempt, expected source-tag state, one-time ID, and fence/expiry. It never contains a `plan_id`. |
| Plan admission/re-admission | Source-tag commitment, invocation claim ID, proposed semantic `plan_id`, current policy/status claims, actual planner/adapter identities, principal, and expected prior admission state/epoch as the CAS precondition. Initial admission expects absent; re-admission expects the exact prior plan. |
| Post-admission node operation | The admitted plan/node, selected prerequisites, current admission/policy state, operation/destination, principal, attempt, one-time ID, and fence/expiry. |

Each family has a separate canonical schema, issuer policy, and principal. A
new operation subtype receives a closed schema; it does not widen one generic
capability map.

For example, a post-admission node capability binds:

```text
plan_id
+ node ID
+ attempt ID
+ admission epoch and status
+ policy generation
+ authenticated principal
+ authority class and provider capability
+ expiry and monotonic sequence/fence
```

The operation principal must not receive a sequence as decorative evidence. A
trusted gateway, signer service, or provider validates the applicable
single-use fence and current precondition immediately before exercising its
authority. A monotonically fenced capability is sufficient only when that
authority boundary enforces it and never exposes a reusable underlying
credential to the caller. A direct provider credential instead must be
short-lived, provider-scoped, and revocable with a specified maximum revocation
latency.

Capability issuance, the enforcing authority boundary, and registry transitions
reject stale or replayed fences. A network-isolated signer may consume one exact
short-lived capability without live registry access; capability issuance is
then the bounded authorization point, and every online downstream boundary
rechecks current status before selection or mutation. An external request or
offline signing authorization that passed its check before revocation may still
finish or lose its response. RK records and reconciles that fact, marks
ambiguous or forbidden continuation as an incident, and issues no new
acceptance or dependent-promotion authority unless explicit revocation policy
permits it. A long-lived ambient credential held outside such an enforcing
boundary cannot support the claim that revocation blocks new work.

## Release Registry

Production uses one logical Release Registry protocol for security-sensitive
state. Logical unification prevents several independently operated ledgers; it
does not merge their writer authorities.

The registry is operator infrastructure: one logical registry serves one
operator's whole fleet across repositories. Nothing is shared with other RK
installations or any central service; there is no global registry.

Registry compromise is contained by design. The registry stores no signing
keys, credentials, or artifact bytes, and every record that authorizes
anything is signed by a principal the registry cannot impersonate. An
attacker with registry write access can halt releases or delay
freshness—outcomes that the checkpoint chain, monotonic mirrors, and
witnessing make detectable—but cannot forge policy, selections, admissions,
or publication authority. Registry complexity is tiered accordingly: the
invariant floor is a small linearizable CAS record store, while checkpoints,
witnessing, and recovery drills are production-assurance measures that the
build-versus-adopt scorecard prices like any other cost. A registry feature
whose outcome provider-native state already satisfies for this fleet is not
built.

The registry stores these record families:

| Record | Unique key and role |
|---|---|
| Source tag | Canonical forge/repository identity and full tag ref; irreversibly reserves one unit, version, and tag object, records its hosted observation, then admits one semantic `plan_id` |
| Node selection | `plan_id` and node ID; selects one canonical output identity |
| Immutable destination | Canonical provider/destination namespace and externally canonical coordinate; reserves it for one admitted plan, node, selected identity, and adapter contract before mutation |
| Operation attempt | `plan_id`, node ID, and attempt ID; records intent, capability, provider correlation, results, and final disposition |
| Policy/admission status | Protected identity and generation/epoch; records active status and explicit revocations |
| Checkpoint | Monotonic sequence and prior-checkpoint digest; commits the durable event prefix and materialized-index root |

It must provide:

- linearizable unique-key insertion and compare-and-swap;
- immutable event records and durable tombstones;
- a materialized current-state index that is disposable and rebuildable from
  committed events;
- capability-scoped principals for source reservation, admission, selection,
  immutable-destination reservation, policy/revocation, and operation-attempt
  mutations;
- authenticated, independently auditable checkpoints;
- a non-equivocation mechanism, such as independently witnessed checkpoints or
  a quorum, so two valid-looking histories cannot both advance;
- monotonic client/recovery state that rejects an older valid checkpoint, plus
  a protected minimum checkpoint for a fresh client; and
- backup and disaster recovery that cannot forget an admitted source
  coordinate, immutable-destination reservation, selected output, current
  policy/admission fact, revocation, attempt, or tombstone.

An append-only log alone is insufficient because clients need an authoritative
answer to “was this key absent, and did I atomically become its one accepted
value?” A mutable CAS index alone is insufficient because rollback or operator
error could erase history. The protocol requires both.

The source-tag transition is also closed:

```text
absent
  -> reserved(unit, version, exact tag object, reservation attempt)
  -> hosted(unit, version, exact tag object)
  -> admitted(unit, version, exact tag object, semantic plan_id, admission epoch)
```

An already hosted exact tag may atomically enter at `hosted` after independent
verification. No transition may change the unit, version, tag object, or
semantic plan. An abandoned reservation can strand that external tag; timeout
or operator convenience never permits reuse. Production qualification must
define and test who may perform each transition and every crash window between
the registry and Git provider.

Before mutating an immutable public destination, a separate CAS binds:

```text
(canonical provider/destination namespace, externally canonical coordinate)
  -> (adapter contract, plan_id, node ID, selected output identity)
```

Examples include a pub.dev package/version and a GitHub repository/tag/asset
name. Adapter or schema version is never part of the uniqueness key: two
contract versions targeting the same external coordinate must collide. The
same binding is idempotent; another plan, node, adapter mapping, or identity
conflicts before publication authority is issued. Contract-upgrade fixtures
must test aliases and canonicalization against prior versions. This closes the
race in which two otherwise admitted releases both inspect an external
coordinate as absent. Mutable destinations such as a Homebrew formula path
instead bind an inspected base and desired transition in the operation attempt,
then use the adapter-specific compare-and-swap rule.

Artifact bytes remain in separately replicated content-addressed storage.
Registry records bind their digest, length, media type, and node contract but do
not turn the registry into an artifact warehouse.

An operation attempt begins with immutable intent and an open status projection.
It may later acquire an authority-result fact such as `succeeded`, `failed`, or
`unknown`. After reconciliation it receives exactly one immutable adjudication:

```text
adopted
discarded
selected-equivalent
conflict
incident
```

Provider results and selected outputs are separate facts. An operation can
succeed remotely yet be discarded or become an incident because another exact
output was selected, policy was revoked, or recovery is ambiguous.

Physical implementations may use an existing trusted controller, a local
single-writer database for local/unisolated use, or provider infrastructure.
Production qualification must prove the same consistency, capability, and
anti-rollback contract under concurrent runners and disaster recovery.

The leading physical candidate to evaluate first is deliberately boring: one
dedicated Git repository as the registry. Events are append-only files
committed serially to per-record-family refs; unique insertion and
compare-and-swap use atomic fast-forward-only ref updates, where a lost race
is a rejected push; the materialized index is a rebuildable projection of the
event history; checkpoints are signed commits; writer scoping uses per-actor
credentials and provider rulesets over ref namespaces; non-equivocation
publishes checkpoint hashes to an independent witness such as a public
transparency log; and anti-rollback combines the checkpoint chain with
monotonic local mirrors. Its audit interface is `git log`, its replication is
free, and its failure modes are legible to one operator. A local single-writer
SQLite database may implement the `local/unisolated` lane. If concurrency or
capability scoping proves awkward under qualification, the fallback is a
single conditional-write key-value table. Phase 0 and Phase 1 must evaluate
this candidate against the full registry contract before considering any new
hosted service; it is a default to attack, not a decided backend.

## Deterministic planning

The semantic production plan is a pure function of:

```text
immutable source snapshot
+ canonical release-unit/tag/version facts
+ release.toml
+ effective protected-policy projection
+ closed adapter and platform contract identities/versions
```

`plan.json` must include:

- source repository, exact Git commit/tree, and SHA-256 identity of the
  canonical transported source inventory/archive;
- release unit, canonical tag and parsed version, and peeled commit/tree;
- required release-authorization predicate and allowed identity class;
- `release.toml` hash;
- the effective policy projection containing only release semantics and
  required authority/capability constraints;
- closed adapter and platform contract identities and versions;
- canonical project paths and manifest hashes;
- native package/product names and versions;
- explicitly normalized binary platforms;
- resolved toolchain and platform contracts;
- all artifact and transformation nodes;
- input/output relationships;
- output contracts and identity modes;
- required authority classes and forbidden capability combinations;
- expected public destinations; and
- required claim types.

The effective policy projection contains facts that change release meaning:
the exact repository/package/tap coordinates, signing requirement, code
identity, builder assurance profile, and allowed authority classes. It omits
the full policy envelope and operational allowlists for current executor
binaries or credentials. A policy change that alters this projection changes
the semantic plan; a routine implementation rotation does not.

The plan excludes the signed tag object, actual invocation claim/envelope and
authorizing actor, RK binary digest, adapter implementation digest, workflow
identity, policy-envelope signer, credential version, and receipt-envelope
identity unless one is itself a consumer-visible product semantic. Those
authorization and operational facts belong to source-coordinate, admission,
and operation records/claims.

The plan contains source/input hashes, stable node IDs, and expected output
contracts—never empty mutable-looking output slots. Actual build, signing,
packaging, and publication identities appear only in authenticated claims and
Release Registry selections.

`plan.json` is canonically encoded and never mutated. Its semantic identity is:

```text
plan_id = SHA256("rk.semantic-plan/v1\0" + canonical_plan_json)
```

Domain separation and canonical JSON test vectors are part of the plan
contract. Two conforming implementations must produce byte-identical canonical
plans for the same inputs or one is non-conforming.

Planning must not silently depend on:

- current time;
- host operating system;
- process working directory;
- traversal order;
- environment variables;
- user-level package-manager configuration;
- mutable registry state;
- network availability; or
- mutable tags.

Remote inspection produces separate evidence. It does not alter the
deterministic graph.

Friendly platform names are part of the adapter contract, not loose labels.
For example, `linux-gnu-x64` must expand to a versioned profile such as
`dart-cli/linux-gnu-x64/v1` that fixes the OS, GNU/glibc ABI and minimum
version, CPU baseline, toolchain constraints, archive contract, and builder
profile.
`macos-arm64` must likewise include a minimum supported macOS contract. RK must
never infer the release matrix from the current host.

Author-facing platform profile identity is separate from consumer-facing asset
filenames. The closed adapter freezes asset names and archive-root layout as a
public compatibility contract; Keybay may preserve an existing
`linux-x64` filename while the plan records `dart-cli/linux-gnu-x64/v1`.
Repository configuration never receives a filename template.

The build receipt records the strongest provider-verifiable runner image
identity available, Dart/Xcode/C/Go versions, resolved native materials,
network use, and the completeness of the hermeticity claim. A hosted provider
may expose only a mutable label plus image-build metadata; RK records that gap
rather than inventing a digest. RK calls an output reproducible only when all
relevant materials are pinned and rebuild evidence proves that claim; otherwise
it is reproducibly resolved and accepted, not asserted to be reproducible
bytes.

### Production plan admission

A `plan_id` identifies release semantics. It does not prove that an approved
implementation produced or validated them. Production therefore requires a
`plan-admission` claim before any production node can exercise authority.

A trusted control-plane principal, separate from candidate workloads:

1. retrieves a canonical immutable source snapshot and authenticated
   invocation without running Git hooks, repository commands, or candidate
   code;
2. verifies the current protected-policy envelope, status, and revocations;
3. runs or independently recomputes with the policy-approved RK engine and
   closed adapters;
4. validates the canonical plan, effective policy projection, and all input
   hashes using fixed bounded parsers;
5. verifies and consumes a single-use plan-admission capability whose expected
   prior state is still current;
6. atomically commits the source-tag record to that tag object, `plan_id`, and
   admission epoch; and
7. authenticates an admission claim binding the admission-capability and
   invocation claim IDs, semantic `plan_id`, exact source/config inputs, full
   policy envelope/generation and status evidence, actual
   planner/adapter/workflow implementation digests, admission principal, and
   Release Registry commitment/checkpoint.

The registry source-tag record keys the externally unique Git ref, not an RK
unit name that a later config can rename:

```text
(canonical forge/repository identity, full canonical tag ref)
  -> (release-unit ID, canonical version, immutable tag object ID,
      semantic plan_id)
```

An absent key is committed once; the same binding is idempotent; a different
plan, unit, version, or tag object is a conflict. The record is append-only even if
the hosted Git ref is later deleted, so a renamed unit or newly signed object
cannot reuse the same external tag. An implementation or routine policy change
may append a new
admission epoch only after recomputing and validating the byte-identical
semantic plan under current policy. It cannot replace the coordinate's plan ID,
selected outputs, attempts, or public facts. This permits security patches
without permitting Plan B or rebuilt-node mixing.

Every post-admission artifact or publication boundary rechecks that the hosted
tag ref still maps to the committed object. Deletion or movement halts the
release; it never authorizes re-creation. Schema 1 has no supersession
operation. Any future supersession ceremony must preserve all prior selected
and published identities and prove that no accepted node was rebuilt.

Every post-admission node operation binds the `plan_id`, its current fenced
operation capability, the semantic `claim_id` values of its prerequisites, and
the actual implementation that acted. Prior claims remain immutable facts
across an admission-implementation upgrade; current policy and revocation rules
decide whether they may authorize new work.

A caller-supplied `plan.json` without a valid active admission may be inspected
or used for an explicitly untrusted local dry run, but it cannot enter the
production graph. Plan admission is one capability class and shares no signing,
attestation, notarization, or publication credential.

## Dependency and toolchain materialization

Planning remains offline, but production builds must eventually obtain source,
hosted dependencies, SDKs, compilers, system libraries, and runner images.
Treating that fetch as an unmodeled setup step would leave the largest
supply-chain input outside the plan.

Each closed build adapter defines explicit material contracts and nodes:

```text
immutable source inventory
        |
        v
credential-free dependency/toolchain fetch
        |
        v
digest + lock/content-identity verification
        |
        v
accepted content-addressed materials
        |
        v
network-disabled build
```

The contract requires:

- Git commit/tree identities plus SHA-256 of a canonical transported source
  archive or sorted path/mode/content inventory. RK does not invent an
  underspecified universal filesystem-tree hash.
- Every dependency whose bytes affect an output is resolved to an exact native
  lock/content identity. If the ecosystem lock does not bind content, protected
  policy must name an immutable authenticated mirror/snapshot contract or that
  output fails planning.
- Exact identities, sources, and verification methods for every independently
  materialized SDK, compiler, image, sysroot, and system library. If a hosted
  platform does not expose an independently addressable base image or system
  component, the adapter records the strongest provider-attested identity and
  inventory, declares the residual builder trust, and cannot claim a hermetic or
  reproducible build. Protected policy decides whether that weaker builder
  assurance is allowed.
- A fixed trusted fetcher with no release authority. Downloaded package
  lifecycle scripts, repository commands, and fetched executables are not run
  during materialization.
- User-level package-manager, Git, proxy, and credential configuration
  neutralized or explicitly recorded as protected material.
- Every fetched object rehashed into content-addressed storage, with digest,
  length, media type, source coordinate, and verification claim.
- The build sandbox receiving only selected materials and no network by
  default. Any unavoidable constrained network service requires its own closed
  adapter contract and weaker-assurance evidence.
- Retention or independently verified replication sufficient to recover the
  exact selected inputs for the required release-evidence lifetime.

For Dart schema 1, tracked `pubspec_overrides.yaml` files may inform local
development diagnostics but never hosted publication closure. A compiled
binary or native bundle consumes dependency bytes, so its exact hosted or local
immutable resolution must be committed and content-verified. A normal pub.dev
source package instead publishes its native dependency constraints; imposing an
application lockfile would change that ecosystem contract. Its sterile
publication validation disables overrides, verifies required first-party
versions publicly, and records the exact credential-free validation resolution
and material hashes in a validation claim without treating that resolution as
consumer semantics. Every fetched validation byte still enters CAS. Fleury
cannot rely on sibling overrides to simulate already-published packages.

Mirrors, cache paths, fetch commands, package-manager configuration, and
toolchain installation scripts do not become `release.toml` fields. They are
closed adapter behavior or separately protected infrastructure policy.

## Artifact identity and "build once"

The invariant is:

> A node may have failed or discarded attempts before acceptance. Once one
> output identity is accepted, that identity is immutable and every downstream
> node consumes it exactly. An accepted artifact is never silently rebuilt.

It does not mean one compilation for an entire release:

- every platform build is a distinct node;
- a pub package and a compiled CLI are distinct nodes;
- signing changes bytes and produces a new node;
- packaging produces a new node; and
- notarization may produce authority evidence or a transformed/stapled node,
  depending on the platform format.

Adapters must declare how identity is proven:

### Byte-exact

The destination consumes the exact accepted bytes. SHA-256 identifies the node.
GitHub release assets, Homebrew-referenced archives, npm tarballs, PyPI wheels,
and PyPI source distributions can use this model when their official upload
interfaces accept prebuilt artifacts.

### Content-exact

The native publisher may reconstruct or wrap an archive. RK accepts a bounded,
safe inventory of paths, types, modes, sizes, and file hashes, then redownloads
and compares the hosted logical contents.

### Digest-native

The ecosystem has an immutable digest identity, such as an OCI manifest
digest. RK records and verifies that native digest.

The adapter must not claim byte equality when only logical content equality is
proven.

### Atomic accepted-output selection

Content-addressed storage can retain two different candidates; it does not
decide which one is accepted. Production uses a Release Registry node-selection
record with an atomic compare-and-swap binding:

```text
(plan_id, node ID) -> canonical accepted output identity
```

Every identity-producing node uses this rule, including builds, package
archives, signed binaries, stapled/transformed outputs, and final archives.
After node-specific checks and an outside-the-producing-workload rehash, the
acceptance principal attempts the binding before issuing its acceptance claim. An
absent key is created once. The same identity is an idempotent exact result. A
different identity is a conflict and never receives an acceptance claim,
even if its own operation succeeded. A signer/notary response proves what that
authority did; it does not select the result for downstream use.

Evidence-only nodes do not receive fictitious output selections. For example,
an Apple notarization result may establish a predicate about one signed digest;
a stapled bundle that changes bytes is a new identity-producing node and does
require selection.

Downstream stages resolve and verify the committed registry entry as well as
the authenticated acceptance claim. Failed, losing, and discarded blobs may
remain content-addressed for diagnostics, but they have no promotion authority.

## Claims, receipts, resumption, and partial releases

A deterministic JSON statement is evidence, not authority by itself. Its stable
semantic identity is distinct from the signatures and transparency material
that authenticate it:

```text
claim_id =
  SHA256("rk.claim/<type>/<schema>\0" + canonical_unsigned_statement)

envelope_id =
  SHA256("rk.envelope/v1\0" + complete_envelope_bytes)
```

Re-signing the same statement, adding a signature, rotating a certificate, or
attaching new transparency evidence may change `envelope_id` without changing
`claim_id`. Downstream work binds the claim ID plus required claim type,
issuer/principal, and verification policy. Envelope IDs remain in the audit
record and every envelope is verified before its claim is trusted.

Claim schemas are layered to avoid circular or impossible bindings:

| Claim class | Required binding |
|---|---|
| Policy/bootstrap status | Policy identity, generation, trust-root lineage, current/revoked state, policy-change capability or genesis ceremony, prior checkpoint, and issuing principal. It exists independently of a plan. |
| Release invocation | Canonical repository, immutable tag object/payload, peeled commit/tree, release unit, pre-plan source capability/attempt, tag signer or provider event, and human authorization. It exists before the plan. |
| Plan admission | Admission-capability ID, invocation claim ID, semantic plan ID, effective policy projection, full policy/status claim IDs, exact source/config inputs, actual engine/adapter/workflow digests, admission principal/epoch, and registry source-tag commitment/checkpoint. It cannot bind its own claim ID. |
| Post-admission operation capability/intent | Plan ID, admission epoch/status, current policy/status claim IDs, fenced capability ID/sequence/expiry, exact selected inputs and prerequisite claim IDs, expected output contract, immutable-destination reservation where applicable, principal, and unique attempt ID. It does not claim an output that does not yet exist. |
| Authority result | Corresponding intent claim ID, exact observed inputs/outputs or evidence predicate, actual implementation, authenticated actor/authority, and provider correlation/response status. It says what that authority observed or did; it does not independently accept the output or choose the registry adjudication. |
| Output acceptance | Producer/authority-result claim IDs, independently rehashed canonical identity, node contract, acceptance principal, and Release Registry node-selection commitment/checkpoint. It applies only to identity-producing nodes. |
| Public observation | Prior semantic claim IDs, independently observed public identity/state and raw provider evidence, observer principal, and registry checkpoint. It does not decide whole-release status. |
| Release completion | Exact required node and public-observation claim IDs, registry commitments/checkpoint, completion-contract version, and adjudicator principal. It exists only when every required predicate is satisfied; partial, blocked, and incident remain status projections rather than weaker “completion” claims. |

Receipts use an existing standard envelope such as DSSE/in-toto unless the next
stage independently reverifies the claimed fact. Every claim names its explicit
schema/type and the actual engine/adapter contract and implementation when one
acted. Claims created before plan admission cannot bind a plan that does not
yet exist; post-admission operation claims bind the semantic plan ID and their
fenced capability.

GitHub artifact attestations may be one platform-specific representation. They
must not become RK's only portable source of truth.

Every immutable version coordinate is inspected as:

- `absent`: publication may proceed;
- `exact`: independently verify and continue; or
- `conflict`: stop this plan and require out-of-band incident resolution.

An `absent` result permits mutation only after the Release Registry's immutable
destination key has been bound to this admitted plan, node, and selected
identity. Inspection alone is not a lock. An `exact` result is adopted only
when that binding already exists or a separately authorized migration/bootstrap
claim establishes why pre-RK public state may enter the registry.

Adapters may additionally model authenticated non-final states such as a
GitHub draft or pending Apple notarization submission. Those staging objects
never count as published coordinates and may be removed only under a narrowly
defined, evidenced pre-publication recovery rule.

Every remote staging mutation starts with a durable registry attempt and
authenticated intent claim binding the plan/node, exact input identity,
destination, operation capability, creator principal, and unique attempt ID. An
authority-result claim adds the remote object/submission ID, observed state,
exact remote contents where applicable, and provider evidence.

Recovery is adapter-specific but closed:

- if the recorded remote ID exists with exact state and contents, adopt it;
- if the result claim/envelope was lost, adopt only one object that the
  provider can bind unambiguously to the authenticated attempt and exact
  contents;
- zero matches permits creation only under the original intent;
- multiple, changed, published, or otherwise ambiguous matches stop;
- deletion applies only to an exact unpublished object under an explicit
  recovery operation and compare-and-swap recheck; and
- expiration never silently authorizes deletion, adoption, or replacement.

When a provider cannot correlate a crash-window operation, its adapter must
prove that an exact retry is non-destructive and record every resulting remote
ID, or fail closed. Phase 0 must prototype and qualify separate GitHub-draft
and Apple notarization submission rules; a generic "retry" switch is not
allowed.

Some channels intentionally maintain a mutable latest-version document. A
Homebrew tap normally replaces `Formula/<name>.rb` when a newer version is
released. That operation uses a separate compare-and-swap state machine:

- absent formula -> create desired formula;
- same version and exact contents -> verify and continue;
- older, independently accepted base -> update to the desired newer version
  only while the inspected tap commit and formula blob SHA remain unchanged;
- same version with different contents -> conflict;
- newer version -> downgrade conflict; and
- changed commit/blob between inspection and apply -> concurrency conflict.

The inspection claim binds the accepted base version, tap commit, and blob
SHA. The publication-result claim binds both the base and resulting commit/blob.
This is a monotonic, authorized channel transition—not permission to overwrite
an immutable release coordinate.

A later Homebrew branch advance legitimately supersedes an older formula
claim. Historical verification uses the exact formula blob and immutable tap
commit recorded in that claim; supersession never permits RK to revert the
tap.

A legacy tap cannot silently become the first accepted base. Migration uses a
one-time, authenticated baseline ceremony:

1. protected policy names the exact tap repository, branch, formula path,
   current tap commit, formula blob SHA, and parsed formula version;
2. an operator authorized specifically for migration inspects that immutable
   blob and issues a `legacy-homebrew-base` claim;
3. the claim authorizes only a compare-and-swap transition away from that
   exact blob; it does not attest that the old release assets satisfy RK;
4. any branch or blob change before the first RK update aborts the transition;
   and
5. after the first verified RK formula commit, ordinary publication claims
   replace the legacy baseline permanently.

There is no `--trust-current-tap` shortcut. This preserves monotonic update
safety without laundering a pre-RK release into accepted artifact history.

RK must never silently overwrite, downgrade, move a tag, replace an asset, or
accept different contents at the same package version.

Cross-channel publication is not atomic. There is no rollback after publishing
an immutable pub.dev version. Authoritative release state is the monotonic set
of committed facts, for example:

```text
coordinate admitted
immutable destination reserved
operation intent exists
authority result exists
output identity selected
remote object exists
public coordinate exact
dependent prerequisite verified
revocation or incident recorded
```

`rk status` projects those facts into friendly labels such as planned,
produced, accepted, published, verified, partial, blocked, or incident.
Different node types legitimately skip labels; no generic mutable state field
is authoritative.

A final completion claim is separate from individual node claims and may be
issued only after independently recomputing every required predicate against one
registry checkpoint. If one channel succeeds and another fails, there is no
completion claim: `rk status` reports a partial release and resumes only with
the same semantic plan, source, version, and selected artifacts, under an active
admission and current operation authorization. Routine policy or implementation
evolution may continue that plan; explicit revocation may leave it permanently
partial.

## Authority and execution boundaries

Credential-free stages may inspect and execute repository source and candidate
artifacts. Authority-bearing stages must be intentionally narrow. Reading or
parsing attacker-controlled bytes is not execution: plan admission may consume
a canonical source snapshot through fixed bounded parsers, but it never runs
Git hooks, repository tooling, package lifecycle scripts, build scripts, or
candidate code.

The security boundary is an authenticated principal and its effective
capabilities—not a process, container, or CI job name. Separate jobs are useful
isolation mechanisms only when they also have distinct non-impersonable
identities, credentials, provider-enforced scopes, and secret-bearing mutable
state.

Repository builds and candidate smoke tests are untrusted workloads. They never
receive claim-signing, attestation, signing, notarization, or publication
authority. A policy-authorized control plane:

1. hashes the workload inputs;
2. runs the workload in an ephemeral no-secret sandbox with network disabled
   unless a closed adapter contract explicitly requires a constrained service;
3. terminates the workload and any descendants;
4. rehashes accepted outputs outside the workload's reach; and
5. authenticates the claim from the control plane.

A workload-generated or self-signed claim cannot gate promotion. The same
rule applies to normal-CI accepted-source evidence: candidate-controlled
workflow code must not be able to mint the credential that approves itself.
Provider implementations may satisfy this with an isolated trusted reusable
workflow or equivalent control plane, but the concrete identity must be bound
by protected policy.

Release authority classes are mutually exclusive by default. An implementation
must not infer that an unlisted pair is allowed. The minimum
forbidden-capability matrix highlights especially dangerous combinations:

| Capability A | Capability B that the same principal must not hold |
|---|---|
| Candidate execution | Any release admission, acceptance, signing, notarization, attestation, publication, tap, or policy authority |
| Invocation verification/claim issuance | Tag signing, tag mutation, plan admission, or destination mutation |
| Plan admission | Any acceptance/selection, signing, attestation, notarization, publication, observation, completion, or policy authority |
| Acceptance/selection or provenance issuance | Any dependent destination publication |
| Tag signing | Tag/repository mutation |
| Artifact signing | Artifact or Release publication |
| Notarization submission | Artifact or Release publication |
| Attestation issuance | GitHub Release publication |
| Immutable-destination reservation | Mutation of that destination |
| Operation-capability issuance | Execution of the operation it authorizes |
| Public-observation issuance | Mutation of the observed destination, dependent publication, or release-completion adjudication |
| Release-completion adjudication | Publication or issuance of any observation it consumes |
| Policy/revocation administration | Every other release authority class |

The only v1 same-principal bundles are atomic parts of one authority:

- a policy/status authorization plus its exact generation/revocation CAS;
- a source-coordinate reservation plus creation of only its exact signed tag
  object; an independent invocation verifier records the hosted observation;
- a plan-admission claim plus the corresponding source-coordinate admission
  CAS;
- an output-acceptance claim plus the corresponding node-selection CAS;
- one signing, notarization, attestation, or publication operation plus its own
  authority-result claim.

An accepted bundle is one capability class, not permission to combine either
part with another authority. Adding another bundle requires a threat-model and
schema revision; provider convenience is not sufficient.

Two operations count as separated only when all applicable conditions hold:

- distinct authenticated principals and policy-bound workload identities;
- distinct credentials or provider capabilities that cannot impersonate one
  another;
- non-overlapping provider-enforced mutation/evidence authority;
- no shared mutable secret-bearing process or storage that lets one recover the
  other's credential;
- no candidate-controlled code or repository-defined command in either trusted
  path; and
- immutable, digest-verified handoff between them.

For every authority, the plan contract, admission evidence, and Phase 0
scorecard record:

```text
intended authority
provider-enforced authority
residual ambient authority
mitigating controls
```

A create-only broker backed by a provider credential that can also update or
delete is not provider-enforced least privilege merely because its code
promises restraint.

Residual ambient permission is acceptable only within one authority class and
only when protected policy bounds the destination, operation, lifetime,
monitoring, and revocation latency. A credential or provider identity that can
exercise both sides of any mutually exclusive pair fails production
qualification; documenting or wrapping it does not restore separation.

### Separation relative to the operating root

"Non-impersonable" is evaluated relative to the named roots of trust, not in
the absolute. On this fleet the operating root can, by definition, exercise
every authority; qualification asks whether any principal other than a named
root can cross a forbidden pair.

For the v1 GitHub provider, provider-enforced separation concretely means:

- each authority class runs under a distinct protected environment whose
  secrets are scoped to that environment alone;
- workload identity is bound by OIDC claims such as `job_workflow_ref`,
  `environment`, and repository, and every external trust relationship
  conditions on those claims rather than on repository or organization
  membership alone;
- trusted workflow definitions live where candidate repositories cannot
  write, such as a separately protected controller repository consumed by
  pinned ref; and
- registry and tap write access is scoped per principal through provider
  rulesets or per-actor credentials, never one shared token.

Before any Phase 1 implementation, the RK candidate must publish a v1
principal-budget table for the GitHub provider: every authority class mapped
to its concrete identity mechanism, credential, enforcing provider setting,
and residual ambient authority. If two classes cannot receive distinct
enforceable identities on the provider, the table must say so, and the design
must change before implementation—by adding an enforcing boundary, moving the
class off the provider, or revising the matrix through an explicit
threat-model revision. Discovering the collision during implementation is not
acceptable.

Production rules:

- Build environments receive source and dependencies but no signing,
  notarization, registry, GitHub-release, or Homebrew authority.
- The candidate-acceptance workload receives artifacts but no release
  authority. A separate control-plane principal observes it, rehashes its
  outputs, and has only the authority to issue the acceptance claim and write
  the corresponding node selection.
- macOS signing receives only accepted unsigned binaries and one signing
  identity. It receives no source checkout or publisher credential and does
  not execute candidates.
- macOS notarization receives only the accepted signed submission and one
  notarization identity. It receives no signing or publication authority and
  does not execute candidates.
- Publication receives only accepted final artifacts and one destination
  authority.
- A Homebrew publisher receives verified public asset metadata and only tap
  authority.
- A pub.dev publisher receives a sterile accepted package inventory/archive
  and only its short-lived publication authority.
- Candidate binaries are never executed in a credentialed process.
- One authenticated principal never receives a forbidden capability
  combination merely because a provider packages operations into one job.

“Release authority” includes both destination mutation and the ability to mint
authenticated evidence that gates a later node. A provenance or acceptance
attester is therefore an authority even when it cannot upload a package.
Attestation issuance and GitHub Release publication must run under separate
principals with non-overlapping capabilities; a publisher may consume and
independently verify an attestation, but may not mint the attestation it relies
on.

An operation may return authenticated evidence of its own single authority
without creating a second one—for example, a signing service can bind its input
and output digest in its signing response. It may not also assert an
independent build/acceptance fact or mutate another destination. A publisher's
claim is likewise not trusted merely because the publisher authenticated it;
public state is independently inspected before it gates another channel.

### Content-addressed handoff

Cross-stage artifact transport is part of the trust boundary. Whoever can
replace a blob, claim, or envelope between isolated stages otherwise controls
signing and publication.

- Every accepted blob is placed in content-addressed immutable staging.
- Registry selections and claims bind digest, byte length, media type, and
  expected node ID.
- Consumers retrieve by digest and verify before parsing, extracting, signing,
  or publishing. A storage path or artifact name is never identity.
- Archive inspection and extraction are bounded, duplicate-aware,
  traversal-safe, and symlink-safe.
- Provider artifact storage and caches are declared materials/trust
  dependencies. Caches never supply accepted identity by themselves.
- Loss of an accepted output prohibits rebuilding or identity substitution. It
  does not prohibit recovery of the exact selected identity from an
  independently verified immutable replica.

Exact restoration requires the registry selection, digest, length, media type,
node contract, and replica/public immutability evidence to match. It emits a
recovery claim and never creates a new selection. Restoring exact bytes for
retention or audit does not itself require an active admission; consuming them
in any new authority-bearing operation does. A publicly verified immutable
GitHub asset or replicated CAS object may recover byte-exact bytes.
Content-exact hosted inventory can recover only its logical content fact, not
reconstruct or prove an earlier byte-exact archive. A lost unsigned binary with
no exact replica remains unrecoverable.

Short-lived workload identity is preferred over long-lived tokens. A
destination that exposes only a long-lived credential may still be mediated by
a trusted fenced gateway that never delegates the credential and represents
only one authority class. If the caller receives the reusable token, revocation
cannot reliably block new work; that architecture fails the revocation
invariant rather than merely emitting a weaker claim.

Local execution uses the same planner and adapters, but its builder identity is
`local/unisolated`. Protected policy decides whether that identity may produce
production artifacts. Local parity means the same logic and formats, not equal
assurance. Separate local helper processes do not establish authority isolation
when one OS account has ambient access to multiple credentials. A production
policy requiring isolated principals rejects those local claims.

## Testing boundary

RK cannot remain austere if every repository can configure arbitrary release
commands. It also cannot infer every product-specific correctness test.

V1 therefore separates:

1. normal product CI and source-review evidence;
2. fixed native-adapter validation, such as `dart analyze`, package validation,
   locked dependency resolution, and supported native build commands; and
3. release-artifact acceptance, such as exact inventory, architecture, runtime
   smoke behavior, signing identity, and public-channel verification.

Project-specific tests remain product CI unless their invariant becomes part of
a closed adapter contract. A credential-free release lane may rerun an
accepted-source product test against an installed public artifact, but the
repository-controlled test cannot mint its own gating claim and its command
never becomes release configuration.

Before production implementation, RK must define how protected policy requires
an authenticated "accepted source commit" result from normal CI without tying
the engine to GitHub. This is a required design gate, not permission to add
arbitrary hooks to `release.toml`.

## Real-world example: Keybay

### Intended configuration

Keybay has two release units because the core package must become public before
the CLI release can consume it, even though both versions move in lockstep.

```toml
schema = 1

[release.core]

[[release.core.project]]
path = "packages/keybay"
publish = ["pub.dev"]

[release.cli]

[[release.cli.project]]
path = "packages/keybay_cli"
publish = ["pub.dev", "github-release", "homebrew"]
binary_platforms = [
  "linux-gnu-x64",
  "linux-gnu-arm64",
  "macos-x64",
  "macos-arm64",
]
```

Both tags derive from package identity: `keybay-v{version}` and
`keybay_cli-v{version}`. Core's pre-RK `v{version}` tags remain historical;
RK-managed core releases begin the derived namespace.

The repository root cannot use omitted `path`: its `pubspec.yaml` is a
non-published workspace, not either releasable package.

### Native and author-controlled files

| File | RK role | Important commentary |
|---|---|---|
| [`pubspec.yaml`](../../pubspec.yaml) | Workspace membership | Declares only `packages/keybay` and `packages/keybay_cli`; it is not a published package. |
| [`pubspec.lock`](../../pubspec.lock) | Reviewed dependency resolution | The two packages use one committed root lockfile. There are no package-local release lockfiles. Release builds must enforce this exact resolution. |
| [`packages/keybay/pubspec.yaml`](../../packages/keybay/pubspec.yaml) | Core native identity | Owns package name, version, repository, SDK constraint, and dependency pins. |
| [`packages/keybay_cli/pubspec.yaml`](../../packages/keybay_cli/pubspec.yaml) | CLI native identity | Owns `keybay_cli`, its version, exact core dependency, and the single `keybay` executable declaration. |
| [`packages/keybay_cli/bin/keybay.dart`](../../packages/keybay_cli/bin/keybay.dart) | CLI entry point | The sole production AOT target. The adapter does not scan example `bin/` directories. |
| [`packages/keybay_cli/lib/src/command.dart`](../../packages/keybay_cli/lib/src/command.dart) | Embedded version contract | `cliVersion` currently must agree with both pubspec versions and the exact core pin. RK validates this Keybay policy through accepted source evidence or a closed project migration, not a generic regex knob. |
| Core and CLI `README.md`, `CHANGELOG.md`, `LICENSE`, `lib/**`, `bin/**`, `.pubignore`, examples | Native package inventory | Pub's native packager determines the exact package. Changelog/version preparation remains outside RK. |
| [`packages/keybay_cli/README.md`](../../packages/keybay_cli/README.md) | Consumer verification contract | Documents immutable-release, asset, checksum, workflow provenance, macOS identity, notarization, Homebrew, and pub.dev expectations. Generated future instructions must preserve or deliberately migrate that signer identity. |

The local workspace matters: the CLI binary is built from the reviewed sibling
`packages/keybay` source, not from whatever version a registry happens to
resolve later.

The CLI manifest's exact `keybay` dependency also creates a publication
precondition: the matching core version must already be publicly available and
must reconcile to the accepted core contents before the CLI package is
published. RK derives that check from native dependency metadata. It does not
require an author-maintained `requires` graph, and it does not grant the CLI
unit authority to republish core.

That public dependency check is not enough to preserve Keybay's stronger
paired-tag policy. The current release-preparation tool also requires the CLI
tag and core tag to peel to the same commit. Repository code may validate that
rule without credentials, but it cannot remain the production authorizer.

The trusted tag path is split:

1. a pinned authorizer constructs and displays the exact annotated-tag payload,
   repository/full tag ref, unit, version, and commit for human approval, then
   issues a short-lived single-use pre-plan signing capability for that exact
   payload digest;
2. an offline/hardware signer with no repository-write or network authority
   verifies the capability and signs only that payload before expiry, then
   returns the signed tag object;
3. a separate create-only tag pusher with no signing key consumes its own
   pre-plan source capability, atomically reserves the canonical repository/tag
   ref, unit, version, and exact object in the Release Registry source-tag
   record, verifies that the approved commit already exists at the protected
   source ref and the remote tag is absent, and creates only that exact tag
   ref/object; and
4. an invocation verifier with neither signing nor repository-mutation
   authority consumes an observation capability, reads the hosted object,
   verifies its signer and commit, records `hosted`, and has only the authority
   to issue the release-invocation claim.

The reservation has an authenticated attempt ID and two states: `reserved` and
`hosted`. The same attempt may finish an initial create while still reserved.
Once the exact remote object is observed, the record becomes permanently
hosted. An absent or different remote ref after that is conflict, never an
invitation to recreate or move it. A reservation cannot be reused for another
object even if the first attempt never completes. Plan admission later adds the
`admitted` state and semantic `plan_id`; none of these transitions may rename
the unit or replace the version or object.

For CLI, the authorizer additionally requires the accepted core
tag/publication claims, verifies the same commit and version, and binds both
tag objects. The signing agent is never exposed to `tool/release.dart`, the
pusher, or another candidate-controlled process. Equal public package contents
alone do not prove same-commit authorization.

### Existing release logic used as migration evidence

These files are not proposed author configuration. They encode current
invariants that the closed adapters or normal CI must preserve:

| File | Current responsibility | RK treatment |
|---|---|---|
| [`tool/release.dart`](../../tool/release.dart) and [`tool/keybay-release`](../../tool/keybay-release) | Synchronize four version references, prepare release PRs, verify the release signer, and currently push one selected signed tag per command. Core must publish first; only then may a separate CLI command push the paired CLI tag from the same commit. | Retain preparation, status, and credential-free validation. Retire the checkout-hosted `publish` path in favor of the external authorizer, offline signer, and separate tag pusher/verifier; do not copy its product policy into generic author fields. |
| [`tool/test_release.dart`](../../tool/test_release.dart) | Regression coverage for Keybay's tag and version policy. | Continues to test project release preparation. |
| [`tool/validate_publish.sh`](../../tool/validate_publish.sh) | Pub dry-run and exact-pin warning policy. | Native Pub validation plus Keybay-specific warning policy must be separated. |
| [`tool/publish_pubdev.sh`](../../tool/publish_pubdev.sh) | Builds one package archive, publishes it through OIDC, or reconciles an existing archive. | Primary evidence for the Dart package adapter, with the hidden-flag caveat below. |
| [`tool/compare_pub_archives.py`](../../tool/compare_pub_archives.py) | Safely compares hosted and expected pub contents while ignoring volatile archive timestamps. | Candidate for audited content-exact adapter logic. |
| [`tool/package_cli_release.sh`](../../tool/package_cli_release.sh) | Freezes the native CLI archive inventory. | The adapter needs a fixed, reviewed bundle inventory; it must not accept arbitrary include globs. |
| [`tool/verify_cli_binary.sh`](../../tool/verify_cli_binary.sh) and [`tool/verify_cli_archive.sh`](../../tool/verify_cli_archive.sh) | Runtime and structural candidate acceptance. | Move common checks into the closed Dart CLI adapter; retain product-specific behavior in normal CI. |
| [`tool/verify_macos_release.sh`](../../tool/verify_macos_release.sh) | Freezes identifier, team, hardened runtime, timestamp, entitlements, and designated requirement. | The macOS adapter applies protected identity policy and emits a verification claim/receipt. |
| [`tool/render_homebrew_formula.py`](../../tool/render_homebrew_formula.py) | Generates the four-platform formula from actual archive hashes. | Closed Homebrew adapter input, not a repository-configured renderer. |
| [`doc/cli-release.md`](../cli-release.md) | Operator policy and failure runbook. | Human-reviewed migration input for protected policy and future operational documentation. Production policy is never regenerated automatically from the revision being released. |
| [`.github/workflows/publish.yml`](../../.github/workflows/publish.yml) and [`.github/workflows/release_cli.yml`](../../.github/workflows/release_cli.yml) | Current provider-specific orchestration. | Migration oracle and shadow target; eventually replaced by thin generated/invoked provider glue. |

### Keybay-specific security aspects

The installed `tool/keybay-release` wrapper currently executes
`tool/release.dart` from the selected checkout while the signing agent is
available, and that Dart program creates and pushes the tag. A maliciously
modified checkout could use the signer as an oracle or push additional refs.
Non-exportable key material does not fix that confused-deputy boundary. This is
a known migration gap, not an RK pattern: production migration is blocked
until tag authorization moves outside repository-controlled execution.

Protected policy must bind at least:

- GitHub repository `danReynolds/keybay`;
- tag namespaces `keybay-v{version}` and `keybay_cli-v{version}` (the pre-RK
  core namespace `v{version}` remains historical);
- the dedicated release tag-signing fingerprint;
- Dart release toolchain version;
- Apple Team ID `5AHFA9FUZG`;
- code identifier `io.github.danreynolds.keybay.cli`;
- Homebrew tap, branch, formula path, and consumer spelling;
- GitHub attestation signer identity; and
- pub.dev package and trusted-publisher registrations.

The secret values themselves remain outside source control.

The current `publish-github` job in
[`.github/workflows/release_cli.yml`](../../.github/workflows/release_cli.yml)
holds `contents: write`, `id-token: write`, and `attestations: write` together.
That is migration evidence, not the RK end state: shadowing must prove a split
between the provenance issuer and the GitHub publisher before this workflow can
be retired.

Keybay's `tool/publish_pubdev.sh` currently uses SDK-specific hidden
`--to-archive` and `--from-archive` flags. This is valuable proof that exact
prebuilt publication is possible with the pinned SDK, but it is not a stable
documented Dart interface. The RK adapter must:

1. pin and feature-test the supported SDK capability;
2. fail closed if the flags disappear or their semantics drift;
3. keep safe content comparison for retry reconciliation; and
4. avoid advertising a stronger general pub.dev guarantee than the tested
   adapter contract provides.

The current Homebrew formula also contains product metadata that cannot be
derived safely from `pubspec.yaml`: Linux requires `libsecret`, and the
installation retains `README.md` and the packaged `example/` directory. Its
formula test itself is the fixed `--version`/`--help` check. A separate
credential-free `accept-homebrew` job installs the public formula and runs
Keybay's quickstart acceptance test. A generic Homebrew adapter must not
silently omit the packaging requirements, hardcode Keybay policy in RK, accept
an arbitrary Ruby template, or move product choices into protected credential
policy.

Phase 0 must resolve the smallest typed author input or strict archive
convention needed for unavoidable packager metadata:

- derive description, homepage, license, executable, and version from the
  native manifest when the derivation is unambiguous;
- prefer a fixed bundle/install convention over a second `support_files`
  inventory;
- admit runtime dependencies only from a closed adapter vocabulary, with exact
  platform meaning;
- keep generic `--version`/`--help` formula checks fixed in the adapter; preserve
  Keybay's post-install quickstart as an authority-free product acceptance
  workload bound to accepted-source evidence, not a generic config field, unless
  a second real product proves a closed adapter test enum necessary;
- permit only exact source-root-relative paths if a file exception is proven
  unavoidable—never globs, Ruby, shell, templates, or arbitrary argv; and
- freeze public asset filenames and archive-root layout as adapter contracts,
  preserving Keybay compatibility or documenting an explicit migration.

This RFC does not freeze an exact Homebrew subtable. Until Phase 0 proves the
minimum unavoidable field set, the three-field project row expresses release
intent but cannot reproduce Keybay's complete formula. Phase 0 must also prove
how the post-install Keybay acceptance oracle is retained or explicitly
replaced without granting its repository-controlled script release authority.

Keybay's current macOS archive identity is part of product behavior, not just
distribution polish. A different code identifier or Developer ID requirement
can break access to existing login-Keychain items. That makes signing identity
a protected policy input and its verification a release gate.

The existing 0.1.0 native release does not satisfy the current immutable-release
and macOS verification contract. It is historical input, not a valid baseline
claim for RK artifact migration. Its live Homebrew formula may be admitted
only as the exact, transition-only `legacy-homebrew-base` described above; that
does not validate or republish the 0.1.0 assets.

## Real-world example: Fleury

### Repository shape

The live Fleury repository root contains 16 Dart manifests. Only these five are
representative public release projects:

```text
packages/fleury/pubspec.yaml
packages/fleury_test/pubspec.yaml
packages/fleury_widgets/pubspec.yaml
packages/fleury_web/pubspec.yaml
packages/fleury_mcp/pubspec.yaml
```

Other manifests belong to private examples, storybooks, profiling, website
examples, and peer fixtures. The repository also contains private npm
manifests and benchmark Cargo manifests. Recursive discovery would conflate
test material with release authority.

Exact project rows are therefore a security property, not mere verbosity.

### Candidate configuration

This example treats the framework packages as one lockstep release unit and
the MCP server as a separately authorized product:

```toml
schema = 1

[release.framework]
# A multi-project unit has no derivable name, so its tag is explicit.
tag = "fleury-v{version}"

[[release.framework.project]]
path = "packages/fleury"
publish = ["pub.dev", "github-release", "homebrew"]
binary_platforms = [
  "linux-gnu-x64",
  "linux-gnu-arm64",
  "macos-x64",
  "macos-arm64",
]

[[release.framework.project]]
path = "packages/fleury_test"
publish = ["pub.dev"]

[[release.framework.project]]
path = "packages/fleury_widgets"
publish = ["pub.dev"]

[[release.framework.project]]
path = "packages/fleury_web"
publish = ["pub.dev"]

[release.mcp]

[[release.mcp.project]]
path = "packages/fleury_mcp"
publish = ["pub.dev"]
```

Important: this is a proposed product policy, not something RK should infer.
All five packages happen to be version `0.1.0` today, but equal current
versions do not prove that they should remain one release unit.

The prebuilt `fleury` GitHub/Homebrew routes are also a future product
decision. Current installation is from Git or local paths, not
`dart pub global activate fleury`: as of 2026-07-26, none of these five package
names exists on pub.dev. If Fleury does not promise native archives, remove
those two channels and `binary_platforms`. `fleury_mcp` exposes its own
executable, but this example keeps it pub.dev-only until a separate
prebuilt-binary promise is made.

### Files and dependency order

| File | RK role | Important commentary |
|---|---|---|
| `packages/fleury/pubspec.yaml` | Framework identity and `fleury` executable | It has no first-party publication prerequisite. Publish it first. |
| `packages/fleury/bin/fleury.dart` | Prospective native CLI entry point | Used only if binary channels are deliberately enabled. |
| `packages/fleury_test/pubspec.yaml` | Test-support package identity | Depends on hosted `fleury`. |
| `packages/fleury_widgets/pubspec.yaml` | Widgets package identity | Depends on `fleury`; its dev validation also references `fleury_test`. |
| `packages/fleury_web/pubspec.yaml` | Web package identity | Depends on hosted `fleury`. |
| `packages/fleury_mcp/pubspec.yaml` | MCP package and executable identity | Depends on hosted `fleury`; exposes `fleury_mcp` via `bin/fleury_mcp.dart`. |
| Per-package `CHANGELOG.md`, `README.md`, and `LICENSE` | Native publication inventory | Validated per explicitly listed package. |
| Tracked `pubspec_overrides.yaml` in the four dependent packages | Local development only | Points at sibling source. It must not silently become registry publication authority. |
| Per-package local `pubspec.lock` | Current local resolution | These lockfiles are ignored and not part of the committed source snapshot. |

The `framework` unit's derived publication order is:

```text
fleury ──> fleury_test ──> fleury_widgets  (validation-only second edge)
   ├────────────────────> fleury_widgets
   └────────────────────> fleury_web
```

For conservative native validation, `fleury_test` should be available before
validating/publishing `fleury_widgets` because widgets has a development
dependency on it. Dependency inspection determines order only among projects
already listed in the relevant release plan.

The separate `mcp` unit derives an external prerequisite that verifies the
exact `fleury` version read from the explicit framework project row, proves
that it satisfies MCP's native constraint, and verifies that exact public
coordinate before MCP's hosted-publication validation/publishing nodes. A
registry solver never picks the prerequisite version. This does not imply that
the `framework` invocation also releases MCP.

### Fleury admission findings

- Pub package publication is structurally representable, but none of the five
  names is currently bootstrapped. Pub.dev
  [allows automated publishing only for an existing
  package](https://dart.dev/tools/pub/automated-publishing); its first version
  must be published interactively with `dart pub publish`. Phase 4 therefore
  needs a one-time, human-authorized ceremony outside RK v1 for each package.
  The ceremony must start from an immutable reviewed source, publish in native
  dependency order, redownload and reconcile each public content inventory,
  and record an authenticated bootstrap receipt before the next package or
  RK-managed version proceeds.
- A native `fleury` binary route is not reproducibly admitted yet: the
  repository has no committed executable lockfile or equivalent immutable
  resolution.
- Local path overrides can make tests pass before sibling versions are
  available on pub.dev. The adapter must validate the actual publication
  closure, not only the development override graph.
- `rk init` may report other detected projects for human review. No planning or
  execution path may add them automatically.

Fleury is the right second pilot because it exercises explicit multi-package
authorization and native dependency ordering without requiring RK to support
arbitrary workspaces.

## Real-world example: Dune CLI

### Intended future configuration

After its source and native bundle become reproducible, Dune's release intent
should be small:

```toml
schema = 1

[release.cli]

[[release.cli.project]]
# path omitted (repository root); the tag derives to dune_cli-v{version}.
publish = ["github-release", "homebrew"]
binary_platforms = [
  "linux-gnu-x64",
  "linux-gnu-arm64",
  "macos-x64",
  "macos-arm64",
]
```

There is intentionally no `pub.dev`: `pubspec.yaml` declares
`publish_to: none`.

### Files RK would use after remediation

| File or output | RK role | Important commentary |
|---|---|---|
| `pubspec.yaml` | Native project identity | Declares `dune_cli` `0.0.1`, `publish_to: none`, the single `dune` executable, and the effective dependency graph. |
| A committed `pubspec.lock` | Immutable dependency resolution | The current local lockfile is ignored and cannot authorize a production build. |
| `bin/dune.dart` | CLI entry point | Calls the Dune runner and is the native bundle target. |
| Exact source commit | Source identity | Must include or immutably resolve the complete dependency closure. |
| `dart build cli` output | Candidate bundle | Dune is not one standalone executable. The bundle contains `bin/dune` and native libraries under `lib/`. |
| `bundle/bin/dune` | Main executable | Must be inventoried, architecture-checked, hashed, tested, and signed on macOS. |
| `bundle/lib/*` | Native runtime dependencies | Every dylib/shared object is part of the accepted artifact and signing/notarization boundary. |
| `TRACKER.md` and `doc/rfcs/0001-runtime-daemon-and-tui-architecture.md` | Current readiness evidence | Record that standalone distribution and parts of the native packaging design remain unfinished. They are not release authority. |

### Why planning must fail today

The current `pubspec.yaml` resolves five dependencies through mutable sibling
paths:

```text
dune_core      -> ../dune_core
fleury         -> ../fleury/packages/fleury
fleury_widgets -> ../fleury/packages/fleury_widgets
stdio          -> ../stdio
resqlite       -> ../resqlite-0.7.0  (root dependency override)
```

The local `pubspec.lock` is ignored, untracked, and does not bind those sibling
Git commits. A fresh clone cannot reproduce the build without separately
provisioning mutable directories outside the repository. Existing local bundle
output is ignored, partial, and ad-hoc signed; it is evidence for future bundle
shape, not a release candidate.

`rk plan` must exit nonzero and emit no executable `plan.json`. It may emit a
separately typed `diagnostics.json` that no production, build, or publication
command accepts:

```text
RK-DART-201: project is not a hermetic release input

release: cli
project: .
manifest: pubspec.yaml
adapter: dart-cli/v1

pubspec.lock is not present in the source commit.

The effective dependency graph escapes the release source:
  dune_core       -> ../dune_core
  fleury          -> ../fleury/packages/fleury
  fleury_widgets  -> ../fleury/packages/fleury_widgets
  stdio           -> ../stdio
  resqlite        -> ../resqlite-0.7.0

RK will not infer, copy, or trust mutable sibling checkouts.
No build or credentialed publication step was started.

Remediation:
  - replace path dependencies with hosted or content-pinned dependencies, or
    move the complete closure into one explicitly allowlisted source workspace;
  - commit and enforce pubspec.lock from a fresh clone;
  - remove release-time dependency overrides; and
  - pass full dart-build-cli bundle acceptance for every declared platform.
```

If `pub.dev` were requested, RK must additionally reject it because the native
manifest vetoes that destination.

### Dune admission criteria

Dune may enter the production release path only after:

- every source dependency is inside one immutable, explicitly understood
  source closure or is a hosted/content-pinned dependency;
- the lockfile is committed and enforced from a fresh clone;
- the four target bundles are produced with a pinned toolchain;
- the complete `bin/` and `lib/` inventory is accepted;
- every macOS Mach-O component is signed and verified before notarization;
- Linux shared-library identities and ABI contracts are verified;
- public archive structure and runtime smoke tests pass; and
- protected policy binds the GitHub repository, Homebrew formula, executable,
  native library inventory contract, and Apple identity.

This is an example of a useful hard failure. A generic "run this build command"
escape hatch would make the config look flexible while discarding the release
compiler's main security guarantee.

## Provider integration

Human commands describe outcomes rather than internal node mechanics. The
minimal intended surface is approximately:

```text
rk check --tag <tag>
rk plan --tag <tag> [--expect-unit <unit>]
rk diff <plan-or-coordinate> <plan-or-coordinate>
rk status <coordinate>
rk explain <plan-or-coordinate> --why-blocked
rk verify <coordinate>
```

The authenticated tag must match exactly one unit; authors do not provide two
independent selectors that can disagree. `--expect-unit` is only an assertion.
These names remain illustrative, but outcome-oriented plan, diff, status,
explanation, and public verification are required product capabilities.

Plan diff is semantic and first-class. It calls out source, intent, policy
projection, artifact graph, platform, authority, and repository-wide
first-party identity-map changes. Diagnostics retain the declaration's source
file, line, column, and JSON/TOML pointer even though source order has no
semantic meaning.

Planning is strictly offline. A plan-invalidating error emits stable typed
diagnostics and no executable `plan.json`; planning categories include author
configuration, unsupported native shape, policy denial, and unresolved local
material. Execution/status diagnostics separately classify missing public
prerequisites, remote conflict, temporary provider failure, ambiguous recovery,
and integrity incident. Pre-mutation failures say prominently that no mutation
occurred.

Local results display:

```text
assurance: local/unisolated
production admissible: no (current policy requires an isolated builder)
```

RK has no generic `--force`, `--skip-verification`, `--retry-anyway`, or
equivalent bypass.

Low-level materialize, produce, accept, authority-mutate, inspect, and reconcile
operations are an internal provider interface over an admitted `plan_id`, not
the primary operator CLI.

Provider glue is responsible only for:

- provisioning a declared runner/toolchain;
- passing a semantic plan, registry checkpoint, and authenticated prerequisite
  claims/envelopes;
- giving one operation its fenced narrowly scoped principal/capability;
- retaining immutable outputs; and
- returning claims/envelopes and provider correlation evidence.

GitHub Actions glue may use OIDC, environments, immutable releases, and GitHub
artifact attestations. Another CI provider may use its own workload identity
and attester. Local execution may use Keybay or another local credential source
without placing credential names in `release.toml`.

Credential resolution is part of that glue contract, not adapter behavior. A
destination or transform adapter declares a typed credential need—its
authority class and exact destination—and never reads an environment
variable, dotfile, or ambient login itself. A credential broker in the
provider lane resolves each need from that environment's native mechanism: an
OIDC exchange or environment-scoped secret in CI, or a per-machine operator
mapping locally that names sources such as a keychain item or Keybay URI.
The mapping is keyed by authority class and destination namespace—an npm
scope, an Apple team, a tap repository—so distinct owners on one machine
resolve to distinct credentials, and a per-project credential is exactly as
narrow as its policy-bound destination.
Explicitly mapped environment variables are permitted but discouraged; silent
pickup of ambient credentials is forbidden. RK never prompts for a secret
value; when a destination has a native login flow, the diagnostic names it.
An unmapped need fails closed before any node runs, naming the authority
class, destination, and expected mapping location. The plan records only the
required authority class; no credential name or location ever enters
`release.toml` or `plan.json`.

The provider must not reinterpret the plan or inject repository-defined
commands.

Operator status projects registry and public facts rather than exposing the
receipt protocol:

```text
pub.dev/keybay_cli/0.2.0    verified
GitHub Release              draft exact; publication not started
macOS arm64                 notarized and accepted
Homebrew                    blocked on verified GitHub Release
Overall                     partial; safely resumable
```

## Rejected alternatives

### One publication row per artifact family

Rejected:

```toml
[[release.cli.publish]]
path = "packages/keybay_cli"
to = ["pub.dev"]

[[release.cli.publish]]
path = "packages/keybay_cli"
to = ["github-release", "homebrew"]
```

This repeats the path, can drift after a move, and requires authors to know the
planner's internal artifact partition. Explicit artifact families do have a
real benefit: they decouple product identity from destination when one host can
carry several distinct products. RK keeps that distinction in the typed plan.
Schema 1 omits it only because the closed Dart/channel matrix has one supported
product resolution per project row.

### Required `kind = "package" | "cli"`

Rejected for v1. A kind can make product intent explicit and becomes valuable
when, for example, one GitHub Release may host a CLI, desktop application, and
source bundle. The current closed manifest-plus-channel matrix has one meaning,
however, and a `kind` field does not select among multiple executables.

Reconsider a concrete product selector when one supported
manifest-plus-channel tuple has two legitimate generated graphs. Until then,
the planner records the derived kind without making the author repeat it.

### Manifest paths everywhere

Rejected as the default author model. Exact project directories are more
natural and allow omission at a repository-root project. Security comes from
exact-directory inspection, ambiguity failure, manifest hashing, and protected
identity policy—not from forcing every author to type `pubspec.yaml`.

An optional concrete manifest selector may be added only when a real hybrid
directory requires it.

### Release-level path defaults plus per-project overrides

Rejected. One field in one location is easier to understand than shorthand,
inheritance, and precedence rules. A one-project release still uses one
`[[project]]` row.

### Recursive workspace discovery

Rejected. It allows a new workspace member, example, fixture, benchmark, or
private package to silently enter release scope. Native dependency graphs may
order an explicit allowlist but never expand it.

### A general `requires` language

Rejected for v1. Package relationships belong to native dependency metadata,
and fixed channel relationships—such as Homebrew consuming verified GitHub
assets—belong to closed adapter semantics. A cross-unit prerequisite such as
Keybay CLI waiting for its exact core package is inspected as public dependency
state.

RK should add an explicit non-native claim dependency only after a concrete
case cannot be expressed safely through those two sources. It must not grow a
second dependency language preemptively.

### Hooks, plugins, and custom publishers

Rejected. They turn reviewed repository data into privileged execution and
make the release kernel as broad as an arbitrary CI workflow.

New ecosystems enter through reviewed, versioned, built-in adapters with closed
schemas and threat models.

### A signed release.toml instead of separate policy

Rejected. Committing an operator signature next to the repository
configuration does defeat an unauthorized edit, but it relocates the
operator statement rather than removing it, requires its own key regardless,
and authorizes whatever revision carries a valid signature: reverting the
file and its signature inside a large merge resurrects old authority at
release time. Preventing that replay requires an out-of-repo record of the
currently approved generation—which is what policy already is. The ergonomic
half of the idea survives as the approval workflow in the protected-policy
section; the storage half does not.

### GitHub Actions as the engine

Rejected. GitHub Actions is one execution provider. The plan, artifacts,
adapter logic, claims, envelopes, and registry protocol must remain usable
elsewhere.

### One universal byte-identity promise

Rejected. Ecosystems expose different publication primitives. Adapters must
state whether they prove byte-exact, content-exact, or digest-native identity.

## Rollout

### Phase 0: comparison and contract prototypes

Phase 0 decides whether RK should exist. It drafts enough exact contracts to
measure candidates and test security properties; it does not freeze schema 1,
select a production backend, or authorize production implementation.

#### Stage A: neutral outcomes and fixtures

- Approve the threat model, austere authoring boundary, no-hooks principle, and
  build-versus-adopt method as research constraints.
- Define observable pass predicates, evidence artifacts, and disqualifying
  results for R1–R8 without naming an RK data structure as the required
  mechanism.
- Share black-box source fixtures, expected artifact/public outcomes, authority
  constraints, recovery scenarios, and evidence predicates. No candidate must
  consume an RK plan, claim, or registry.
- Run the uniform screen and classify complete candidates, bounded benchmarks,
  and evidenced eliminations.
- The screen may consume Appendix A's pinned survey directly as elimination
  evidence; a candidate is prototyped only if the screen leaves it eligible
  after that evidence is applied. Current evidence supports screening out,
  with named reasons the screen may overturn: `dist` for a Dart fleet, because
  its only Dart-capable builder is experimental executable configuration and
  its remaining value—archives, manifest digests, formula generation—must be owned by
  the composition anyway; and Conveyor, because its unique value is cross-OS
  signing and notarization, exactly the authority a proprietary,
  source-unavailable binary cannot hold under the hard invariants, leaving no
  usable credential-free value. Recording these expectations before the screen
  runs preserves its honesty rather than replacing it: an elimination still
  requires the named evidence written down.

#### Stage B: candidate-specific prototypes

- Prototype only candidates still eligible to win and explicitly approved,
  time-boxed component/DX benchmarks.
- On current evidence the decisive Stage B comparison is expected to be the
  typed kernel internal to a centrally maintained controller versus RK as a
  generic product. Those two candidates share almost all implementation; the
  comparison must still charge productization—generic schema surface,
  extraction, documentation, second-ecosystem readiness—separately so the
  cheaper packaging can win on its own inventory.
- Require each candidate to map the neutral outcomes to its own mechanisms.
  Native provider CAS, an existing ledger, several stores, or a central
  controller may satisfy an outcome; their complete code, state, authority, and
  recovery cost is charged to that candidate.
- For the RK candidate only, draft and test the canonical semantic-plan and
  claim/envelope schemas, effective policy projection, Release Registry
  CAS/checkpoint protocol, fencing/revocation, materialization/handoff,
  destination recovery adapters, platform profiles, Homebrew contract,
  accepted-source boundary, and RK bootstrap/update path described by this RFC.
- For the RK candidate, also produce one choreography diagram per channel
  naming which principal creates and which consumes every registry record and
  claim, in order, plus the v1 GitHub principal-budget table required by the
  authority-boundary section. The capability families are specified
  individually; these two artifacts are the cheap instruments that surface any
  remaining inter-family gap before code exists.
- For every candidate, record the principal/capability mapping, exact material
  path, provider recovery behavior, intended authority, provider-enforced
  authority, and residual within-class ambient permission.
- Apply the whole-system inventory, uncertainty treatment, and stopping rule.
  RK-specific architecture work counts entirely against RK.

#### Stage C: survivor canary qualification

- Stage C is pre-production qualification of the surviving selection, not a
  comparison instrument. Run it after Stage B has narrowed the field so canary
  cost is spent on at most the finalists, and schedule the canary resources
  deliberately—a pub.dev canary package is permanent once published, and a
  canary tap, repository, and Apple submissions must stay separate from every
  consumer destination.
- For every candidate still eligible to win, use separately scoped canary
  identities and non-consumer destinations to exercise real GitHub
  draft/release, Homebrew tap, pub.dev canary-package, and Apple submission
  semantics where no sandbox exists.
- Distinguish configuration/permission evidence, permission-negative probes,
  deterministic client-boundary fault injection, and observed provider
  behavior. Negative probes do not prove the absence of provider or sandbox
  vulnerabilities.
- Inject controllable failures for stale restore, split-brain/CAS conflict,
  policy revocation, capability replay, upload interruption, lost response,
  notary timeout, draft collision, tap concurrency, lost evidence envelope, and
  rerun. Provider-internal failures that cannot be injected remain explicit
  residual risk and receive no unsupported safety credit.
- A safety-critical behavior with neither an enforceable control nor an
  observable reconciliation oracle fails qualification.
- Publish the complete whole-system inventory, uncertainty ranges,
  hard-invariant evidence, candidate-specific prototype cost, and
  stopping-rule result.

If an existing composition wins, adopt it and stop RK. If a useful typed kernel
does not earn generic product status, keep it internal to the selected
controller. Phases 1–2 occur only if Phase 0 selects RK and project governance
separately authorizes non-production implementation. Phases 3–5 additionally
require the production migration/schema gate below.

No Keybay, Fleury, Dune, or other consumer-production credential is used in this
phase. Stage C uses only separately scoped canary credentials and destinations.

### Phase 1: planner and dry-run engine

- Implement strict TOML parsing with unknown-field rejection.
- Resolve exact project directories and Dart manifests offline.
- Parse tags and validate native versions.
- Produce deterministic semantic plans and cross-implementation vectors.
- Implement the minimum Release Registry protocol selected by a Phase 1
  non-production architecture decision and later qualified by the production
  gate; do not assume a new hosted service.
- Implement credential-free dependency/toolchain materialization into CAS and
  network-disabled builds.
- Add adversarial fixtures for traversal, symlink escape, duplicate paths,
  ambiguous manifests, workspace expansion, destination conflicts, and
  dependency escape, plus claim re-signing, registry rollback, stale fences,
  and implementation upgrades during partial release.
- Implement credential-free artifact production and candidate-acceptance
  workloads. Dry-run evidence is never production admission.

### Phase 2: shadow Keybay

- Encode Keybay's protected identities outside the repository request.
- Generate an RK plan beside the existing workflows for the same signed tag.
- Compare node inventory, hashes, platform contracts, authority separation,
  and read-only public verification. This proves observational equivalence
  only; it does not prove mutation or recovery.
- Keep `.github/workflows/publish.yml` and `release_cli.yml` authoritative until
  the shadow plan proves equivalence.
- Repeat Phase 0's canary qualification with the selected, pinned RK candidate
  and current provider versions. Canary authority can never mutate Keybay's
  production coordinates. This is migration regression evidence, not the first
  proof of provider behavior.
- Repeat deterministic fault injection at every state boundary, adding
  concurrent accepted candidates, policy revocation, partial publication, and
  resume to the Phase 0 provider cases.
- Require end-to-end canary claims/receipts for absent-to-verified transitions and
  recovery before migration. A provider behavior that cannot be tested is an
  explicit unresolved production blocker, not something read-only shadowing
  proves.
- Do not retain both authorities after migration; two release engines create
  ambiguous operational policy.

### Phase 3: migrate Keybay

- Replace bespoke orchestration with thin provider glue invoking the pinned RK
  engine.
- Replace checkout-hosted tag signing/push with the pinned external authorizer
  plus separate offline signer and create-only tag pusher before any RK
  production release.
- Before the first RK-managed tap update, perform the one-time authenticated
  `legacy-homebrew-base` ceremony against the exact then-current formula
  commit/blob.
- Preserve consumer verification or publish an explicit signer-identity
  migration.
- Retain the old release runbook as historical evidence, not active authority.

### Phase 4: Fleury pilot

- First bootstrap each new package outside RK through pub.dev's required
  interactive first-version ceremony, recording the exact public coordinate,
  contents, immutable source, and authorized uploader; do not pretend OIDC can
  create a package.
- Then begin RK-managed publication with the first subsequent version.
- Prove multi-package allowlisting and dependency ordering.
- Add native `fleury` binaries only after lock/reproducibility and product
  distribution policy are accepted.

### Phase 5: Dune admission

- Do not weaken RK to accommodate the present mutable path graph.
- Admit Dune only after its source closure, lockfile, native bundle, and
  platform acceptance satisfy the criteria above.

### Later ecosystems

The engine's internal decomposition keeps new targets cheap without opening
the kernel. Modules are closed, versioned, and compiled in—never runtime
plugins—along five independent axes:

1. native ecosystem adapters that read manifests, resolve closure, and run
   fixed validation: `dart-pub/v1` first; Cargo, npm, RubyGems, or Python
   later;
2. build adapters that produce candidate outputs for a versioned platform
   profile: `dart-cli/v1` first;
3. transform adapters that sign, notarize, archive, and checksum. They key on
   artifact shape—Mach-O binaries, archive layouts—not on source ecosystem: a
   future Rust or Go binary reuses the macOS signing and notarization modules
   unchanged;
4. destination adapters that implement one shared publisher interface—declare
   an identity mode and a frozen version grammar, inspect a coordinate as
   absent/exact/conflict, stage and publish accepted content, reconcile hosted
   state, and recover a correlated attempt—for pub.dev, GitHub Releases, and
   Homebrew first, and registries such as crates.io, npm, PyPI, RubyGems, or
   an OCI registry later; and
5. execution-provider glue and Release Registry backends, orthogonal to all of
   the above.

The planner's closed compatibility matrix is where an ecosystem meets a
channel; the modules behind a cell are reused across cells. A later RubyGems
CLI target, for example, is one new native adapter plus one new destination
adapter consuming the same kernel, transforms, GitHub Releases adapter, and
Homebrew adapter.

Add one closed adapter at a time. A new adapter proposal must document:

- native project resolution;
- canonical package/artifact identity;
- dependency and workspace authorization behavior;
- credential-free production;
- exact publisher interface;
- short-lived authority options;
- retry and conflict semantics;
- public verification;
- platform/build isolation; and
- known gaps where the ecosystem cannot preserve an RK invariant.

Cargo's combined package/verify/upload flow, npm lifecycle scripts, Python
dynamic versions and wheel matrices, and OCI digest/tag behavior must each be
treated as distinct threat models.

## Open questions and required decisions

These questions do not justify adding generic configuration:

1. What is the protected operator-policy format, bootstrap trust,
   delivery mechanism, effective semantic projection, and explicit revocation
   vocabulary locally and in each CI provider?
2. Which human release-authorization mechanisms and identities may issue the
   authenticated release-invocation claim?
3. Which standard canonical JSON, claim schemas, DSSE/in-toto profiles,
   identity backends, issuer rules, and transparency evidence authenticate
   gating claims without exposing claim authority to untrusted workloads?
4. Which existing or minimal backend satisfies the logical Release Registry's
   linearizable CAS, scoped writers, checkpoint, monotonic-client, backup, and
   anti-rollback recovery contract locally and in each CI provider?
5. Which content-addressed staging implementations satisfy the portable
   cross-stage handoff, replication, retention, and exact-recovery contract?
6. What exact adoption, retry, deletion, expiry, and compare-and-swap semantics
   apply to GitHub drafts and Apple notarization submissions?
7. How does RK consume an accepted-source CI result portably without becoming
   a test-command DSL?
8. Does the Dart package adapter standardize on pinned hidden archive flags, a
   documented future Pub interface, or content-exact sterile publication?
9. What exact ABI, minimum-OS/libc, CPU baseline, toolchain, asset naming, and
   archive-root contract defines each versioned binary platform profile?
10. Which parts of Keybay's project-specific archive inventory belong in a
   reusable Dart CLI adapter versus normal product CI?
11. What is the smallest non-executable schema for unavoidable Homebrew metadata
   such as Keybay's Linux `libsecret` dependency, installed support files, and
   formula smoke test?
12. Which Dart lock/content identities, SDK/images, mirrors, and system-library
    inputs are sufficient for sterile materialization and network-disabled
    builds?
13. How are trusted time or monotonic sequence, single-use fencing, provider
    ambient privilege, and revocation races represented and qualified?
14. How is an identical semantic plan re-admitted under a patched
    policy-authorized implementation without invalidating prior selected
    outputs or permitting Plan B?
15. How are RK binaries, adapters, policy roots, and Release Registry clients
    bootstrapped, upgraded, revoked, and recovered? This includes the
    self-hosting bootstrap: what releases RK before RK can release itself.
    Decided 2026-07-27: RK is implemented in Dart.
16. Is RK developed in this repository during the Keybay shadow phase or moved
   to its own repository before implementation? Decided 2026-07-27: RK lives
   in its own standalone repository at `~/Coding/release-kit` from the start;
   Keybay remains the first shadow and migration consumer.
17. Is `RK` the final product name?
18. What is the source of GitHub Release title, body, and prerelease
    metadata, and does GitHub permit editing the body of an already immutable
    release?
19. Should `tag` be optional for single-project release units? Decided
    2026-07-27: yes, in schema 1, defaulting to `<package>-v{version}`
    derived from the native package identity; a multi-project unit still
    declares `tag` explicitly. Keybay core migrates its public namespace
    from `v{version}` to the derived `keybay-v{version}` at RK migration.

## Phase 0 entry authorization

This RFC may be accepted as authorization for comparison and contract
prototyping when:

- the explicit threat model, roots of trust, residual risks, and the
  Stage A/B/C comparison structure are accepted as research constraints;
- the exact-project, native-facts, austere path/publish/platform intent model
  is approved as a candidate author boundary—not a frozen schema;
- the no-hooks/no-plugins/no-recursive-discovery/no-bypass boundary is
  approved as a hard comparison invariant;
- protected policy is acknowledged as conjunctive authorization rather than
  repository configuration;
- the uniform candidate screen, whole-system inventory, uncertainty treatment,
  material-difference rule, and fail-closed stopping rule are approved;
- neutral black-box outcomes and fixtures will not require candidates to share
  a prepaid RK implementation; and
- production credentials, production migration, follow-on implementation, and
  schema 1 remain blocked pending the separate gate below.

Entry authorization starts Phase 0; it does not assert that the R1–R8
predicates, prototypes, canary evidence, or final selection already exist.

## Phase 0 completion and final-selection gate

Phase 0 is complete only when:

- every R1–R8 requirement has a mechanism-neutral observable predicate,
  evidence artifact, and disqualifying result;
- every surveyed candidate is uniformly classified as a potential complete
  composition, bounded benchmark, or evidenced elimination;
- candidate-specific prototypes use only shared black-box fixtures and charge
  all candidate-specific plan, state, glue, authority, recovery, and bootstrap
  machinery to that candidate;
- each surviving complete composition passes the hard invariants for
  non-executable privileged input, mutually exclusive authority classes, exact
  accepted-output promotion, source-tag and immutable-destination concurrency,
  material verification, safe partial recovery, revocation, and non-rollback
  state;
- each survivor has real canary evidence for every safety-critical provider
  behavior, or an enforceable/observable alternative oracle; unsupported
  provider claims receive no credit;
- the whole-system inventory, fixed/marginal cost ranges, residual risks,
  uncertainty, and operator recovery decisions are published; and
- the stopping rule selects an existing composition, RK, or no candidate
  without treating sunk work or an incomparable trade-off as an RK win.

If an existing composition wins, its own reviewed production plan follows and
the RK-specific gate below is inapplicable. If no candidate wins, production
migration remains blocked. Selecting RK does not itself authorize follow-on
work; it makes a separate non-production Phase 1–2 implementation decision
eligible.

## Production migration and schema-freeze gate

Production credentials, destination mutation, Keybay migration, and schema
freeze are authorized only after Phase 0 selects RK, the required Phase 1–2
evidence exists, and all of these are resolved:

- canonical semantic-plan identity is independent of implementation identity,
  with cross-implementation test vectors and policy-authorized
  admission/re-admission;
- one concrete Release Registry implementation proves linearizable coordinate
  admission, immutable-destination reservation, and selection CAS,
  capability-scoped writers, attempt dispositions, non-equivocating
  authenticated checkpoints, and non-rollback disaster recovery in
  non-production qualification;
- source-tag and immutable-destination keys use externally canonical
  provider namespaces, exclude internal unit/adapter versions from uniqueness,
  and pass alias/collision vectors across contract upgrades;
- routine policy evolution, explicit revocation, admission epochs, fenced
  single-use operation capabilities, and in-flight provider reconciliation are
  specified and fault-tested;
- claim IDs, envelope IDs, issuer verification, authority results, output
  acceptance, public verification, and completion schemas are canonical and
  portable;
- mutually exclusive authority classes have non-impersonable
  provider/gateway-enforced separation; residual ambient permission stays
  within one class and every such permission, lifetime, revocation latency, and
  mitigation is recorded;
- immutable source, dependency, and independently materialized SDK/toolchain,
  image, and system-library inputs are verified into CAS before
  network-disabled builds; non-addressable hosted runner components have an
  explicit provider identity, inventory, residual-trust classification, and
  policy decision rather than a fabricated digest;
- a canonical repository/tag ref commits to only one unit, version, immutable
  tag object, and semantic plan even after hosted-ref deletion, while exact
  selected bytes may be recovered but never rebuilt or substituted;
- provider staging recovery fails closed under every crash-window ambiguity;
- accepted-source evidence cannot be minted by candidate-controlled workflow
  code and is consumed without making GitHub Actions part of the engine;
- the Dart package adapter has a feature-tested, pinned byte-exact or honestly
  content-exact publisher/reconciliation contract and does not depend silently
  on an unsupported SDK behavior;
- RK's own binaries, adapters, policy roots, and registry clients have an
  authenticated bootstrap, update, revocation, and recovery path;
- schema 1 freezes the one-binary-bearing-project rule, exact versioned platform
  profiles, public asset/archive compatibility, the smallest unavoidable
  typed Homebrew metadata without commands or templates, and the stable typed
  diagnostic-code vocabulary that consumers see in CI logs;
- Keybay tag signing no longer executes repository-controlled code with signing
  or tag-mutation authority; and
- Keybay, Fleury, and Dune case studies remain accurate; reusable architecture
  gaps are resolved without an arbitrary escape hatch, while project-readiness
  gaps continue to reject only the affected project until its phase-specific
  admission criteria are met.

## Appendix A: reproducible evidence snapshot

The repository examples were inspected on 2026-07-26 at these Git commits:

| Project | Repository snapshot | Scope note |
|---|---|---|
| Keybay | `a6218704586384fe79246746c14341a6b83bfae2` | Tracked release files used by this RFC. The RFC itself was an untracked draft during inspection. |
| Fleury | `fadc5c9dde906aee4901ef8fce94077080f577d8` | Source of the 16-manifest inventory and five explicit candidate projects. |
| Dune CLI | `8e74de02bea62033446c86c6fffb372f5c14aeae` | Source of the tracked manifest/path graph. Ignored lock/bundle outputs were observed locally only and are deliberately not treated as commit evidence. |

The five proposed Fleury package URLs returned not-found on 2026-07-26. That
availability fact can change; the bootstrap gate always rechecks public state.

The peer survey cutoff was 2026-07-26 in America/Toronto. It used released refs
and peeled source commits for open-source tools. Conveyor's
implementation is proprietary, so its row pins versioned documentation and
records that source unavailability instead of implying a source review. No row
relies on a mutable branch:

| Tool | Surveyed release/evidence version | Source/evidence pin |
|---|---|---|
| dist/cargo-dist | [`v0.32.0`](https://github.com/axodotdev/cargo-dist/releases/tag/v0.32.0) | [`6886366640dd4da83d33ba55cc04aa58423cbad2`](https://github.com/axodotdev/cargo-dist/commit/6886366640dd4da83d33ba55cc04aa58423cbad2) |
| Conveyor | [Documentation `22.1`](https://conveyor.hydraulic.dev/22.1/) | Proprietary implementation; [versioned documentation](https://conveyor.hydraulic.dev/22.1/), [EULA](https://www.hydraulic.dev/eula.html), and [vendor pricing/source-access statement](https://www.hydraulic.dev/pricing.html) |
| Fastforge | [`0.6.10`](https://pub.dev/packages/fastforge/versions/0.6.10), tag [`fastforge-v0.6.10`](https://github.com/fastforgedev/fastforge/tree/fastforge-v0.6.10) | [`62cd11097a95b45b17bf17c91ef48c9790693a90`](https://github.com/fastforgedev/fastforge/commit/62cd11097a95b45b17bf17c91ef48c9790693a90) |
| GoReleaser | [`v2.17.1`](https://github.com/goreleaser/goreleaser/releases/tag/v2.17.1) | [`83f4c19a5c5c0b9efef6bf2aedc6805bbcb9dfe2`](https://github.com/goreleaser/goreleaser/commit/83f4c19a5c5c0b9efef6bf2aedc6805bbcb9dfe2) |
| JReleaser | [`v1.25.0`](https://github.com/jreleaser/jreleaser/releases/tag/v1.25.0) | [`76e2acc3a33b9e72f8c168799f27bb753bd54e6c`](https://github.com/jreleaser/jreleaser/commit/76e2acc3a33b9e72f8c168799f27bb753bd54e6c) |
| Melos | [`8.2.2`](https://pub.dev/packages/melos/versions/8.2.2), tag `melos-v8.2.2` | [`c09d24d2ab0531ee105aa7ddc78a5b74bc70855d`](https://github.com/invertase/melos/commit/c09d24d2ab0531ee105aa7ddc78a5b74bc70855d) |
| Release Please | [`v17.10.4`](https://github.com/googleapis/release-please/releases/tag/v17.10.4) | [`bfcc6145ed27118d77b63ae46ae8fa059d8f985b`](https://github.com/googleapis/release-please/commit/bfcc6145ed27118d77b63ae46ae8fa059d8f985b) |
| Changesets | [`@changesets/cli@2.31.1`](https://github.com/changesets/changesets/releases/tag/%40changesets%2Fcli%402.31.1) | [`a897bb8ac115fa65343a8bfe53654040c1542a80`](https://github.com/changesets/changesets/commit/a897bb8ac115fa65343a8bfe53654040c1542a80) |
| release-plz | [`release-plz-v0.3.160`](https://github.com/release-plz/release-plz/releases/tag/release-plz-v0.3.160) | [`7e38e7a93dff31bbf6312400f79b9de36e8d3834`](https://github.com/release-plz/release-plz/commit/7e38e7a93dff31bbf6312400f79b9de36e8d3834) |
| semantic-release | [`v25.0.8`](https://github.com/semantic-release/semantic-release/releases/tag/v25.0.8) | [`1bfdc5297603270e04010a1fc0bb2e51a00c7947`](https://github.com/semantic-release/semantic-release/commit/1bfdc5297603270e04010a1fc0bb2e51a00c7947) |

JReleaser's separately maintained guide was pinned at
[`62b00a164a2d8fff410274854b9f163e5c92918f`](https://github.com/jreleaser/jreleaser.github.io/commit/62b00a164a2d8fff410274854b9f163e5c92918f).
A refreshed build-versus-adopt gate must record new source/documentation pins
rather than silently inheriting updated “latest” pages.

Before the Conveyor spike, Phase 0 must additionally record the exact binary
download URL, SHA-256 digest, and accepted license text. Versioned
documentation is evidence about claimed behavior, not proof that proprietary
executable bytes are immutable.

### Requirement matrix

`Y` means a closed built-in contract meets the requirement; `P` means
meaningful adjacent support but a material gap; `N` means absent or dependent
on executable extension/custom glue. This assesses each no-cost/open-source
offering usable under the project's no-paid-dependency constraint. Conveyor is
free for open-source projects but proprietary; the other rows assess their
open-source editions. It is not a quality judgment outside this threat model.

| Tool | R1 | R2 | R3 | R4 | R5 | R6 | R7 | R8 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| dist | P | N | P | P | P | N | P | N |
| Conveyor | P | P | P | Y | N | P | P | N |
| Fastforge | P | N | P | Y | N | N | N | N |
| GoReleaser OSS | P | P | P | Y | N | N | N | N |
| JReleaser | Y | P | P | Y | N | N | P | N |
| Melos | P | N | N | Y | N | N | P | N |
| Release Please | N | N | N | Y | Y | P | N | Y |
| Changesets | P | N | N | Y | P | P | P | N |
| release-plz | P | N | N | Y | Y | P | P | Y |
| semantic-release | P | N | N | Y | N | N | N | N |

- R1: language-native registry publication plus cross-platform application
  binaries. Homebrew formulas or npm binary installers alone do not count as
  the project's native language package.
- R2: macOS signing and notarization with isolated signer authority.
- R3: promotion of accepted immutable artifact nodes.
- R4: the same provider-neutral engine and evidence formats locally, on GitHub
  Actions, and in a second independent CI conformance canary; only one hosted CI
  integration must be maintained for production in v1.
- R5: small, non-executable repository configuration.
- R6: fail-closed project, destination, identity, field, and inference handling.
- R7: evidenced safe resumption after partial publication.
- R8: a closed kernel without general hooks or arbitrary plugins.

Non-obvious cells are grounded in pinned primary sources:

- dist has distinct phases and manifests, but its pinned
  [security scope](https://github.com/axodotdev/cargo-dist/blob/6886366640dd4da83d33ba55cc04aa58423cbad2/book/src/supplychain-security/index.md)
  lists macOS signing as forthcoming, its
  [configuration](https://github.com/axodotdev/cargo-dist/blob/6886366640dd4da83d33ba55cc04aa58423cbad2/book/src/reference/config.md)
  supports only GitHub-generated CI and exposes commands/custom jobs.
- Conveyor can package desktop/CLI applications for Windows, macOS, and Linux,
  and its
  [signing documentation](https://conveyor.hydraulic.dev/22.1/faq/signing-and-certificates/)
  says it can sign and notarize macOS applications from other operating
  systems. That is valuable portability. Its
  [HOCON extensions](https://conveyor.hydraulic.dev/22.1/configs/hocon/#including-the-output-of-external-commands)
  can execute external commands, and its
  [macOS contract](https://conveyor.hydraulic.dev/22.1/configs/mac/#appmacsignscriptsapp)
  allows custom signing scripts, while its
  [notarization contract](https://conveyor.hydraulic.dev/22.1/configs/keys-and-certificates/#via-custom-notarization-script)
  allows a custom notarization script. Its documented
  [in-CI release path](https://conveyor.hydraulic.dev/22.1/continuous-integration/#running-conveyor-from-within-github-actions)
  can give one Conveyor invocation signing keys and Apple notarization
  credentials while `make copied-site` also performs
  [publication](https://conveyor.hydraulic.dev/22.1/serving/uploading/). Its
  normal task graph, cache, and targeted rerun controls are useful adjacent
  validation/recovery behavior, but they are not authenticated admission or
  resumption receipts. Source access is a paid
  [vendor offering](https://www.hydraulic.dev/pricing.html), so it cannot be an
  independently auditable privileged authority under this model.
- Fastforge 0.6.10 is MIT-licensed and supports many Flutter package and
  publishing formats in its pinned
  [README](https://github.com/fastforgedev/fastforge/blob/62cd11097a95b45b17bf17c91ef48c9790693a90/README.md).
  Its released Dart implementation has arbitrary
  [pre/post hooks](https://github.com/fastforgedev/fastforge/blob/62cd11097a95b45b17bf17c91ef48c9790693a90/packages/flutter_app_packager/lib/src/flutter_app_packager.dart)
  and its
  [release operation](https://github.com/fastforgedev/fastforge/blob/62cd11097a95b45b17bf17c91ef48c9790693a90/packages/unified_distributor/lib/src/unified_distributor.dart#L327-L403)
  packages and publishes in one process. It has useful signing pieces but no
  closed isolated notarization or accepted-artifact promotion lane. Separate
  package/publish commands and a portable Dart CLI are useful adjacent support,
  but there is no selection ledger or digest reconciliation. The parallel Rust
  rewrite is explicitly unreleased and is not credited to the surveyed Dart
  release.
- GoReleaser OSS genuinely supports binary
  [notarization](https://github.com/goreleaser/goreleaser/blob/83f4c19a5c5c0b9efef6bf2aedc6805bbcb9dfe2/www/content/customization/sign/notarize.md)
  and an
  [artifact ledger](https://github.com/goreleaser/goreleaser/blob/83f4c19a5c5c0b9efef6bf2aedc6805bbcb9dfe2/www/content/customization/general/artifacts.md),
  but not Keybay's isolated authority; its
  [split/merge continuation](https://github.com/goreleaser/goreleaser/blob/83f4c19a5c5c0b9efef6bf2aedc6805bbcb9dfe2/www/content/customization/general/partial.md)
  is Pro-only and its hooks remain executable.
- JReleaser supports staged
  [workflow resumption](https://github.com/jreleaser/jreleaser.github.io/blob/62b00a164a2d8fff410274854b9f163e5c92918f/docs/modules/concepts/pages/workflow.adoc)
  and binary distributions, but not authenticated accepted-artifact recovery;
  it also has
  [script hooks](https://github.com/jreleaser/jreleaser.github.io/blob/62b00a164a2d8fff410274854b9f163e5c92918f/docs/modules/reference/pages/hooks/script.adoc).
- Melos has excellent dry-run-first Dart
  [publishing](https://github.com/invertase/melos/blob/c09d24d2ab0531ee105aa7ddc78a5b74bc70855d/docs/commands/publish.mdx),
  but also executable
  [workspace scripts](https://github.com/invertase/melos/blob/c09d24d2ab0531ee105aa7ddc78a5b74bc70855d/docs/configuration/scripts.mdx)
  and no binary/signing kernel.
- Release Please explicitly
  [does not publish packages or applications](https://github.com/googleapis/release-please/blob/bfcc6145ed27118d77b63ae46ae8fa059d8f985b/docs/design.md);
  its comparatively closed
  [schema](https://github.com/googleapis/release-please/blob/bfcc6145ed27118d77b63ae46ae8fa059d8f985b/schemas/config.json)
  is still a useful DX reference.
- Changesets' useful retry behavior checks npm versions before `npm publish`,
  but its
  [configuration](https://github.com/changesets/changesets/blob/a897bb8ac115fa65343a8bfe53654040c1542a80/docs/config-file-options.md)
  can load repository JavaScript modules and does not reconcile content.
- release-plz
  [publishes Cargo crates and forge releases](https://github.com/release-plz/release-plz/blob/7e38e7a93dff31bbf6312400f79b9de36e8d3834/website/docs/usage/release.md)
  portably, but does not produce cross-platform binaries or reconcile existing
  public contents.
- semantic-release's ecosystem breadth comes from its dynamic
  [plugin loader](https://github.com/semantic-release/semantic-release/blob/1bfdc5297603270e04010a1fc0bb2e51a00c7947/lib/plugins/index.js),
  which is intentionally outside RK's closed privileged kernel.

The central native-tool controller remains a serious alternative precisely
because it can implement Keybay's required boundaries without pretending a
general peer removes them. The Phase 0 screen and spikes must compare that
alternative, the constrained existing-tool compositions, and RK using the same
pass/fail tests and whole-system scorecard.

## Appendix B: revision history

- Revision 10 (2026-07-28): superseded as build authority by RFC 0002 after
  a first-principles reset; retained as the threat catalog and assurance
  ladder. The minimal design removes the Release Registry, protected-policy
  document, claims, and capability machinery in favor of reality inspection,
  draft staging, provider-side enforcement, and native-tool auth deferral.
- Revision 9 (2026-07-27): made policy approved rather than hand-authored—a
  release.toml-driven approval command displays the effective delta, prompts
  for operator-only facts, and signs the next generation—and recorded the
  rejection of an in-repo signed release.toml, whose valid signature would
  travel with reverted revisions.
- Revision 8 (2026-07-27): stated the registry's contained blast
  radius—write access can halt or delay but cannot forge authority—and
  tiered registry complexity so the invariant floor is a minimal CAS store
  and every further assurance measure must be priced by the scorecard.
- Revision 7 (2026-07-27): decided question 19—`tag` is optional for a
  single-project unit, deriving `<package>-v{version}` from native identity,
  and required for multi-project units; updated the Keybay, Fleury, and Dune
  examples and Keybay's policy namespaces (core migrates to
  `keybay-v{version}`); and keyed credential-broker mappings by authority
  class and destination namespace.
- Revision 6 (2026-07-27): stated that one registry serves one operator's
  fleet with no central service; specified typed credential needs resolved by
  a provider-lane broker with no ambient pickup, no value prompting, and
  fail-closed unmapped needs; and deferred an optional single-project tag
  default to a future schema (question 19).
- Revision 5 (2026-07-27): named the five closed module axes and the shared
  destination-adapter interface so new release targets reuse the kernel and
  transform modules, and specified that the portability canary is a plain
  self-hosted runner rather than a second hosted CI brand.
- Revision 4 (2026-07-27): recorded Phase 0 entry authorization and the first
  resolved decisions—Dart implementation and a standalone
  `~/Coding/release-kit` incubation repository (questions 15 and 16)—without
  changing any contract.
- Revision 3 (2026-07-27): named the solo-operator trust anchor and made every
  separation predicate decidable relative to the named roots; defined concrete
  provider-enforced separation for the v1 GitHub provider and required a
  principal-budget table before Phase 1; named a dedicated Git repository as
  the leading Release Registry candidate, SQLite for the local lane, and a
  conditional-write table as fallback; allowed the Stage A screen to consume
  Appendix A directly and recorded the expected `dist`/Conveyor eliminations;
  identified kernel-versus-product as the expected decisive Stage B
  comparison; reframed Stage C as pre-production qualification; named
  RFC 8785 as the default canonical-JSON profile; added the GitHub Release
  title/body/prerelease metadata question, per-channel choreography diagrams,
  the self-hosting bootstrap question, and frozen diagnostic codes to the
  schema gate.
- Revisions 1–2 predate this history.
