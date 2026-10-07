# Dependency-aware repository staging

> Archived. Superseded by [practical staging](../practical-staging.md), which
> replaced rk's own dependency resolution and archive staging with Pub.

Status: implemented. This document maps the design to its production owners and
regression tests. The [repository release contract](repository-release-plan.md)
defines command behavior; the [native qualification record](dependency-staging-native-proof.md)
separates fixture, SDK and actual Fleury evidence from live-publication claims.

The implementation was developed against RK main
`6e7bb165c8027d8fc5e5293b45432850cf3229f8`. Earlier proposals and delivery progress
are preserved in Git history; they do not override the contract below.

## Outcome and scope

`rk stage` privately prepares every configured release unit. A consumer can use
compatible, verified archives from another unit before that provider is public.
`rk release` finishes preparation for the entire selected scope, asks once, and
publishes in runtime dependency order. Package versions remain independent.

For example, unpublished `fleury_mcp 0.1.0` may depend on `fleury 0.2.0`. If MCP
instead requires published Fleury `0.1.0`, bumping the local Fleury to `0.2.0`
does not rewrite MCP's manifest, force its version to change, or substitute an
incompatible dependency. Published manifests remain immutable.

The existing schema-2 `release.toml` remains the configuration. There is no new
release group, shared version, `--all` option or automatic manifest edit.

| Command | Behavior |
| --- | --- |
| `rk plan [unit]` | Source-only candidate topology; native resolution is explicitly pending |
| `rk stage` | Prepare all configured units in dependency order; no publication |
| `rk stage <unit>` | Prepare exactly the named unit; reuse a current verified sibling stage or resolve hosted dependencies without building siblings |
| `rk release [unit]` | Prepare the selected scope, review once, then publish within that scope |
| `rk status [unit]` | Observe destinations and local stage evidence without solving, adopting, producing or mutating stages |

## Architecture and ownership

Core owns scope, scheduling, persistence, stage identity, authorization and
retry/stop behavior. Native adapters own requirements, version/source semantics,
transitive resolution, preparation environments and public consumer checks.
Target modules retain their destination and credential behavior.

| Owner | Responsibility |
| --- | --- |
| `engine/native_dependencies.dart`, `native_stage_context.dart` | Opaque package identities and context/slot bindings; no shared semver rules or global name-to-version map |
| `engine/native_stage_discovery.dart`, `native_stage_authorization.dart`, `native_publication.dart` | Typed discovery, frozen authorization and publication handoffs |
| `engine/repository_stage_preparation.dart` | Restore first; discover fresh selected contexts; order units and bind completed providers before consumer production |
| `engine/dependency_graph.dart`, `release_dependencies.dart` | Deterministic phase-specific ordering, cycle and unsupported unit-grouping diagnostics |
| `engine/stage_intent.dart`, `stage_lookup.dart`, `stage_restoration.dart` | Locate and authorize frozen choices before fresh resolution; adopt transactionally |
| `engine/stage_dependencies.dart`, `stage_proof.dart`, `stage_source.dart` | Exact imported archives, portable proof closure and source/producer evidence |
| `commands/release.dart`, `release_stage_coordinator.dart` | Complete selected private work before publication review |
| `commands/repository_publication.dart`, `release_publication_coordinator.dart` | Runtime target graph, aggregate immutable consent and checks before each public action |
| `native/dart/` | Dart manifest/lock policy, native discovery/replay, frozen authorization and fresh public consumer proof |
| `targets/pub_dev/package_stage.dart`, `binary_chain.dart` | Shared Dart preparation for native package archives and executable builds |

Bindings belong to a consuming native context and occurrence (slot). Another
adapter may install multiple versions or interpret peer, optional and platform
dependencies differently. Core schedules only the edges that adapter projects.
Non-Dart fake-adapter tests exercise opaque constraints and multiple slots.

Pub is the first concrete native dependency adapter. Dart binary builds reuse its
preparation. Git tags, GitHub Releases and Homebrew keep their existing target
lifecycle edges and consume prepared artifacts. npm and RubyGems can implement
the same handoffs without introducing a generic solver or plugin registry.

## Fresh selection and frozen reuse

An authorized saved stage takes precedence over fresh candidate selection.
Changing between named/bare or stage/release commands does not change its choices.
A consumer already staged with a hosted version keeps it even if a compatible
local provider becomes eligible later; RK does not claim that newer combination
was tested.

For a fresh solve:

1. Match ecosystem, credential-free canonical source and package identity.
2. Prefer a compatible configured provider eligible for the selected scope.
   A named command can also use an already completed, current verified sibling.
3. Otherwise resolve the original requirement from its declared public source.
   Merely having a local sibling does not make it mandatory or expand scope.
