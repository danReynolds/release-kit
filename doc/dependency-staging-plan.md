# Dependency-aware repository staging

Status: implementation in progress. The native mechanism proof, initial
source-only native requirements/candidate projection and staged-provider artifact
contracts are implemented and reviewed. Frozen-choice lookup/authorization,
native preparation integration, repository execution and final Fleury
qualification remain. No publication has occurred.

Baseline: RK main `6e7bb165c8027d8fc5e5293b45432850cf3229f8`, inspected 2026-10-02.

## Outcome

`rk stage` prepares every configured release unit without publishing anything.
A consumer can prepare against compatible, verified package artifacts produced
by another unit in the same invocation. `rk release` publishes those exact
artifacts in dependency order, checking public availability before consumers
publish. Package versions remain independent.

One set of native dependency facts feeds both operations. Staging waits for
private artifacts; publication waits for the public facts each ecosystem actually
requires. The execution graphs may differ: development/build dependencies and
GitHub/Homebrew prerequisites are not all runtime package dependencies.

Example: unpublished `fleury_mcp 0.1.0` may depend on `fleury 0.2.0`. An already
published MCP version cannot have its manifest changed. If an unchanged MCP
still depends on published `fleury 0.1.0`, a local Fleury bump to `0.2.0` must not
force an MCP bump or cause RK to substitute the incompatible local package.

## Current behavior and code to reuse

| Existing owner | Present behavior | Planned extension |
| --- | --- | --- |
| `engine/release_dependencies.dart` | Shared package/repository ordering, but reads Dart Pubspecs, requires current sibling versions, and merges dev/runtime publication edges | Separate native requirements from compatible candidate selection and phase-specific edges |
| `engine/dependency_graph.dart` | Deterministic ordering, cycles, readiness | Reuse for repository preparation as well as existing unit graphs |
| `commands/release.dart` | Bare stage refuses multiple units; bare release stages/publishes one unit at a time | Prepare full selected scope before the first public act |
| `engine/stage_contract.dart`, `stage_receipt.dart`, `stage_inspection.dart` | Producer contracts, hash-bound inputs, resumable per-unit receipts | Import verified dependency artifacts as declared inputs; validate their provenance |
| `engine/release_stage.dart`, `stage_plan.dart` | Unit stage identity and reuse, currently cached by unit | Include resolved dependency bindings in identity and refresh |
| `targets/pub_dev/package_stage.dart`, `resolution.dart` | Native archives and isolated consumer validation; limited same-unit workspace overrides | Consume exact dependency archives before the first native resolution |
| `binary_chain.dart`, `builds/dart_cli.dart` | Native Dart binary production | Share Dart dependency preparation with package validation |
| `targets/pub_dev/module.dart`, `client.dart` | Publish from archive, compare registry archive hashes, probe availability | Reuse these proofs for staged-provider publication requirements |

The existing same-unit snapshot mechanism uses source directories, not final
archives. It is evidence that private resolution is possible, not proof that the
new artifact-based contract already holds. The first Pub solve currently runs
before its consumer overrides are installed; fixing only the second solve would
leave non-workspace first publications broken.

## Command and version semantics

| Command | Scope and behavior |
| --- | --- |
| `rk plan [unit]` | Remains source-only. Shows candidate dependency edges and requirements requiring native/registry resolution; makes no claim that a registry version exists |
| `rk stage` | Stages all configured units in a stable dependency order; publishes nothing |
| `rk stage <unit>` | Keeps the named scope. May consume an existing verified compatible sibling stage matching the current configured source/toolchain/contract; otherwise uses native hosted resolution. Does not build other units or select arbitrary historical cached versions. If neither path resolves, point to `rk stage` or the provider unit |
| `rk release` | Resolves the scope, completes its private preparation, then uses the existing authorization and publication lifecycle |
| `rk release <unit>` | Publishes only that unit; an unpublished provider outside the public scope still blocks publication |

No new release groups, root version, lockstep requirement, `--all`, or automatic
manifest edits. Keep schema-2 release intent. A future version-edit command is
separate from staging.

Candidate policy:

1. Match identity by ecosystem, canonical source/registry, and native package
   identity, not by name alone. Registry identity must not expose credentials.
