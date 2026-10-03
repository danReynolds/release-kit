# Dependency-aware repository staging

Status: reviewed delivery plan; implementation is in progress on
`codex/dependency-staging`. Native discovery/replay, receipt-bound inputs, shared
Pub/binary preparation, frozen-choice verification and source-bound binary lock
policies are implemented. Command integration is not complete.
The remaining work is defined in the implementation packets below; foundation
proofs do not qualify bare `rk stage` or publication. No publication has occurred.

Baseline: RK main `6e7bb165c8027d8fc5e5293b45432850cf3229f8`, rechecked against
remote main on 2026-10-02. Continue in the existing `codex/dependency-staging`
worktree; do not restart the native proof or create another implementation branch.

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

## Baseline behavior and code to reuse

| Existing owner | Main baseline behavior | Extension |
| --- | --- | --- |
| `engine/release_dependencies.dart` | Shared package/repository ordering, but reads Dart Pubspecs, requires current sibling versions, and merges dev/runtime publication edges | Separate native requirements from compatible candidate selection and phase-specific edges |
| `engine/dependency_graph.dart` | Deterministic ordering, cycles, readiness | Reuse for repository preparation as well as existing unit graphs |
| `commands/release.dart` | Bare stage refuses multiple units; bare release stages/publishes one unit at a time | Prepare full selected scope before the first public act |
| `engine/stage_contract.dart`, `stage_receipt.dart`, `stage_inspection.dart` | Producer contracts, hash-bound inputs, resumable per-unit receipts | Import verified dependency artifacts as declared inputs; validate their provenance |
| `engine/release_stage.dart`, `stage_plan.dart` | Unit stage identity and reuse, currently cached by unit | Include resolved dependency bindings in identity and refresh |
| `targets/pub_dev/package_stage.dart`, `resolution.dart` | Native archives and isolated consumer validation; limited same-unit workspace overrides | Consume exact dependency archives before the first native resolution |
| `binary_chain.dart`, `builds/dart_cli.dart` | Native Dart binary production | Share Dart dependency preparation with package validation |
| `targets/pub_dev/module.dart`, `client.dart` | Publish from archive, compare registry archive hashes, probe availability | Reuse these proofs for staged-provider publication requirements |

The baseline same-unit snapshot mechanism uses source directories, not final
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

Candidate policy for a **new** native resolution follows. An authorized frozen
stage takes precedence over this policy: repeating a named stage as a bare stage
reuses its recorded hosted choice even if a compatible local provider is now
eligible. Report what was actually used; do not claim the new provider combination
was tested. Command verb and scope do not invalidate an otherwise identical stage.

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

Portable provider evidence includes a bounded, deduplicated closure of referenced
provider plans and receipts, keyed by stage identity. Reject missing, conflicting
or cyclic proof nodes. Validate each node against current configured source,
toolchain and canonical producer contracts, including its native frozen contexts.
The consumer retains the actual archives it uses; it need not retain unused
ancestor payloads or require a deleted ancestor stage to exist. A provider's
development/build-only ancestor is included in the proof closure even if absent
from the final consumer's runtime graph. This extends existing imported proof
files; it is not a new attestation service or registry.

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
source/intent key (source, unit, native requirements, configured candidate
identities, toolchain and adapter policy) to locate completed or interrupted stages.
Exclude command verb, named/bare scope, changing registry availability, live paths
and signed download URLs. Include the effective default dependency registry even
for binary-only projects. Scope controls fresh candidate eligibility and actions,
not the identity of already prepared bytes.