4. Validate the whole graph natively, including transitive requirements revealed
   by hosted packages. A selected provider that conflicts with that graph refuses;
   it is not silently replaced with an older package.

An exact already-public package is a hosted dependency input, not an unpublished
provider candidate. Reading its manifest does not schedule publication.

Discovery completes before fresh producers run. Preparation and publication use
separate projections of the same native facts: dev/build inputs need not be
public runtime dependencies. Each unit still executes as a complete unit. An
acyclic package graph requiring units to interleave (U=[A,C], V=[B], C→B→A)
gets a regrouping diagnostic rather than a false package-cycle report.

## Dart preparation

`DartStageSource` reads configured roots, candidates and operation policy from the
selected immutable source. Git-bound source comes from the selected commit;
unbound source retains single-invocation authority. Caller-supplied restored
manifests cannot authorize themselves.

Hosted metadata discovery delegates solving to Pub. A shadow source restricts an
eligible selected candidate to its configured version and supplies manifest-only
placeholder archives. These placeholders never become release artifacts or
compiler inputs. Actual external archives must match their native digest and
full discovered manifest before replay.

Replay preloads exact archives into an isolated native cache under their original
hosted identities, resolves offline against unchanged manifests, and compares the
complete graph (sources, versions, hashes and dependency edges). No arbitrary
workspace path can stand in for an imported runtime archive. Package and binary
producers share this mechanism.

| Input | Policy |
| --- | --- |
| Pub archive root | Detached original manifest, no inherited lockfile |
| Binary root | Committed applicable lockfile, including workspace root locks; native compatible-lock behavior |
| Discovery refinement | Start each pass from the original effective lock, preserving real external hash authority |
| Development-only helper | Snapshot-bound source and original constraints verified before the declared managed source mapping |
| Runtime dependency | Exact selected package archive; unrelated path/Git substitutions refused |
| Explicit hosted source | Preserve native registry identity and SDK syntax constraints |

A development helper binds its path, full manifest and source receipt. It may be
versionless (native effective version `0.0.0`); publishing still requires an
explicit version. Its own dev dependencies are ignored under native semantics.
Native discovery checks every original incoming requirement and root back-edge
before any helper override. Replay allows only the declared source mapping and
checks the exact helper/package locations before and after operations.

If transitive discovery makes a helper runtime-reachable, RK removes helper
eligibility and resolves again from the original lock using archive/hosted policy.
This promotion is monotonic and bounded: it does not search older bridge versions
solely to regain source-helper eligibility. A refusal reports this limitation and
the runtime path, rather than claiming no native solution could exist.

Native archives use a format-aware validated reader. Extraction rejects escaping
paths/links, malformed metadata, duplicate/conflicting paths and unsupported file
kinds, preserves relevant modes, and enforces resource limits. Required files
excluded from an archive cannot leak in from the checkout.

## Stage identity, imports and recovery

A cross-unit consumer copies the exact provider archive and portable proof into
its own declared input area. The binding includes provider coordinate, ownership,
producer contract, plan/receipt identity and archive digest. These cross-unit
bindings are fixed before the consumer stage identity is finalized.

Same-unit handoff instead uses producer edges and the completed provider output
receipt; putting a not-yet-produced hash in the shared stage identity would create
a cycle. Publication always requires the completed unit stage.

Portable proof is a bounded, deduplicated closure keyed by stage identity. It
includes development/build ancestors even when absent from the final runtime
graph. Missing, conflicting or cyclic nodes refuse. Current source, toolchain,
canonical contracts and frozen native contexts authorize every proof node.
Consumers retain the archive bytes they use, so cleanup of provider directories
does not invalidate their copied evidence or require unused ancestor payloads.

Schema 13 persists the full frozen plan in the receipt header before the first
producer. Its digest must equal the stage identity's plan digest. A consumer
interrupted before its header exists has no durable staged work to preserve;
once a header exists, its choices are reused or rejected, never silently solved
again. Header-only receipts supply no source output. Interrupted source cleanup
keeps that header continuously present.

Restoration follows this order:

1. Recompute current source/configuration/toolchain/native intent.
2. Read a bounded candidate receipt and validate identity, fields, paths and plan.
3. Authorize roots, native contexts and portable provider proofs against current
   source and canonical producer contracts.
4. Reconstruct the candidate stage without changing shared resolver state.
5. Verify recorded bytes and completed producer evidence, then adopt its bindings
   atomically and resume only unfinished work.