2. Within the selected scope, prefer a compatible configured release candidate.
   In a named scope, a compatible verified sibling receipt matching the current
   configured candidate/source/toolchain/contract is also usable. Without such a
   sibling receipt, resolve normally from the declared public source, even when
   the local configured version is compatible. Merely having a local sibling
   never requires building it in a named invocation.
3. When the local candidate is incompatible, resolve the original requirement
   from its declared public source. Do not invent an edge to the local candidate.
4. Native resolution must validate the complete resulting graph. A selected
   compatible candidate that creates a transitive conflict produces an actionable
   failure; do not silently replace it with an older package and claim the new
   combination was tested.
5. If neither a compatible candidate nor native published resolution works,
   refuse with the requirement, candidate version, and manifest location.
6. Already released, unchanged units keep the existing no-op behavior. Reading
   them as a source of dependency facts does not schedule a new publication.

For Dart, exact and caret behavior must come from Pub-compatible semantics,
including `^0.0.x`, prereleases, and supported range expressions. RK already
depends on `pub_semver`; use it in the native layer. The current
`Dependency.satisfiedBy` shortcut supports only a subset of native forms and is
not the new cross-ecosystem contract. Dart and npm caret semantics must not be
assumed identical. Native requirement extraction must retain explicit
`hosted:` URLs and SDK dependency kinds, which the existing lightweight parser
does not fully distinguish. This does not add custom-registry publication.

## Shared machinery and adapter boundary

Introduce only the small typed handoff needed by current producers. Names below
describe responsibilities; implementation should reuse existing types where they
already express the same invariant.

- **Requirement:** consumer identity, native dependency name/source/constraint,
  manifest location, and adapter-owned usage semantics. Core treats native
  constraints as opaque and asks the adapter for compatibility.
- **Binding:** a requirement satisfied by a selected candidate artifact or by a
  native published resolution. Carries exact identity, version, source identity,
  artifact digest, and provider provenance when relevant.
- **Prepared inputs:** immutable bindings plus verified local artifact handles
  supplied to the producer. Adapters do not rediscover arbitrary workspace paths.

Bindings are scoped to a consuming native resolution context and dependency
occurrence, not a repository-global name-to-version map. Version/source values
at this boundary are adapter-native identities. A later ecosystem may install
multiple versions or interpret peer/optional/platform requirements differently;
core schedules the required producer edges the native implementation projects.
It does not impose Dart's single-version solution or generic semver semantics.

Native discovery must surface transitive staged-package requirements before a
consumer producer is scheduled: a hosted bridge may depend on a configured local
package even when the consumer never names it directly. Direct manifest edges
alone are insufficient. Source-only `plan` can mark that native discovery as
pending; actual preparation must resolve the edges or refuse explicitly before
executing the dependent. It must not silently use raw source or change a frozen
binding graph mid-production. The first native proof includes this case.

Core owns scope, scheduling, deterministic output, persistence, invalidation,
authorization and retry/stop behavior. Native dependency code owns parsing,
version acceptance, transitive solving, preparation environments, and public
consumer-resolution checks. Public target modules keep their destination
semantics; `publish` does not become a package-manager-independent install hook.

Today there are four publication modules: Pub.dev, Git tag, GitHub Release, and
Homebrew. Dart/Pub needs the first concrete dependency consumer; Dart binary
builds reuse it. GitHub, Homebrew and tags use the already prepared artifacts and
retain their existing public target edges. npm and RubyGems are future native
dependency implementations, not modules to invent in this change.

Move reusable Dart preparation out of a publication-only call path so package
archive validation and standalone compilation share it. A small internal native
dependency interface is justified by those two consumers. Avoid a new plugin
registry, generic solver, event bus, or a second graph assembled in each adapter.
Use an in-memory non-Dart test adapter to prove orchestration does not depend on
Pubspecs, Dart semver, a flat dependency installation, or Pub command strings.

## Artifact and stage contract

Prepare providers before consumers. For a cross-unit dependency, once the
provider's completed stage receipt validates, copy its exact archive bytes into
a declared dependency-input area in the consumer's private stage. Record provider
unit/project, coordinate, provider receipt/plan identity, archive path and digest,
and relevant native resolution evidence in the consumer contract. Copies allow
clean/retry to retain a self-contained consumer stage rather than following
mutable external paths.