Persist the full frozen plan in a versioned receipt header before any producer
runs; its digest must equal the stage identity's plan digest. The complete-stage
step is too late to be the only copy. A small atomic local index maps intent to
stage ID and is only a lookup hint: inspect the receipt and current contract,
revalidate frozen binding proofs, and reconstruct the full stage identity before
reuse. Missing/corrupt hints fall back to bounded receipt discovery. Absence of a
prior stage permits a new solve; failed authorization of a found recovery stage
must not silently substitute one. Preserve existing explicit-stage replacement
rules and partial-publication lost-stage refusals. No second journal is needed.

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
Package and binary producers share authorized provider facts and use the same
verified provider artifact wherever their contexts select that provider. Preserve
operation-specific lockfile/dev policies and record each native resolution graph
separately; do not force identical third-party solutions or flatten context slots
into one repository-global selection.

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
plan labels unresolved registry choices as unresolved. Status uses a read-only
lookup to inspect recorded contexts, source contracts and receipt bytes; it does
not perform fresh solves, materialize caches/inputs, update indexes or execute
producers. Distinguish a locally verified receipt from any native reauthorization
still required before stage/release adoption. Parsed bindings alone never grant
publication authority. JSON reports distinguish
staged, already public, blocked, and not attempted; no all-green aggregate for a
partial stage. Update the JSON schema/documentation when fields change.

## Remaining implementation packets and exit criteria

Continue from the existing branch. The native mechanism and producer contracts
have passed their bounded reviews; do not repeat those as new standalone projects.
Each packet must connect to the next production caller and keep the current
command behavior until its complete replacement is exercised.

| Packet | Primary seams | Required result |
| --- | --- | --- |
| 1. Authoritative native inputs | `source_tree.dart`, `native/dart/stage_context.dart`, `hosted_discovery.dart`, `stage_preparation.dart` | Current source authorizes every root/candidate/helper; Pub and binary use explicit native policies |
| 2. Frozen stage restore | `stage_receipt.dart`, `stage_store.dart`, `release_stage.dart`, `stage_dependencies.dart` | Complete and interrupted stages reuse exactly their recorded choices; portable provider proofs survive cleanup |
| 3. Repository preparation | `dependency_graph.dart`, `release_stage_coordinator.dart`, `release.dart`, `bin/rk.dart` | One real bare `rk stage` prepares all configured units; named stage retains its scope |
| 4. Publication integration | `release_publication_coordinator.dart`, `targets/pub_dev/module.dart`, `client.dart` | All private work precedes publication; exact public-provider and fresh consumer checks guard upload |
| 5. Qualification and DX | CLI/phase tests, help, JSON docs, pipeline docs, isolated Fleury checkout | Real command-level Fleury evidence, full regressions, understandable success/refusal/retry output |

Packets 1 and 2 can share a review boundary, but neither constitutes command
completion. Packet 3 is the first command-level milestone. Packet 4 is required
before describing dependency-aware release as complete. No real publication,
remote tag, release draft or tap write is part of qualification.

### 1. Authoritative native inputs

Build a small operation-input description from the selected immutable source.
For Git-bound runs, use reads at the selected commit, not live `GitSourceTree.read`
or caller-supplied restored manifests. For unbound runs retain the existing
single-invocation source checks; do not create reusable cross-run authority.
Resolve configured provider ownership and canonical source identities once.
The Dart adapter owns manifest parsing, operation policy and native discovery;
core receives context/slot bindings and the dependency edges it must schedule.

Make these policies explicit in the native context and its format:

- Pub archives use a detached original root without an inherited lockfile.
- Binary compilation uses the committed applicable lockfile, including the
  workspace lock when applicable. Native `pub get` keeps compatible locked
  choices and updates when required; this is not a new strict-lock policy
  ([native behavior](https://dart.dev/tools/pub/cmd/pub-get)).
  Seed each discovery refinement pass from a transformed copy of the original
  effective lock, never the previous pass's selected solution. Install that
  effective lock at the detached member root for replay; leaving a workspace
  parent's lock on disk is insufficient. Restore original source identities and
  verify real external integrity; placeholder discovery archives must not
  overwrite the authority of committed hashes.
- Compatible eligible first-party candidate preference remains explicit for a
  fresh solve. If selecting it changes a locked package, report the change and
  let native Pub resolve remaining constraints. Pub and binary contexts share
  eligible provider facts, while retaining their own complete native solutions.
- An authorized dev-only workspace helper binds its snapshot-relative path,
  full manifest and source identity to the consumer's existing source-snapshot
  receipt. Keep that mapping Dart-owned; do not fabricate a hosted artifact or
  Pub producer for a helper that never publishes. Native discovery checks every
  original incoming constraint and root back-edge version/source before any
  managed override. Discovery/replay comparison allows only this declared dev
  source mapping; every other node and edge must still match. The helper's own
  dev dependencies remain ignored under native semantics. Reject untracked or
  out-of-snapshot helpers. Classify runtime reachability first: a runtime-reached
  helper requires its package archive. Reject unrelated overrides and runtime
  path/Git substitutions as already specified.

The binary-lock and committed-source cases now pass; see current evidence below.
The next packet-1 action is the development-helper policy: add native cases for
an incompatible back-edge or transitive incoming constraint, runtime promotion,
ignored helper dev dependencies and untracked helpers. Implement the
smallest policy support that makes those tests and the existing archive replay
cases pass. Do not accept an override-only success as the back-edge proof.

Exit: root/owner/source/lock/helper tampering refuses before producer work;
ordinary, workspace and binary fixtures run against the unchanged final
manifests. The native package cache and checkout remain unmodified.

### 2. Frozen stage restore and proof authorization

Persist the bound plan in the receipt before source/build/archive producers,
with an explicit compatible receipt migration. Use `StageStore`'s mutation lock
for atomic intent hints; bounded no-follow receipt scanning is the fallback.
Keep `StageHistory` advisory rather than making its unchecked history authoritative.

Adoption order is fixed:

1. Recompute current source intent from packet 1 and current toolchain/config.
2. Read a bounded candidate receipt and frozen plan; validate their hashes,
   identity, paths and format. A hint never supplies authoritative intent.
3. Authenticate root/candidate manifests and the portable provider proof closure
   against current configuration and canonical contracts. Reuse the existing
   native frozen verifier for exact metadata and native graph authorization.
4. Bind the authorized dependencies into the shared `ReleaseStages` instance;
   require its newly reconstructed full identity to equal the recorded one.
5. Inspect recorded artifact bytes and completed producer contracts; resume only
   unfinished work. Refresh temporary download/provider handles without changing
   the portable plan. Publication requires a completed, strictly verified stage.

Exit tests cover interrupted resume without a new solve, missing/corrupt hints,
forged self-consistent dependency JSON, changed root/registry/toolchain, newer
registry versions, stage-to-release and bare-to-named reuse, and named-hosted to
bare reuse. For A→B→C, delete A and B stages and verify C, including A used only
by B's development/build environment. A missing proof or changed copied archive
refuses. Lost recovery-critical public artifacts still yield the existing refusal,
never a freshly compiled replacement.

### 3. Repository preparation and real command wiring

Add one shared repository preparation coordinator at the existing composition
root. It receives adapter-authorized contexts and invokes the existing per-unit
`ReleaseStageCoordinator`; do not introduce another native solver or target
registry. Use one bound `ReleaseStages` instance for execution, inspection,
refresh and restored status.

Discover all selected native contexts and transitive provider edges before
scheduling production. Construct the executable producer graph, diagnose actual
cycles, then project to serial complete-unit order. An acyclic producer graph
with cyclic unit grouping gets the explicit interleaved-grouping diagnostic.
Same-unit producer edges use current verified output receipts. Cross-unit imports
are finalized after their providers complete, before consumer identity is fixed.

Split the existing unit flow into inspect, prepare and publish phases. Private
preparation defers selected-provider public availability, while preserving source,
conflict, monotonicity, endpoint-readiness and lost-stage guards. Do not broadly
ignore unknown public state. All-units preparation must not create publication
sessions. Already public exact targets remain publication no-ops. Fresh discovery excludes
already-exact public packages without an eligible current private archive from
local producer candidates and uses normal authenticated hosted resolution for
those coordinates. It must not select a local import then skip its producer as
already released. Classify package targets individually in mixed multi-project
units; a unit-level no-op cannot hide a required producer.

Fresh named staging can use a verified current sibling stage, otherwise normal
hosted resolution. It cannot build the sibling. A frozen imported provider proof
can remain usable after its original stage is cleaned. Publish scope never grows.
Use fake non-Dart contexts with opaque versions and multiple install slots to
exercise this coordinator, in addition to the real native fixture.

| Provider state during a fresh solve | Eligible input and action |
| --- | --- |
| Selected unpublished package | Its producer is scheduled; consumer waits for verified artifact |
| Named command, current compatible verified sibling archive exists | Import it without building or publishing the sibling |
| Named command, no eligible sibling archive | Normal hosted resolution; native refusal if no compatible public version exists |
| Already-exact public package, no current private archive | Authenticate hosted metadata/archive; no synthetic local producer or republishing |
| Restored consumer already binds copied provider proof | Verify and retain that exact binding, regardless of current public appearance or deleted provider stage |

Exit: command tests for all four unpublished packages, transitive-only edges,
independent versions, hosted fallback, named scope, deterministic ordering,
interruption, unsupported grouping and truthful partial JSON. Assert zero public
mutations and zero publication sessions for both successful and failed stage.
Only then remove `RK-CLI-004` and update bare-stage help.

### 4. Publication boundary

Bare release uses packet 3 to prepare the full frozen scope first. Aggregate
warnings and exact staged claims, then obtain the one publication confirmation.
Re-read destination truth and stage/source/toolchain identity at the existing
boundaries. Do not implement this as two calls to the current `_release`, which
mixes private and public work and checks public prerequisites too early.

Project public dependencies using the frozen native graph together with original
runtime requirements and their provenance, including hosted transitive edges.
Name-based reachability alone is insufficient: Pub root development requirements
can shadow the same runtime name. If runtime requires core `^0.1.0` but a root
dev requirement selects private core `^0.2.0`, that private selection must not
become a public core `0.2.0` prerequisite. The fresh public consumer still has to
resolve the original runtime `^0.1.0` requirement. A selected provider creates an
exact-public obligation only for runtime requirements it actually satisfies.
Dev/build-only inputs do not create package publication prerequisites. Keep
target-specific Git tag, GitHub and Homebrew ordering in their existing owners.

Before the existing publication coordinator records an attempted/possibly-acted
operation, run a read-only blocking gate for exact selected first-party public
archive identity and the fresh external-root runtime resolution described above.
Use the existing pre-act gate seam; putting these checks inside `module.publish`
would incorrectly report a no-upload refusal as a possibly acted publication.
The existing post-publication availability warning is not this blocking gate.

Match every relevant provider's declared registry. Record the public resolution
separately; it may legally select another compatible version under a broad range.
After the gate, refresh stage/context and the final destination read, then upload
the same verified archive. Never repackage after public checks. Named release
must stop if a required unpublished provider is outside its public scope.

Exit: event-order tests prove every unit is prepared before confirmation or the
first public mutation; a late preparation failure causes zero public mutations
and zero publication-session acquisitions.
Native probes cover mismatched public bytes, propagation lag, dev-helper
exclusion, workspace metadata, runtime resolution failure, broad ranges, a
runtime/dev diamond and a same-name dev requirement shadowing runtime.
Pre-act gate refusals report blocked/not-attempted, never attempted/may-have-acted.
Partial publication resumes exact completed public work with unchanged bindings;
source/endpoint/stage drift after confirmation cannot widen the authorized act.

### 5. Qualification and documentation

Run the full RK suite and targeted native cases on CI SDK 3.12.2 and current
stable. Retain supported minimum 3.10.4 archive/direct-executable coverage; report
the independently reproduced macOS AOT-bundle limitation separately.

Dogfood the actual CLI in an isolated Fleury checkout with unchanged release
configuration: one bare stage for four packages, repeat reuse, named consumer
reuse and provider cleanup, archive inspection, generated-app compilation and
package/test smoke workflows using the staged bytes. Record source/RK/SDK IDs,
archive hashes, warnings and selected dependency provenance. Scripted native
packaging alone is not this acceptance test.

Update help, README, refusal codes, JSON schema/docs, pipeline docs and the
superseded repository plan in the same delivery. Source-only `rk plan` must still
perform no network, compiler, cache write or publication-session operation.
Review the final production diff independently; do not equate prior bounded
approvals or green focused tests with complete feature approval.

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
| Runtime/dev shadow | Private core 0.2 selected by dev constraints does not replace original runtime core ^0.1 public requirements or invent a core 0.2 publication edge |
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
Both required the native mechanism evidence before integrating later slices;
that mechanism has since passed its gate. The next work is the remaining
implementation packets above, not a restart of the original proof.

The current remaining-work review found and incorporated durable incomplete
receipts, transitive portable proof closure, scope-independent frozen reuse,
already-public provider handling, and separation of private preparation from
public prerequisites. The native review also tightened effective workspace-lock
handling, helper source authority, runtime/dev shadow semantics, observational
status, and placement of public checks before attempted-upload accounting.

Both reviewers reread the revised five-packet plan and approved starting packet 1,
with no remaining planning blocker. The architecture reviewer requested two final
wording corrections (baseline labeling and distinguishing public reads from
mutations); both are incorporated. The native review's final helper/runtime/status
clarifications are incorporated in packets 1/4 and the output contract. This
approval covers implementation readiness, not command behavior or publication
qualification. No user product decision remains pending.


## Current implementation evidence

This is a snapshot after the source/binary-lock integration, not an additional
execution backlog. Earlier
slice results are superseded by the current evidence below.

| Implemented foundation | Evidence and qualification boundary |
| --- | --- |
| Native mechanism | `664a7c1`: real conflict/backtracking, unchanged manifests, archive replay, compile and external-root fixtures across Dart 3.10.4, 3.12.2 and 3.13.5; see the native proof document |
| Generic dependency facts and receipts | Opaque native identity/context/slot/phase model; independent-version fallback; imports, external archives and same-unit producer handoff; non-Dart coordinator fixture |
| Native discovery and archive fidelity | Bounded hosted metadata discovery, transitive local candidates, guarded native archive reader, original-registry cache replay, full manifest/graph/hash/payload checks and signed URL redaction |
| Shared Pub and binary producers | `7b62807`: real packaging and BinaryChain compilation use bound archives, preserve warnings/manifests, and record actual graph/hash evidence; production CLI does not bind these automatically yet |
| Frozen native verification | `f8ecd5b`: authenticates exact external metadata and current supplied local candidates, then re-solves only frozen choices and compares causal graph; caller still must authorize roots/provider provenance/adoption |
| Source and binary lock policies | Native contexts format 2 bind the effective source lock path/hash. Discovery preserves original native preferences through refinements and separately authenticates committed external hashes. Shared preparation installs the ordinary/workspace lock in its detached root. Native workspace listing validates membership and SDK syntax before detachment; bound source reads always use the selected Git commit. Development-helper exceptions remain pending. |

The architecture and native reviewers approved the bounded producer integration;
the native reviewer approved the frozen verifier primitive. Analysis was clean.
The broader native/stage/producer/Pub/phase run passed 381 tests, and the latest
focused verification/preparation/graph run passed 30. Stable SDK passed the 20
bound native cases; five frozen-choice cases passed on minimum and stable SDKs.
These recorded runs are not a final full-suite result for the remaining work.

All four Fleury native archives were prepared from committed source
`14d76107b6ba468b44e75c120390eddca271b307`; the three dependents used the exact
newly staged Fleury archive. All four saved resolutions were subsequently
reauthenticated against current registry metadata without changing their choices.
MCP and web retained native exact-version warnings. No real publication occurred.
This is native-mechanism evidence, not completed bare-command dogfood.

Dart 3.10.4 passes archive preparation and direct executable cases. Its macOS
`compile aot-snapshot` emits ELF for the current fixture while RK's existing
bundle path requires Mach-O; a dependency-free probe reproduced the limitation.
Minimum-SDK macOS bundle qualification remains explicitly outside the evidence.

The source/lock slice passed 418 broader source/stage/binary/phase regressions,
followed by 67 affected native tests after the final workspace guard fix. Analysis
is clean. Twelve lock/source and actual bound binary cases pass on each of Dart
3.10.4 and 3.13.5; the final excluded/nested/malformed workspace guard also passes
on both. Review found and closed unsupported legacy lock parsing, unauthenticated
workspace membership and arbitrary snapshot fallthrough under a Git identity.
The native reviewer approved this bounded slice. These tests do not qualify
development helpers, frozen-stage adoption or automatic repository CLI execution.

Context format 1 cannot authorize this new operation policy and is explicitly
refused; format 2 records even the absence of a binary lock. Normal legacy stages
without native contexts retain their existing path. Receipt/index adoption and
its explicit migration behavior remain packet 2.