Lookup uses a bounded no-follow receipt scan. It must inspect every candidate
to detect ambiguity and unclassifiable evidence, so no advisory index is needed.
Old advisory index files are ignored. Stage history is also not authority.
Retained invalid, ambiguous or unauthorized stages refuse; only conclusive
absence permits fresh discovery. Temporary download handles can refresh without
changing the portable frozen plan.

Persistence and lookup share the same 4 MiB receipt byte limit. The source inventory is
preflighted before copying source files; oversized later evidence refuses before
replacing the last valid receipt. A successful write must remain readable on the
next invocation.

Intent excludes command scope/verb, live registry availability, temporary paths
and signed download URLs. It includes the effective default registry, operation
policy, roots/candidates and applicable committed locks. The existing whole-source
identity still applies; this change does not promise reuse across unrelated commits.

Schema-12 receipts are not reinterpreted as schema 13. Preserve recovery-critical
old stages and use the RK version that created them. Explicit cleanup permits
rebuilding unpublished old work. A missing new-schema directory cannot bypass
existing public-progress recovery checks.

## Publication and consent

All selected private work precedes one aggregate review, publication session
acquisition and public actions. Consent binds exact receipts/stages, authenticated
recovery inputs, remaining targets, first-name claims, signing and warnings.
Already-public targets and local-only outputs remain checked across asynchronous
work. Public work may shrink when another actor finishes it; changed or expanded
scope refuses under the old consent.

The Dart gate projects original runtime requirements through frozen manifests.
A dev constraint shadowing a runtime name cannot donate that selected version's
transitive edges. Immediately before an upload is marked attempted, the adapter:

1. Fetches relevant selected first-party providers from their public sources and
   verifies their exact staged archive digests and full manifests.
2. Solves a fresh external consumer with only the proposed consumer archive
   preloaded under its hosted identity and a consumer-only synthetic lock.
3. Checks the consumer's source, version, archive, package location and extracted
   inventory, and verifies provider bytes again after the solve.

Private helpers, workspace substitutions and inherited locks cannot satisfy this
public probe. A broad runtime range may resolve a newer compatible public version;
that transient result never replaces the private binding. Failed proof reports
`RK-PUB-018` while the target remains `not_attempted`. The coordinator rechecks
stage/context and destination before uploading the staged archive.

Recovery rules and mixed-unit repackaging limits are specified once in the
[repository contract](repository-release-plan.md#ordering-and-recovery). In
particular, native tar timestamps can make a repack differ from immutable public
bytes. An exact configured tag or built-asset progress remains recovery-critical;
a public package alone does not prove that tagless siblings were previously staged.

## Regression coverage and qualification

| Boundary | Primary suites |
| --- | --- |
| Opaque native identities, phases, graph order and interleaved units | `native_dependencies_test`, `repository_stage_preparation_test`, `repository_publication_test` |
| Constraints, public fallback, transitive conflicts and native backtracking | `dart_hosted_discovery_test`, `native_hosted_staging_test`, `dart_resolution_graph_test` |
| Committed binary locks, workspace policy and helper promotion | `dart_dependency_lock_test`, `dart_development_source_test`, `dart_helper_replay_test` |
| Archive fidelity, malformed archives and exact public identity | `native_package_archive_test`, `dart_public_archive_test`, `dart_public_consumer_test` |
| Imported bindings, same-unit handoff, provider cleanup and tampering | `stage_dependencies_test`, `stage_restoration_test`, `stage_evidence_test` |
| Interrupted headers, bounded lookup, frozen reuse and resolver rollback | `stage_lookup_test`, `stage_restoration_test`, `stage_source_test` |
| Full command scope, all-private-before-consent and partial recovery | `dart_stage_preparation_test`, `release_stage_command_test`, `repository_publication_consent_test` |
| Runtime/dev projection, late drift and public failures before upload | `dart_publication_projection_test`, `repository_publication_consent_test` |
| Source-only plan, read-only status, reporting and existing targets | `release_plan_test`, `status_test`, `phase_conformance_test`, target/binary suites |

The native fixture tests use owned loopback registries and Git roots. The real
Fleury qualification uses an isolated unchanged checkout and cache, records
source/toolchain/archive identities, and runs generated-app tests and a live MCP
interaction against the extracted archives. Full suites pass on SDK 3.13.5 and
3.12.2; minimum 3.10.4 has scoped native coverage. See the
[qualification record](dependency-staging-native-proof.md#final-qualification--2026-10-03)
for counts, hashes and proof limits.

Remaining boundaries are explicit: SDK-mediated runtime paths to staged providers
need original SDK constraint evidence; runtime path/Git substitution is unsupported;
minimum-SDK macOS AOT bundles remain unqualified; no real registry upload or browser
rendering was exercised. The baseline conservative status message for some
public-only binary recovery cases is also unchanged.