Resolve cross-unit binding digests before finalizing the consumer stage identity. Stage
lookup, the unit cache, refresh, status and publication must all use the same
bindings. A later public appearance of the identical provider artifact does not
change the consumer's private binding or force a rebuild. A changed provider
artifact cannot inherit the old consumer receipt merely because its version
string is unchanged.

Within a multi-project unit, a provider and consumer share one stage identity.
Do not put the provider's not-yet-produced archive hash into that identity. Use
producer-contract edges inside the unit and bind the archive hash in the
consuming `StageStep` after the provider producer completes and its output
receipt/contract validates. A completed producer is sufficient for this private
handoff; publication still requires the completed unit stage. Replace the current
source-only inputs on sibling Pub archive producers with actual artifact edges.

Frozen bindings and current availability are separate facts. Refresh verifies
the recorded choice; it does not pick a newer hosted version or change a staged
binding into a hosted binding because the provider was just published. Published
fallback bindings also retain the exact native-selected versions and integrity
evidence. Repeating an unchanged stage reuses its verified frozen bindings. A new
stage after source/input change, or deliberate cleanup through existing stage
management, may resolve anew and produce a new identity; add no new refresh flag.

Locate reusable receipts before performing a new hosted solve. Use a deterministic
source/intent key (source, unit, native requirements, selected candidate identities,
toolchain and adapter policy) to locate the last completed stage for that intent.
A small atomic local index is a lookup hint only: inspect its receipt and contract,
revalidate frozen binding proofs, and reconstruct the full stage identity before
reuse. Missing/corrupt hints fall back to bounded receipt discovery or a new stage,
never unchecked adoption. The index is not a second journal or an authority;
partial-publication recovery still requires the exact original stage.

Imported inputs must be declared in the canonical producer contract before any
receipt is trusted. The imported-input producer must prove correspondence with the frozen dependency
plan; a forged self-consistent evidence map is not sufficient. Extend current
contracts/inspectors, including their special Pub-archive input checks. Do not
hide authoritative dependency hashes in optional history evidence.

Extract native archives through a format-appropriate validated reader into
isolated scratch directories; refuse traversal, escaping links and malformed
entries, duplicate/conflicting paths, and preserve relevant file modes. The existing deterministic RK tar
reader is not assumed to accept every native Pub archive. Package contents must
come from the archive, so omitted library files cannot be supplied accidentally
by the checkout. Apply this guarantee to same-unit and cross-unit runtime
dependencies. The explicitly dev-only helper exception is described below.

Use the existing source/toolchain/environment binding rules. Do not promise
selective reuse across unrelated commits: the current whole-source identity
still applies. Within a fixed source identity, dependency changes invalidate
consumers while unaffected verified stages stay reusable.

Receipt/schema migration must be explicit. Old stages without dependency proof
cannot become proof of the new behavior. Preserve fully supported old no-dependency
stages if practical; otherwise give the existing explicit rebuild remedy.
Never silently rebuild recovery-critical partially published binary artifacts.

## Dart resolution: prove the mechanism first

The native solver remains authoritative. Managed path overrides alone are not
enough: they bypass inbound constraints, including those from hosted transitive
packages. The first implementation slice is a bounded native fixture probe,
before changes to repository orchestration.

Evaluate the smallest sound mechanism against the cases below:

- Exact staged archives available before the first `pub get`, for ordinary
  packages and workspaces, with an isolated Pub cache and scratch environment.
- A staging-only resolution environment that preserves original version/source
  requirements, native backtracking, and unchanged final published manifests.
- Existing managed overrides are acceptable only if a complete original-graph
  audit proves all inbound constraints and does not falsely reject the native
  solver's valid alternative resolution. Checking root dependencies alone fails
  this gate. Do not implement an RK-owned replacement dependency solver.
- If overrides cannot meet that gate, evaluate an ephemeral adapter-owned hosted
  view of the exact archives. Keep it local to the preparation process; preserve
  registry/source identities in bindings; never redirect publication, forward
  credentials to the wrong destination, or leave global cache/config changes.

The selected mechanism is a **hosted discovery solve followed by native archive
cache replay**. See [measured native evidence](dependency-staging-native-proof.md).
Workspaces were rejected because they shadow another registry's same-name
package and require a newer language lower bound than an otherwise valid
consumer may declare. Managed runtime overrides are unnecessary.

1. In a private discovery environment, map each canonical original registry to
   a distinct loopback registry. Rewrite only hosted source locations in the
   shadow root and registry metadata; preserve native constraints and all other
   resolution-affecting fields. Default dependencies always refer to the
   original default registry, not their containing package's registry.
2. Let Pub solve against manifest-only discovery payloads with examples and
   precompilation disabled. These payloads are metadata, never stage artifacts.
   Once selected, a candidate is constrained by restricting its exact source/name
   listing to the selected version. No override bypasses inbound constraints.
   Candidate selection must only include compatible reachable candidates; retain
   native hosted fallback when a candidate is incompatible or outside named scope.
3. Read native selected identities and dependency edges before producer ordering.
   After producers complete, verify real archive manifests against the original
   discovery metadata. Never permit an unplanned edge to appear during production.
4. Native `dart pub cache preload` installs the exact verified archives into an
   empty private cache under each **original** registry identity. Resolve the
   unchanged consumer manifest with `pub get --offline`, using only these frozen
   versions. Native Pub rechecks original source/version/SDK requirements.
5. Native `pub publish --to-archive` and compilation use that resolution. Verify
   the original-source identities, versions, dependency graph and hashes still
   agree afterward. Only the justified dev-helper exception uses managed overrides.

The dependency plan records discovery metadata hashes separately from archive
hashes. Loopback URLs and temporary payload hashes do not become package identity
or authoritative artifact evidence. Production still needs guarded extraction,
bounded metadata fetching, source mapping, graph comparison and receipt binding;
the fixture helper is not a production registry implementation.

Validate the actual package payload and the selected dependency graph. Pub hints
and warnings retain their normal meaning; Pub can report analyzer errors as
warnings. Do not silently turn every existing warning into a new refusal. A
missing packaged import must be exposed by native validation, and the native
compile fixture must fail; a warning-bearing archive cannot be reported as clean.
Temporary files and resolution overrides must be absent from published archives.
Package and binary producers must use the same selected staged-package bindings,
while preserving their operation-specific third-party lockfile/dev policies.
Record each native resolution graph separately; do not require all third-party
versions to be identical between Pub packaging and executable compilation.

## Phase-specific edges and publication

Keep native dependency kinds intact. Runtime/public dependencies that require a
provider coordinate add publication prerequisites. Build/dev dependencies add
preparation edges when the native operation actually needs them. They must not
automatically become public-consumer requirements simply because Pub's root
development environment uses them.

Preserve the existing dev-only workspace-helper path: a helper used exclusively
for development may come from a receipt-bound source snapshot even when nothing
publishes it. It is labeled development evidence and can never satisfy a runtime
artifact requirement. This preserves the common library dev-depends-on-test-helper
whose runtime dependency points back to the library. Check the helper's original version constraints and back-edges in native discovery before
applying its managed override; Pub may ignore overridden helper back-edges. If
the same helper is also runtime-reachable, the runtime artifact rule wins. A path/Git runtime dependency
does not acquire this exception. SDK requirements remain native SDK inputs;
they are never mistaken for similarly named local/hosted packages.

Detect cycles on the executable projections, with actual paths in diagnostics.
A dev-only edge must not create a spurious public cycle. Genuine mutually
unpublished runtime artifact cycles that have no preparable inputs refuse; do
not add a bootstrap or atomic multi-package transaction in this delivery.

Use serial release-unit traversal initially, retaining existing producer
concurrency within a unit. For interleaved grouping such as unit U=[A,C], V=[B]
with C depending on B and B on A, the package graph is acyclic but serial complete
unit staging is impossible. Diagnose this explicitly as unsupported interleaved
release-unit grouping and suggest separate units. Do not misreport a native
package cycle. Repository-wide producer scheduling is a separate extension.

Bare release performs complete private preparation of its selected scope before
the first permanent act. Move the single actual publication confirmation after
that preparation and warning collection; today's `_askOnce` precedes preparation.
Preserve its one-confirmation behavior and scope-freezing guarantees, and re-read
destination truth at the established authorization/publication boundaries. Staging never
creates a publication session or public claim. Existing private signing and
notarization behavior remains unchanged.

Before a dependent publishes, confirm required provider coordinates are public,
compare their artifacts with the stage binding using adapter-native proofs, and
run a fresh ordinary consumer resolution with staging substitutions removed.
For Pub, reuse the registry archive-digest and fresh-cache availability tools.
Create a tiny external root depending by path on the extracted staged consumer:
its runtime dependencies resolve normally from their declared sources, while its
development helpers are not installed as consumer requirements. No inherited
lockfile, override or workspace; the extracted consumer itself is the only local
runtime exception. Prove this for workspace metadata in the native fixture.
This check validates; it must not regenerate the archive about to be uploaded.

This explicit preupload gate is required: Pub's `--from-archive` skips normal
package validation. RK must not assume uploading the exact archive re-runs the
resolution performed by `--to-archive`. See the native
[Pub publication implementation](https://github.com/dart-lang/pub/blob/master/lib/src/command/lish.dart);
the first slice records the matching supported SDK revision rather than relying
on a moving upstream branch as its sole evidence.

For a fully bundled Dart executable with no runtime registry dependency, consuming
a staged Dart library is a build dependency and does not itself require that
library's publication before the executable can be released. The native adapter
projects this distinction; the GitHub/Homebrew target does not infer package edges.

For a broad range, normal public resolution may legally choose another version.
Record that graph separately; do not claim the staging graph was identical.
Any required selected-provider publication still needs its exact proof. A binary
continues to publish the compiled bytes whose dependency graph was recorded.

Name conflicts, permissions and propagation remain public checks, not guaranteed
by staging. If a later publication fails, preserve completed public truth and
resume only unfinished work. Publication never broadens a named command or
silently adopts different dependency artifacts.

## User-facing result

Human output should say which dependencies were used, without requiring new
configuration or manual ordering:

```text
fleury      0.2.0  staged
fleury_mcp  0.1.0  staged using fleury 0.2.0
4 units staged. Public dependency checks run during release.
```

A fallback should be equally visible: `fleury_mcp 0.1.0 uses published fleury
0.1.0; local fleury 0.2.0 does not satisfy its requirement`.

`plan`, `status`, stage progress and JSON use the same binding facts. Source-only
plan labels unresolved registry choices as unresolved. JSON reports distinguish
staged, already public, blocked, and not attempted; no all-green aggregate for a
partial stage. Update the JSON schema/documentation when fields change.

## Implementation slices and exit criteria

Each slice is reviewable and keeps existing release behavior intact until the
new path has its proof. Do not enable whole-repository staging by merely deleting
the CLI refusal.

1. **Native resolution proof.** Add a disposable two-package fixture outside the
   production path and the transitive/backtracking cases below. Prove exact archive
   extraction, pre-first-solve input injection, unchanged manifests and SDK support.
   Select the mechanism above and retain regression fixtures. No core refactor yet.
2. **Requirements and binding selection.** Introduce the minimal native handoff,
   adapt Dart facts, use native-compatible version matching, and replace the
   forced-current-sibling rule. Keep static plan source-only. Prove independent
   versions, old-public fallback, source identity and phase-specific cycles.
3. **Cross-unit artifact inputs and receipts.** Extend contracts, stage identity,
   cache/refresh, inspector and imported archive handling. Prove tamper/drift,
   provider-stage deletion, deterministic reuse and migration behavior.
4. **Shared Dart preparation.** Integrate the proven mechanism with native Pub
   archive staging and Dart binary compilation; cover same-unit/workspace and
   separate-package layouts. Prove native validation exposes missing packaged
   files, actual consumer compilation fails, and output manifests remain unchanged.
   Exercise built executables with the staged dependency value.
5. **Repository stage and release integration.** Reuse the existing graph/coordinator
   flow to prepare selected scope, preserve named scope and aggregate output,
   then reuse the publication pipeline and fresh public-resolution checks. Test
   zero public calls after any preparation failure and unchanged authorization scope.
6. **Qualification and documentation.** Run focused native fixtures and the full RK
   suite; dogfood all four Fleury packages without publication; update help,
   README, codes, JSON docs, pipeline docs and the superseded repository plan.

Suggested ownership: slices 1/4 are the Dart preparation seam; slices 2/3/5 are
shared core. Public target modules change only where typed prepared inputs or
publication checks require it. Future npm/gem packages can add native semantics
against the same requirements/bindings; implementing those ecosystems is outside
this delivery.

### First implementation packet

Start with slice 1 on a new implementation branch from the latest RK main; keep
this documentation commit available as the design reference. Reconcile later
upstream changes before editing. Do not start with `ReleaseCommand` or remove
`RK-CLI-004` first.

Suggested new fixture files are `test/native_dependency_staging_test.dart` and
`test/support/native_pub_fixture.dart`. They are test-owned processes/files, not
a production registry server or a new release target. Use a disposable Git root,
isolated Pub cache, credential-free loopback fixture registry, and separate native
process environments. No `publish` command without `--to-archive`/`--dry-run`, no
real registry uploads, and no Git tags. Fixture teardown owns every temporary
directory and local listener it creates.

Concrete cases to implement first:

1. **Two unpublished packages:** core `0.2.0` exports a known value; MCP `0.1.0`
   requires core `0.2.0`. Create the provider with native archive tooling, extract
   it, package MCP, and compile/run a consumer that prints the expected value.
2. **Transitive contradiction:** MCP accepts core `^0.2.0`, but its selected
   hosted bridge requires core `^0.1.0`. The resolution must fail even with local
   staged core available.
3. **Valid backtracking:** MCP accepts core `^0.2.0` and bridge `>=1.0.0 <3.0.0`.
   Hosted bridge `2.0.0` needs core `^0.1.0`; bridge `1.0.0` needs core `^0.2.0`.
   Correct native resolution selects bridge `1.0.0`. An override-plus-audit that
   selects bridge `2.0.0` then refuses fails this mechanism gate.
4. **Source and payload:** repeat with explicit/default hosted syntax, a same-name
   different registry, and a provider library excluded from the archive. Assert
   actual selected paths/digests, manifest equality, and compile results.
5. **Development and consumption:** preserve an unpublished dev-only source
   helper with a back-edge; prove the external-root consumer probe ignores that
   helper and still catches an unavailable/incompatible runtime dependency.
6. **Same-unit production:** feed a verified provider producer output to another
   producer before the common stage completes; avoid identity/receipt deadlock.
7. **Transitive discovery:** the consumer names only hosted bridge; bridge accepts
   a selected unpublished core candidate. Native discovery must identify and
   expose that artifact dependency before ordering consumer production.

Record Dart `3.12.2` (the pinned RK formatting/analysis CI SDK), current stable,
and the declared minimum `3.10.4` capability outcome. Do not require archive
staging on a SDK that lacks the necessary native flags: it must give the existing
clear unsupported-SDK refusal. Record the actual Pub revision/mechanism used by
supported SDKs. Native tools, not mocked success strings, determine the result.

Deliver a short evidence section with selected mechanism, commands, SDK versions,
archive and manifest hashes, resolver outcomes, and why rejected alternatives
failed. Review that result before starting slice 2. This gate is ready to begin;
the remaining slices are conditional on its success, not a claim that native
resolution has already been proved.

## Acceptance matrix

| Case | Required evidence |
| --- | --- |
| Fleury-shaped four unpublished packages | One bare stage creates/verifies all four archives; no publish, tag, draft, tap write or publication login |
| Independent versions | MCP `0.1.0` stages against core `0.2.0`; no manifest/version edits |
| Old-public fallback | MCP requiring `0.1.0` resolves published core `0.1.0` while local core is `0.2.0`; no false release edge |
| Missing compatible version | Fails before publication; native requirement and manifest location are shown |
| Constraints | Exact, caret before 1.0, `^0.0.x`, prerelease/range cases agree with native Pub; unknown syntax fails honestly |
| Transitive conflict | A hosted dependency requiring core `<0.2.0` cannot be masked by a staged core `0.2.0` override |
| Valid native backtracking | Solver can choose an older compatible transitive dependency; RK neither accepts an invalid graph nor invents a false conflict |
| Source identity | Same package name from another registry, Git/path source or wrong unit cannot satisfy the binding |
| Layouts | Ordinary packages, Dart workspaces, same-unit projects, dev-only inputs, runtime/dev diamond and actual cycle |
| Archive fidelity | An excluded required provider file is exposed by native package validation; a real consumer compile fails; warning-bearing stage is not labeled clean |
| Binary route | CLI builds/runs using staged core; GitHub/Homebrew receive those exact binary artifacts |
| Integrity/reuse | Changed bytes, forged dependency evidence, missing import, wrong digest/source/toolchain refuse reuse; repeated unchanged stage reuses outputs |
| Cleanup/resume | Provider stage can be cleaned after verified import without breaking consumer bytes; interruption resumes completed verified work |
| Public mismatch | Registry serves the same name/version with different artifact bytes: dependent publication refuses |
| Propagation/retry | Provider public but temporarily unavailable: dependent waits/refuses with a rerun path; never republishes provider blindly |
| Partial publication | Fresh re-run skips exact public work, preserves consumer bindings, and retains lost-stage refusal for partially published binaries |
| Scope/consent | Named stage builds no other units; named release publishes no providers; scope cannot grow after consent |
| Pure plan | No registry, compiler, cache writes or publication sessions in `rk plan`; pending resolutions labeled honestly |
| Future ecosystem seam | Non-Dart fake uses opaque constraints/source identities and different dependency kinds; shared scheduling/receipts require no Dart branching |
| Same-unit handoff | Provider output feeds consumer before unit completion, using producer receipts; no stage-identity hash cycle |
| Interleaved grouping | U=[A,C], V=[B], C→B→A gets an unsupported grouping diagnostic, not a false package-cycle claim |
| Development helper | Existing unpublished dev-only source helper/back-edge still works; runtime promotion requires artifact proof |
| Frozen hosted binding | New compatible registry release does not change a resumed stage's recorded solve or identity |
| Override policy | Unrelated developer runtime overrides remain refused; only declared preparation bindings/dev-helper exceptions are eligible |
| Named hosted fallback | Compatible local sibling with no eligible stage does not block named staging when native hosted resolution succeeds |
| Transitive discovery | Hosted bridge reveals staged-core dependency absent from consumer manifest; native discovery supplies the edge before scheduling |

Relevant existing suites: `dependency_graph_test`, `resolve_test`,
`release_plan_test`, `pub_dev_resolution_test`, `stage_plan_test`,
`release_stage_test`, `release_stage_command_test`, `stage_cli_test`,
`release_test`, `phase_conformance_test`, target catalog/client tests and binary
producer tests. Add native integration fixtures alongside these; mocks alone
cannot establish package-manager resolution behavior.

Fleury qualification uses an isolated checkout and cache, unchanged release
config, native archive inspection and generated-app/test smoke runs against the
staged artifacts. It records commit, SDK/RK identity, dependency bindings and
archive hashes. Live publication remains separately authorized.

## Review record

Two independent reviews examined the current RK code, the written draft,
revision 2, and final revision 3 on 2026-10-02. The review scopes were shared
architecture and native resolution/qualification. Both explicitly approved
revision 3 for starting the native-proof slice, with no remaining planning
blockers. Review verdicts concern implementation-start readiness, not implemented
functionality.

| Finding | Resolution in the plan |
| --- | --- |
| Overrides can bypass transitive constraints and lose valid native backtracking | Mandatory real native proof precedes orchestration; concrete conflict and valid-alternative fixtures |
| First Pub solve runs before current private override setup | Input preparation explicitly precedes the first native solve |
| Same-unit archive hashes in stage identity would be circular | Cross-unit imports bind identity; same-unit edges bind consuming producer receipts |
| A complete-unit-only receipt rule would deadlock same-unit preparation | Private intra-unit handoff accepts verified producer output; publication requires complete stage |
| Frozen hosted choices cannot be rediscovered by solving afresh | Source/intent lookup hint, authoritative receipt verification, and immutable binding refresh |
| Dev-only workspace helpers and binaries have different public prerequisites | Explicit dev snapshot exception, external-root runtime consumer probe, bundled-binary distinction |
| Pub analyzer findings may be warnings; archive upload does not rerun validation | Warning status remains accurate; real compile fixture and explicit preupload public-consumer check |
| Registry identity can be lost in current Pubspec parsing | Native extraction retains hosted source and SDK kind; same-name source mismatch tests |
| Cross-ecosystem caret/multiple-version assumptions would leak into core | Adapter-native versions and per-resolution bindings; use actual Pub semantics, not npm assumptions |
| Multi-project units can interleave without a package cycle | Initial serial-unit scope gives an explicit unsupported-grouping diagnostic |
| Named stage should not require a sibling stage when published resolution works | Explicit hosted fallback when no eligible sibling artifact exists |

Final architecture verdict: revision 3 is ready to start; no remaining
architectural blocker. Final native-resolution verdict: revision 3 is ready to
start the native-proof slice; no new blockers or further planning changes.
Both require the native mechanism evidence before integrating later slices.
There are no unresolved product-policy questions; the remaining technical choice
is deliberately the first implementation packet.


## Implementation progress

- Native mechanism proof: commit `664a7c1`. Nine chosen-mechanism native cases
  passed on Dart 3.10.4, 3.12.2 and 3.13.5. Both reviewers approved the mechanism.
- Source facts and selection: shared native identity/context/slot/phase model,
  conjunctive candidate compatibility, independent hosted fallback, Pub-native
  constraints, explicit hosted-source/SDK distinction, and source-only candidate
  reporting. Checklist edges now consume the same publication projection.
  Native constraints remain inside the Dart adapter boundary.
- Resolution ownership is explicit: a transitive declaring package retains its
  provenance, while the enclosing configured root owns preparation/publication
  obligations. This must be exercised end-to-end when native discovery connects.
- Staged-provider artifact inputs: `StageDependencies` freezes native context,
  slot, opaque provider coordinate, consuming producers, provider stage/receipt,
  archive metadata and portable provider proof into the consumer plan. A core
  producer copies exact verified bytes; canonical contracts compare expected
  metadata independently of receipt evidence. The coordinator schedules this
  producer and gives targets the same decorated contracts it inspects.
  Same-unit dependencies bind producer output hashes when ready, without putting
  future hashes into unit identity. Consumer verification survives provider-stage
  deletion. Rebinding preserves identity while refreshing temporary provider
  handles. Signed-build inspection permits canonical dependency inputs and still
  requires the source snapshot. The architecture reviewer approved this bounded
  slice after those last two regressions were fixed.
- The artifact slice is exercised with a non-Dart native producer through the
  actual coordinator, including reuse, independent opaque versions/install slots,
  forged self-consistent receipts, provider/input tampering, cleanup, and an
  incomplete same-unit provider handoff. This proves the generic receipt path;
  production Dart preparation does not use the new bindings yet.
  The focused artifact, existing stage/plan/coordinator, target, Pub resolution
  and phase-conformance suites pass together: 298 tests with the complete Dart
  3.12.2 SDK. `dart analyze` is clean. This is focused regression evidence,
  not the final full-suite or Fleury-stack qualification.
- Remaining review requirements: frozen real bindings rather than candidate
  selections authorize receipt inputs; full native graph/manifest agreement;
  dev-helper original/back-edge constraints; bounded isolated source discovery;
  safe extraction, stage lookup/reuse and recovery. Restoring dependency JSON
  verifies consistency with a declaration, not authorization of that declaration.
  Source/intent lookup must validate the native frozen choices and provider
  contracts before adopting a restored plan. Hosted fallback graphs, selected
  versions and integrity still need their own immutable plan binding. The
  artifact contract does not complete implementation slice 3 on its own.
- Production native preparation primitives now implement bounded hosted shadow
  discovery and exact archive replay. Discovery uses native backtracking,
  discovers transitive-only candidates, refines compatible local preference,
  preserves source identity and hosted fallback, and discards all listeners and
  caches. Signed archive URLs are temporary fetch details, not serialized
  identity. Ignored provider dev metadata and failed speculative prefetches do
  not override a successful native solve.
- The native archive reader uses Pub's tar library with stricter framing,
  expansion and path limits. Original manifest equality precedes preload;
  replay verifies exact graph/source/hash selection, package configuration,
  root manifest, installed payload inventory and executable modes. Native
  operations verify this environment before and after running. Review found
  and closed directory/stacked-metadata framing bypasses, YAML alias expansion,
  signed-URL refusal, provider-dev remapping and speculative-prefetch failures.
  Both independently reproduced archive and discovery cases remain regressions.
- The native reviewer approved this bounded archive/discovery/replay slice.
  The focused archive/native/digest/graph suite passes 55 tests; the broader
  archive/native/phase/stage run passed 178 before the final parity fixes.
  Production discovery plus the original native scenarios also passed on the
  supported minimum and stable SDKs. Command integration is not enabled yet.
  Required next work remains native context/hosted archive binding and lookup,
  dev-helper authorization, shared Pub/binary integration, repository preparation
  and publication gates, full-suite verification, and four-package Fleury dogfood.
