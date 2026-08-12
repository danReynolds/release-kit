# Initialization, targets, and release artifacts

Status: implemented and validated, 2026-08-12. Schema 2, scoped
typed targets, explicit optional Git tagging, project-owned binary platforms,
project-qualified producers, aggregate release assets, manifest-bound
destination artifacts, optional-Git evidence, compact initialization, and
late native credential acquisition are current behavior.

## Outcome

`rk init` should discover facts, present release choices, and write a small
`release.toml` only after explicit review. Native project manifests remain the
authority for package identity and package contents. `release.toml` records
the release decisions those manifests cannot answer: which public targets to
use, how projects form a release unit, and what standalone artifacts to build.

The implementation should also separate three concepts that are coupled in
the alpha:

1. A **producer** builds one or more typed local blobs.
2. A **release-asset contribution** deliberately exposes one produced blob
   under an exact public name.
3. A **target** publishes exact inputs to a destination and reads them back.

The GitHub Release target therefore does not own binary production and does
not upload an arbitrary build directory. It collects the unit's explicit
release-asset contributions, rejects collisions, adds aggregate metadata, and
publishes the resulting inventory.

## Decision status

### Low-regret corrections adopted

The reviews found several corrections that tighten the design without adding
user-facing concepts:

- destination exactness is independent from source binding;
- a staged blob's private path/kind is separate from its contributed public
  filename;
- bundle metadata is frozen locally before tag creation;
- an ambiguous multi-project repository receives no default per-package tags;
- `binary_platforms` is Dart-producer configuration, not a universal build
  matrix;
- non-Git discovery follows native workspace membership rather than a generic
  recursive scan;
- init remains static and does not execute repository code to resolve dynamic
  metadata;
- credentials arrive after local producer work; and
- Git tag and GitHub read-back include their managed metadata, not only names
  or version presence;
- `binary_platforms` enables the current standalone Dart producer without a
  generic `produce` key;
- producer-owned settings and every staged producer identity are qualified by
  project, allowing several standalone producers in one release unit;
- producer facts such as signing identity are derived from published artifacts
  or native producer metadata instead of copied into `release.toml`;
- an explicitly selected GitHub Release may contain only its changelog body
  and release manifest when no producer contributes downloadable assets;
- a Homebrew formula is published only to its canonical tap, not duplicated as
  a GitHub asset; and
- init remains an on/off selector. Required customization happens in the
  generated TOML rather than an interactive form.

Several other changes are large implementation work but not product choices:
safe/exact GitHub draft recovery, credential sequencing, optional-Git stage
identity, and producer qualification should remain fail-closed engineering
requirements rather than additional configuration surface.

## Product rules

### Native configuration stays authoritative

Use `pubspec.yaml`, `package.json`, a project `.npmrc`, a gemspec, `Cargo.toml`,
`pyproject.toml`, or the relevant native build configuration for:

- package name and version;
- registry destination, access, and native publication vetoes;
- which source files belong in a registry package;
- native executable declarations; and
- ecosystem-specific build and packaging behavior.

Do not copy those settings into `release.toml`. `rk` should invoke read-only
effective-metadata and native pack/build operations where literal manifest
parsing is insufficient, then inspect their exact output rather than
reimplementing file-selection rules. It must redact credential-bearing URLs
and values from the init plan, TOML, receipts, diagnostics, and JSON.

The same rule applies to producer mechanics. Existing published artifacts,
native bundle metadata, toolchain conventions, and declared executable names
are authoritative for facts such as a macOS signing identifier. `rk` should
record and disclose the resolved value, but not ask the operator to restate it.
An override belongs in the schema only after a concrete case demonstrates that
the underlying producer cannot express or derive the required value.

### Infer coordinates, not audience

Infer or preselect a target only when the repository declares a usable
coordinate at that destination. A capability does not state an audience.

- A publishable Dart package declares a pub.dev coordinate.
- An npm package can declare a registry coordinate and can veto publication
  with `private` or native registry configuration.
- A usable Git remote declares a place where a tag can be published.
- `executables`, npm `bin`, Python console scripts, a `Dockerfile`, or an app
  project declare capabilities. They do not declare standalone distribution.
- A GitHub remote supplies the address for a GitHub Release, but not the intent
  to create one.

Every adapter owns the exact native evidence sufficient to infer its registry
target. It reports these facts separately:

```text
coordinate
destination
destination evidence: repositoryDeclared | ecosystemDefault | ambient | ambiguous
publication veto, if any
redacted provenance for the decision
```

Init preselects a registry only when the effective native publication command
resolves to one stable repository-declared or ecosystem-default destination
and no veto applies. Ambient user or machine configuration is shown as
ambiguous until the operator makes it repository-stable through the native
tool's configuration. Account ownership and write authority are not init
facts; release preflight owns them. Staging recomputes the effective endpoint
and binds it into the plan. An adapter must retain vetoed and ambiguous
projects in the init model with a reason rather than silently turning
uncertainty into publication intent.

Native metadata and build commands are repository code and may execute hooks.
Init performs static discovery only. If static native configuration cannot
resolve a coordinate or version, the candidate remains unresolved and
unselected; init does not run a build backend, Gradle configuration, or other
repository code to improve the guess. Later status/release work may run native
commands under their explicit contracts. Run producer work before acquiring
or refreshing publication credentials, and never inject provider credentials
into producer environments. `rk` cannot sandbox a hook from credentials
already available to the same OS user; that ambient same-UID boundary remains
an explicit local-operator limitation.

### Configuration records decisions, not observations

Persist choices that must remain stable across `rk` upgrades. In schema 2,
`binary_platforms` is specifically the explicit public-platform inventory for
the existing standalone Dart CLI producer. `rk init` may propose the platforms
supported by the installed `rk`, but only after the operator selects a target
that needs that producer. It must write the exact reviewed list so a later
`rk` release cannot silently add a platform or public filename.

Do not claim this is a language-neutral build matrix. Rust target triples,
Python wheel tags, Go build variants, OCI platforms, and mobile flavors may
need different producer settings. Add a producer namespace only after a
second real standalone producer demonstrates the common shape.

Do not persist derived defaults merely to show that discovery worked. A
conventional Homebrew tap, for example, should remain absent from the file
unless the operator overrides it.

### Git is a capability, not a prerequisite

Projects without Git can use registry targets whose native publisher supports
them. They cannot use `git-tag`, GitHub Release, or the planned Homebrew flow.

Do not invent a directory hash and present it as a source identity. Exact
staged artifacts still receive content hashes, so `rk` can prove what bytes it
published. What is unavailable is comparison to an immutable source revision.

Destination exactness and source binding are independent facts:

```text
target verdict:     absent | exact | conflict | unknown
source binding:     gitCommit | unbound
source comparison:  exact | unavailable
```

A non-Git publication can therefore be remotely `exact` while source
comparison remains `unavailable`. Source unavailability must never weaken the
destination byte or inventory comparison an adapter can perform. A future
provider may also expose a native lifecycle state such as processing or
review; that is additive to these facts.

Destination `exact` also requires a retained expected payload or digest. While
an unbound stage exists, `rk` may compare a downloaded registry payload to it.
After that stage is deleted, status can report authenticated presence but the
target verdict becomes `unknown` unless the provider exposes a durable digest
already bound to rk's expected payload. Deleting a completed unbound stage
therefore weakens later auditability and never authorizes another act.

Schema 2 does not support cross-invocation reuse of an unbound pre-publication
stage. A non-Git release must build, validate, authorize, and begin publication
in one invocation. After any public act, that exact stage becomes mandatory
for recovery. Git-backed or not, loss of a recovery-critical stage refuses
further publication whenever a remaining step consumes its bytes. A source
commit is not proof that signatures, notarization, or archives can be
reproduced byte for byte. A future cross-invocation design must add full stage
identity to both TTY and unattended authorization; `--confirm=<version>` alone
is insufficient.

For Git-backed releases, retain the clean-tree refusal even when `git-tag` is
not selected. It is an operator guard, not the source-closure proof. All
producers run from the staged source closure rather than the worktree;
adapter-owned generation happens inside that closure, path escapes refuse,
and submodule, LFS, ignored-input, and external-source behavior must be
explicitly supported or refused.

## Model and terminology

### Release units and projects

A **project** is one native package or build root. In schema 2, a **release
unit** is the set of projects that share one version, unit-scoped targets, and
public release metadata. Independent project versions in one coordinated
event are a future model: `rk` must not choose one child version as the unit's
tag or release version.

The schema 2 built-ins declare their allowed attachment point:

- **project-scoped:** registry publication such as `pub.dev`, `npm`,
  `rubygems`, `crates.io`, or `pypi`, plus the executable-specific `homebrew`
  formula target;
- **unit-scoped:** `git-tag` and `github-release`.

The single-project shorthand may mix both scopes in one `publish` list. A
multi-project unit puts unit-scoped targets on the unit and project-scoped
registry/Homebrew targets on each project row. Configuration validation—not
target implementation—owns this distinction.

Standalone producer intent belongs to the project that can build it,
independently of the unit destination. The proposed minimal schema uses the
producer's required setting as that explicit intent:

```toml
binary_platforms = ["macos-arm64", "linux-x64"]
```

The presence of `binary_platforms` is the persisted decision that an
executable capability should become standalone archives. It is not inferred
from, or owned by, GitHub. Selecting GitHub alone does not enable it because
metadata-only releases are valid. Selecting Homebrew for a project requires
and enables that project's producer with a reviewed platform list.

A stable producer id derived from the resolved project qualifies every local
step, checklist id, receipt producer name, workspace path, and artifact
reference. A unit may therefore aggregate multiple standalone producers.
Public filenames remain intentionally unqualified and must be unique across
the release. `homebrew_tap` stays a unit-level default/override shared by its
project formula targets; a future concrete need can add per-project tap
overrides.

This is not asserted as a universal property of future ecosystems. A native
project may later expose multiple named publications or multiple destination
bindings. Internally, init candidates and target identities must therefore be
keyed by project plus destination coordinate, not only by a target kind such
as `npm`. Schema 2 supports at most one binding of each current registry kind
per project; a concrete second-destination use case can extend the schema.

Init version one should not guess multi-project release grouping. It proposes
one candidate per native project. When a repository contains more than one
viable project and no adapter supplies a unique native grouping and tag
convention, project registry targets remain selectable but unit-scoped targets
start unselected with `release grouping required`. The operator can remove
candidates in the selector and can hand-edit TOML to create shared units. A
future grouping feature needs explicit native evidence or its own reviewed
interaction.

### Producers, contributions, and targets

A **producer** performs local work and returns typed staged blobs. The minimal
local `ProducedBlob` needs:

```text
owner project or unit
stage-relative path
content digest and size
media type
producer-owned kind and optional variant
```

Stage path and public name are deliberately different fields. A
`ReleaseAssetContribution` carries the producer id, references a
`ProducedBlob`, and adds one validated `publicName`. Public names may not
contain separators, control characters, dot traversal, or collide under the
destination's normalization rules;
`SHA256SUMS` and `release-manifest.json` are reserved.

Not every staged blob is public. Initial producer kinds are intentionally
small:

- `registryPayload`: one member of a set consumed by a native publisher;
- `standaloneArchive`: a downloadable executable archive;
- `installerManifest`: an installer formula or manifest;
- `evidence`: logs, notarization responses, and other stage-local proof.

An exact contribution promotes a produced blob into the unit's release-asset
inventory. Producers do not name GitHub. A standalone CLI archive normally
gets that projection; a pub archive, npm tarball, gem, crate, wheel, debug
directory, or notarization log does not by default. Registry adapters may
return a `RegistryPayloadSet` because one publication can contain several
files. An installer producer can separately project its manifest as a release
asset while also handing the same blob to its installer target.

Remote-first products such as OCI indexes and store-managed builds may
eventually need a `RemoteSubject` identified by coordinate and provider digest
rather than a stage-relative blob. Reserve that seam in the terminology, but
do not implement it in schema 2.

The implementation should use concrete contribution types and simple
before/after producer ordering. It should not introduce a plugin registry or
a general artifact DAG. If a second release host later consumes the same
inventory, the shared `ReleaseBundle` abstraction can be extracted from two
real consumers rather than predicted now.

### GitHub Release assembly

Before authorization, a concrete local GitHub bundle-assembly step:

1. Collects every `ReleaseAssetContribution` in the release unit, including
   any explicit projection of an installer manifest.
2. Validates their already-declared public filenames without accepting globs.
3. Refuses duplicate filenames, even if the bytes happen to match.
4. Generates `SHA256SUMS` over every contributed blob, excluding the checksum
   file and manifest themselves, when contributed blobs exist.
5. Generates `release-manifest.json` containing the contributed blob
   inventory, the checksum-file digest when present, the resolved plan and
   coordinates, and the available source binding. The manifest excludes
   itself to avoid a recursive digest.
6. Freezes the title as `<unit> <version>`. A single-project body is that
   project's changelog entry. A multi-project body concatenates every
   project's required entry in declaration order under deterministic project
   headings.
7. Freezes the complete rk-managed filename and digest inventory in the stage.

The annotated Git tag binds the frozen manifest digest. The GitHub target only
publishes those staged bytes and the frozen body. GitHub-generated source
archives are outside rk's managed asset inventory.

GitHub publication is an idempotent multi-call state machine:

1. Create or adopt only an rk-identifiable draft for the exact tag and frozen
   plan.
2. Accept an interrupted draft only when its existing assets form an exact
   verified prefix of the expected inventory.
3. Upload missing assets; any unexpected name or differing bytes conflict.
4. Verify the complete draft inventory, then publish it.
5. Read back the published release and exact rk-managed inventory.

Do not delete, replace, or sweep unexpected remote assets automatically.
Draft adoption and final exactness compare the tag, title, body,
draft/published state, manifest, and every rk-managed asset. Differing managed
metadata is a conflict even when all asset bytes match. Git-tag exactness
separately verifies both the remote peeled commit and the annotated manifest
digest.

A GitHub Release with no producer-contributed assets is valid when the user
explicitly selects that target. It publishes the unit/version title, the
changelog entry as its body, and `release-manifest.json`. The manifest records
an empty contributed-asset inventory plus the tag/source and target bindings;
`SHA256SUMS` is omitted. GitHub's own generated source archives remain outside
rk's managed inventory.

GitHub Release requires a verified immutable tag/source binding. In the first
implementation only a selected `git-tag` target can satisfy that prerequisite.
The permanent target interface must not assume rk owns tag creation, because a
future version may adopt an exact externally managed tag.

Unusual user-provided files are deferred. When needed, add an explicit typed
asset producer with exact paths and validation rather than arbitrary globs on
the GitHub target.

### Homebrew

The supported Homebrew path is a formula in a remote Git tap whose archives
come from the same unit's GitHub Release:

```text
homebrew -> github-release -> git-tag
```

Each project selecting Homebrew contributes one explicit install contract. It
names that project's archive references, executable names, and validated
install mapping; the current Dart producer still permits one executable per
project. A unit may publish several formula targets to the same tap.
Before any public action, run every safe non-mutating tap and credential
preflight the provider supports. Readability is not proof of write authority,
so unprovable permissions remain a named publish-time risk.

Derive the ordinary case from the source GitHub repository:

```text
source repository:  owner/repo
tap:                owner/homebrew-tap
formula path:       Formula/<executable>.rb
```

One tap may hold many formulae. Only a nonstandard tap needs configuration:

```toml
homebrew_tap = "some-org/homebrew-tools"
```

Arbitrary non-GitHub tap remotes and a local-directory tap workflow are not in
the first implementation. They can be added when a real publication case
defines the authentication, comparison, and recovery contract.

The Homebrew producer creates one formula blob and gives it only to the tap
target, its canonical destination. It does not contribute the formula as a
GitHub release asset. The release manifest still records the formula digest,
tap coordinate, and formula path so the release remains auditable without
duplicating the consumer-facing file.

## Proposed schema 2

The common single-project Dart CLI stays small:

```toml
schema = 2

[release.rk]
publish = ["git-tag", "pub.dev", "github-release", "homebrew"]
binary_platforms = ["macos-arm64", "linux-x64", "linux-arm64"]
```

The conventional Homebrew tap is derived and omitted. A custom tap is the
rare flat override:

```toml
[release.rk]
publish = ["git-tag", "pub.dev", "github-release", "homebrew"]
binary_platforms = ["macos-arm64", "linux-x64"]
homebrew_tap = "some-org/homebrew-tools"
```

Keep this sparse flat override until a target has enough genuinely optional
settings to justify a scoped table. Do not add nesting merely for symmetry;
`binary_platforms` describes production shared by multiple targets.

A multi-project unit separates scopes:

```toml
schema = 2

[release.framework]
tag = "fleury-v{version}"
publish = ["git-tag", "github-release"]

[[release.framework.project]]
path = "packages/fleury"
publish = ["pub.dev"]

[[release.framework.project]]
path = "packages/fleury_test"
publish = ["pub.dev"]
```

The repeated `[[release.framework.project]]` header is TOML array-of-tables
syntax: each occurrence appends a different project row to the same
`framework` release unit. The rows intentionally share a unit because they
share one version, tag, GitHub Release, and changelog composition. Their native
manifest identity and path distinguish them; rk derives stable internal
producer ids rather than asking for another config name.

A unit may also aggregate several standalone producers:

```toml
[release.tools]
publish = ["git-tag", "github-release"]

[[release.tools.project]]
path = "packages/server_cli"
publish = ["pub.dev", "homebrew"]
binary_platforms = ["macos-arm64", "linux-x64"]

[[release.tools.project]]
path = "packages/admin_cli"
publish = ["pub.dev"]
binary_platforms = ["macos-arm64", "linux-x64"]
```

Both projects contribute archives to one GitHub Release. Only `server_cli`
publishes a Homebrew formula. Internally their build and archive steps are
qualified by their derived project ids; public filename collisions still
refuse during private bundle assembly and before publication.

There is one `publish` vocabulary, not a second `targets` key. The target
catalog declares the valid scope of each entry and produces a precise error
when it appears at the wrong level.

Schema 2 validation should reject unused or contradictory intent, including:

- `tag` without `git-tag`;
- `homebrew_tap` without `homebrew`;
- `binary_platforms` without a selected target that consumes the standalone
  archive contributions;
- a Dart project declaring `binary_platforms` without exactly one executable;
- project-scoped targets on a multi-project unit;
- unit-scoped targets on a project row, or project-scoped targets such as
  `homebrew` on a multi-project unit table;
- GitHub Release without a satisfiable immutable tag binding or usable GitHub
  coordinate;
- a project selecting Homebrew without GitHub Release, binary platforms, or
  exactly one installable contribution;
- duplicate tag coordinates across proposed units; and
- two release-asset contributions with the same public filename.

This is a pre-alpha contract change, so schema 2 replaces schema 1 without a
compatibility or migration layer. Existing dogfood configurations are updated
directly. An unsupported schema receives a concise diagnostic; `rk` does not
rewrite it automatically.

## Initialization experience

### Discovery model

Discovery produces a pure `InitPlan` before any rendering or writing. Each
candidate contains:

```text
native project identity and path
native version and publication coordinate
capabilities such as executables
available targets and prerequisites
initial selection
why each target is selected, available, or unavailable
derived defaults and unresolved required decisions
```

Native adapters also declare their source requirement: `none`, `vcsMetadata`,
or `immutableRef`. Git discovery uses tracked files. Without Git, discovery
starts at the root manifest and follows only explicit native workspace
membership. It does not recursively follow symlinks or nested repositories;
fallback filesystem matches are ambiguous, unselected candidates rather than
publication proposals.

Keep native publication vetoes, private packages, workspace roots, examples,
fixtures, and ambiguous manifests in this plan. The selector can explain why
they are unselected or unavailable. Discovery should not make them disappear.

The pipeline is:

```text
scan -> InitPlan -> optional TTY edits -> render TOML
     -> parse and resolve through rk itself -> preview -> final confirm -> write
```

`rk` never overwrites an existing `release.toml`.
The final preview includes the exact `.gitignore` addition when `.rk/` is not
already ignored, and one confirmation authorizes both files. The config write
uses create-new/exclusive semantics so a concurrent `release.toml` creation
cannot be overwritten.

### Compact TTY selector

For initial setup without a config, show one row per discovered candidate,
one producer toggle, and one column per currently supported destination. Group
the producer separately so it is not mistaken for another publication target:

```text
Select release outputs

                         Produce              Publish
  Use  Unit              Binary    Tag    pub.dev   GitHub   Brew
› [x]  rk                [ ]       [x]    [x]       [ ]      [ ]

  GitHub Release — changelog + manifest, plus selected binary archives

  ↑↓ unit   ←→ option   space toggle   enter review
```

Controls:

```text
up/down       move between units
left/right    move between on/off cells
space         include a unit or toggle the selected cell
enter         review the generated TOML
```

`[x]` means selected, `[ ]` means available, and `—` means unavailable. The
focused cell's one-line explanation says what it does or why it cannot be
selected. Cascades report one short consequence such as `Homebrew also enabled
Binary, Tag, and GitHub`; they do not open another prompt.

Toggling `Use` off removes that candidate from the proposal and dims the row;
toggling it back on restores the row's selections from this session. Enter
shows the exact TOML and incidental `.gitignore` patch, with one way back to
the matrix and one final write confirmation.

When the terminal is too narrow for the matrix, render the focused unit as a
vertical card rather than truncating labels or scrolling horizontally:

```text
› rk
  [x] Use
  [ ] Binary
  [x] Git tag
  [x] pub.dev
  [ ] GitHub
  [ ] Homebrew
```

The controls and dependency behavior remain identical in both layouts.

Init has no field editor. Selecting `Binary` writes the exact current supported
platform list into the TOML proposal. The operator changes that list in the
file. For macOS, the producer derives an established identifier from the
published binary, a native bundle identifier when present, or the executable
name on a first bare-CLI release. The stage preview discloses the resolved
identifier before signing, but init does not add identity configuration.
Custom taps and every other necessary override are file edits.

Selection dependencies are visible and deterministic:

- selecting Homebrew selects GitHub Release, Git tag, and the compatible
  `Binary` cell;
- selecting GitHub Release selects Git tag;
- selecting `Binary` selects GitHub Release and Git tag;
- deselecting a prerequisite deselects its dependants;
- target and producer changes remain simple on/off cascades.

The initial selection is conservative:

- native registry coordinate: selected unless the native project vetoes or
  makes the destination ambiguous;
- Git plus a usable remote and one unambiguous release unit/tag convention:
  Git tag selected;
- multiple viable projects without native grouping/tag evidence: unit-scoped
  targets available but unselected with `release grouping required`;
- Git without a usable remote: shown but unavailable with the required fix;
- GitHub Release and Homebrew: available but unselected;
- executable declaration: exposes standalone distribution capability but
  selects no target;
- workspace roots, private packages, fixtures, and examples: visible but
  unselected or unavailable; and
- non-Git project: native registries remain available; Git tag, GitHub
  Release, and the planned Homebrew flow are unavailable.

Raw terminal mode must be restored in `finally` on Enter, Ctrl-C, EOF, and
exceptions. Narrow terminals, `TERM=dumb`, redirected input/output, and
non-TTY execution must emit no cursor-control sequences.

### Noninteractive behavior

- `rk init` without a usable TTY prints the conservative proposal and writes
  nothing.
- `rk init --write` accepts exactly that conservative proposal.
- `rk init --json` returns candidates, target availability, selection,
  dependency effects, and reasons as structured data. This requires a JSON
  contract bump; assign the exact schema number when `doc/json.md` is amended.

Do not add a large flag surface for configuring every target noninteractively
until an automation use case demonstrates that JSON plus a hand-authored file
is insufficient.

## Framework and ecosystem expectations

The producer/target split must survive these cases without making their
native package payloads GitHub assets by accident.

| Ecosystem or project | Native registry evidence | Capability that does not imply standalone distribution | Normal producer and target behavior |
| --- | --- | --- | --- |
| Dart package | publishable `pubspec.yaml` | `executables` | Native pub archive goes only to pub.dev; the existing Dart CLI producer contributes reviewed `binary_platforms`. |
| npm package/workspace | effective `package.json`, `publishConfig`, project `.npmrc`, and no native private veto | `bin`, bundled frontend output | `npm pack` owns package contents; its tarball is registry payload, not a GitHub asset. Multiple registries require a future binding model. |
| Ruby gem | gemspec identity and host configuration | gem executables | `gem build` owns the `.gem`; standalone archives require a separate producer. |
| Rust crate | `Cargo.toml` registry publication settings | binary targets | `cargo package` owns the crate payload; cross-built binaries are separate release assets. |
| Python package | effective identity and unambiguous index configuration; `pyproject.toml` alone may not name one | console scripts | a payload set of wheels and sdists goes to the index; standalone binaries/installers require an explicit producer. |
| Go module or CLI | module path plus its Git-root and tag convention | `package main` | the tag is often the package release and may be subdirectory-prefixed; downloadable binaries require an explicit producer. |
| Maven/Gradle package | effective named publication and repository binding | application plugin or runnable JAR | Native publication owns its artifact set; multiple publications and repositories are a future binding extension. |
| Docker/OCI image | explicit image repository and registry | `Dockerfile` or compose service | The canonical result may be a remote digest rather than a local blob; OCI waits for the remote-subject and lifecycle model. |
| Flutter/mobile app | store application ID plus explicit release configuration | presence of an app target | App stores, signing, tracks, and review are explicit future targets; no target is inferred from the project type alone. |
| Framework monorepo | per-package native coordinates | examples, CLIs, generated docs | Init proposes candidates, not grouping; unit-level announcements can carry no downloads. |

An adapter is ready only when it can answer five questions using native
semantics:

1. What is the project coordinate and version?
2. Is publication explicitly vetoed, redirected, or ambiguous?
3. Which native command materializes the exact registry payload?
4. Which declared capabilities can back optional typed producers?
5. Which public facts can `rk` read back exactly after publication?

Registry adapters also declare one of two publication modes:

- `prebuiltPayload`: the native publisher accepts the exact staged payload set
  that rk validated; or
- `nativePublishTransaction`: the native command couples packaging, signing,
  or upload, and the adapter defines how expected identity is established
  before the act and proved by provider read-back afterward.

An adapter that cannot establish that identity safely is unsupported. A
`RegistryPayloadSet` is therefore available where native semantics permit it,
not a mandatory fiction for Cargo, Maven/Gradle, or other coupled publishers.

The current targets preserve the invariant that local blobs and validation
finish before the first public act. Remote-first targets such as OCI and app
stores may later need explicit `prepare`, `commit`, and `observe` phases and a
provider-native lifecycle state. That future seam must not weaken the
first-irreversible-action boundary or exact read-back rules of current targets.

Within a release unit, selected public targets retain the simple current
order: `git-tag` when selected, registry publications in native dependency
order, `github-release`, then `homebrew`. Omitted targets disappear from the
graph; dependencies, rather than a second configurable ordering surface,
determine the remaining sequence.

## Implementation sequence

### Phase 1: schema and target scope

- Amend RFC 0002 and `doc/json.md` before changing behavior.
- Add schema 2 and explicit `git-tag` to `publish`.
- Separate `UnitConfig.publish` from `ProjectConfig.publish`.
- Make `binary_platforms` a project-owned producer setting in schema 2; retain
  `tag` and `homebrew_tap` as unit settings.
- Make tag derivation and checklist emission conditional in schema 2, remove
  `publish` as an unconditional inline-project discriminator, and let
  unit-scoped target expectations exist without a single `target.project`.
- Move producer settings to the project that builds the artifacts and validate
  them independently from the unit destination.
- Put target scope, prerequisites, and applicability in the built-in target
  descriptors.
- Validate sparse overrides and contradictory intent.
- Treat project/unit attachment as the current built-in schema, not a promise
  that future target kinds have only one binding per project.

Primary seams: `lib/src/engine/config.dart`,
`lib/src/engine/resolve.dart`, and `lib/src/targets/catalog.dart`.

Phase 1 review record: three independent reviews challenged current Dart DX,
future polyglot extension, and operator/recovery safety. Hardening retained the
austere public schema and added these implementation constraints before moving
on: several tagged units require explicit stable tag namespaces; target
identity survives alongside lifecycle kind in JSON and catalog routing;
prerequisites and archive-consumer capability live with built-in target
metadata; untagged releases do not depend on pushed HEAD or tag-signing policy;
and completed stages validate their manifest unit, version, and nullable tag.
The review also confirmed that the remaining one-binary-project and
binary-required GitHub restrictions are temporary Phase 2 limitations, not
schema promises.

### Phase 2: typed artifact contributions

- Remove the current one-binary-project invariant. Qualify local steps,
  checklist ids, receipts, workspaces, and artifact references with stable
  resolved project/producer ids.
- Replace the GitHub target's direct dependency on one Dart binary project
  with `ProducedBlob` and exact `ReleaseAssetContribution` records.
- Have the existing standalone Dart producer contribute platform archives.
- Have each project selecting Homebrew emit one explicit install contract and
  give its formula blob only to its tap target. Record formula digests and
  destinations in the release manifest without adding them to GitHub assets.
- Add local bundle assembly before authorization: validate names, detect
  collisions, generate checksums after all contributions, and generate the
  release manifest. Move checksum ownership out of the current one-binary
  producer pipeline.
- Carry producer ids, blob references, public names, and generated bundle
  ownership through stage contracts, receipts, stage inspection, status rows,
  and the manifest.
- Make GitHub publication resume an exact draft prefix and refuse all other
  partial remote inventories.
- Support explicitly selected metadata-only GitHub releases with a changelog
  body and release manifest but no checksum file.

Primary seams: `lib/src/engine/assets.dart`,
`lib/src/engine/checklist.dart`, stage contracts, and
`lib/src/targets/github_release_target.dart`.

Phase 2 review record: the expedited blocker audit checked multi-producer
identity/signing/storage, destructive GitHub recovery, release-versus-
destination manifest inventory, lost-stage refusal, metadata-only releases,
and future producer seams. It found no current safety or configuration
blocker. One future implementation seam remains intentionally internal:
standalone contribution discovery is still assembled by the current Dart
producer adapter. A second producer ecosystem should move that collection
behind built-in producer adapters without adding a generic TOML `produce`
key. The full suite exposed and fixed two stale pre-qualification signing
fixtures; focused stage, destination, status, and interruption suites are
green.

### Phase 3: optional Git and evidence semantics

- Introduce a source-context abstraction with Git-bound and unbound modes.
- Give adapters explicit source requirements. Without Git, follow only the
  root manifest and declared native workspace membership; do not perform a
  recursive best-guess scan.
- Bind Git-backed stages to the commit; bind unbound stages only to exact
  staged blobs and build transcript without claiming a source revision.
- Make Git-tag checklist work conditional on selection.
- Preserve destination verdicts and add independent source-binding and
  source-comparison fields to human and JSON status models.
- Refuse cross-invocation reuse of unbound pre-publication stages; document the
  full-stage-identity authorization required before this can be added later.
- Preserve lost-stage refusal after a public act for non-reproducible
  Git-backed and unbound releases alike.

Primary seams: `bin/rk.dart`, `lib/src/commands/init.dart`, source-tree and
stage identity code, status inspection, and `doc/json.md`.

Phase 3 review record: the blocker-only audit found and removed unconditional
pushed-HEAD and tag-signing dependencies from untagged releases, made manifest
coordinates nullable where Git is absent, and refused cross-invocation reuse
of an unbound stage. Destination verdicts remain useful without pretending a
directory hash is a source revision.

### Phase 4: `InitPlan` and selector

- Extract discovery and proposal generation into a pure plan.
- Add adapter-owned native metadata and repository parsing.
- Keep vetoed and ambiguous candidates with reasons.
- Implement the compact raw-key selector with unconditional terminal cleanup.
- Keep selection to unit, producer, and target toggles. Render platform lists,
  and necessary rare overrides into the TOML proposal rather than adding field
  editors.
- Render through the real schema 2 parser and resolver before preview.
- Extend the bumped JSON schema with the same plan and dependency effects,
  with all credential-bearing coordinate components redacted while preserving
  the public destination identity.

Reuse the existing output width and redraw machinery. Do not create a second
terminal renderer.

Phase 4 review record: the shortened audit hardened conservative selection for
examples, fixtures, private packages, custom registries, and ambiguous
multi-package tags. The selector now bounds itself to terminal height,
truncates long unit names, restores terminal mode on every exit, and leaves
all scalar editing to TOML.

### Phase 4b: release readiness and credentials

- Split target readiness into safe ambient preflight and credential/session
  acquisition.
- Run safe non-mutating checks before staging.
- Run all producers and validate the complete stage without rk-supplied
  publication credentials.
- Acquire or refresh target sessions only after that stage is complete and
  before authorization and public acts.
- Freeze and recheck the effective endpoint after credentials are resolved;
  ambient redirection that changes it refuses.

Phase 4b review record: the blocker-only safety, current-Dart, and future-tool
passes found no public configuration concept to add. They did catch one
sequencing hole: explicit `--stage` had skipped safe readiness checks. That
path now runs safe checks but still never acquires publication sessions.

### Phase 5: dogfood

Exercise initialization and staging against:

- release-kit: Dart package plus optional standalone GitHub artifacts;
- Keybay: a library unit and a standalone CLI unit with Homebrew;
- Fleury: many publishable packages, executable capabilities that must not
  imply binary distribution, no default per-package tags, and hand-authored
  multi-project grouping;
- a non-Git registry fixture;
- a custom Homebrew tap;
- two producers that deliberately collide on one release filename; and
- a notes-only GitHub Release.

Add adapter-contract design fixtures for an npm workspace with two registries,
a Rust crate plus CLI, Python dynamic metadata and multiple wheels, a Go
multi-module repository with subdirectory tags, Maven named publications, an
OCI remote digest, and a Flutter app flavor. These are boundary tests for the
model, not promises to implement those targets in this plan.

Do not publish real packages or releases as part of these implementation
tests. Live publication remains a separately authorized gate.

Phase 5 dogfood record: real read-only init runs against release-kit, Keybay,
and Fleury produced conservative schema-2 proposals. Release-kit selected its
root pub.dev package and sole unambiguous tag while leaving standalone binaries
opt-in; Keybay selected its two pub.dev packages without guessing per-package
tags; Fleury selected its public native packages without treating executable
declarations as binary-release intent. A real Keybay PTY run enabled Homebrew
and visibly cascaded Binary, GitHub, and Git tag, then cancelled without
writing. The run exposed long-name and large-workspace layout issues, which
were fixed in the selector.

## Acceptance checks

### Configuration

- Schema 1 is rejected with a concise unsupported-schema diagnostic.
- Schema 2 requires explicit Git tag intent.
- Unit destinations and project producers remain independently expressible in
  single- and multi-project units.
- Two standalone projects building the same platform receive distinct
  checklist, receipt, workspace, and artifact identities before public-name
  collision validation.
- Target scope and unused-option errors point at the exact TOML declaration.
- Cross-unit tag-coordinate collisions refuse before writing or staging.
- Init-generated TOML parses and resolves through the production path.
- An existing or concurrently created config is never edited or overwritten;
  the `.gitignore` patch is previewed and confirmed with the config.

### Init interaction

- Dependency selection and reverse deselection are deterministic.
- Executable declarations expose capability without selecting distribution.
- Ambiguous multi-project repositories do not receive default per-package
  tags.
- No selected init state requires scalar editing. A choice that needs
  hand-authored detail remains unavailable with an explanation.
- Init never executes repository code to resolve dynamic metadata.
- Ctrl-C, EOF, exceptions, and normal completion restore terminal state.
- Pipe, JSON, `TERM=dumb`, and narrow-terminal cases contain no stray escape
  codes and preserve all decisions as data.

### Artifact and target behavior

- Registry payloads never enter GitHub inventory without an explicit typed
  release-asset contribution.
- Two contributions with one public filename refuse before publication.
- Reserved, path-escaping, control-character, case-equivalent, and
  destination-equivalent public names refuse before publication.
- Checksums, manifest, title, notes, coordinates, and managed inventory are
  frozen locally before authorization and tag creation.
- Interrupting GitHub after draft creation, every asset upload, verification,
  and publish resumes only an exact verified prefix.
- GitHub read-back compares tag, title, body, state, manifest, and the exact
  rk-managed inventory and bytes; metadata-only differences conflict.
- Git-tag read-back verifies the peeled commit and annotated manifest digest.
- A selected release with no producer-contributed assets has a changelog body,
  manifest, and no checksum file.
- Every available safe Homebrew preflight occurs before Git tag or any other
  permanent action; unavailable authority proof is reported as a residual
  risk rather than claimed as passed.
- The Homebrew formula is absent from GitHub assets, present exactly in the
  tap, and digest-bound in the release manifest.

### Non-Git behavior

- A non-Git registry release can stage, publish, and read back its payload.
- Status preserves destination `exact/conflict/unknown` independently of
  unavailable source comparison.
- No directory hash is described as a source revision.
- Changing a source drop after staging cannot silently authorize the old
  unbound stage.
- Deleting a completed unbound stage downgrades exactness to unknown unless a
  durable provider digest was already bound to the expected payload.
- Losing an unbound or non-reproducible Git-backed partial stage refuses before
  another public action that requires its bytes.

### Release safety

- Every available safe, non-mutating preflight runs before the first public
  act; immediately before each act, rk re-inspects that exact target.
- All local producers and validation complete before any public target runs.
- The stage freezes destination coordinates, target set, tag, public names,
  blob digests, manifest digest, and plan identity; a changed remote, config,
  or plan refuses authorization.
- Publication credentials are acquired after untrusted producer work and are
  not injected into producer environments or serialized into evidence.
- Repository, ecosystem-default, and ambient destination sources are
  distinguished; a changed effective endpoint refuses before authorization.
- Provider races are adopted only when reinspection proves the exact intended
  result; rk never force-moves a tag or tap update.
- Public target order is Git tag when selected, dependency-ordered registries,
  GitHub Release, then Homebrew, with omitted targets removed from the graph.
- Re-running skips only exact, read-back-confirmed public work.

## Review record

Three independent reviews were incorporated on 2026-08-12:

- a current Dart/Flutter and release-kit implementation review using rk,
  Keybay, and Fleury workflows;
- a future polyglot DX review covering npm, Rust, Python, Go, Maven/Gradle,
  OCI, and Flutter/mobile; and
- a release-operator and evidence-safety review covering partial publication,
  recovery, authorization, credentials, and non-Git source drops.

The same reviewers then re-read the amended plan and challenged only remaining
high-severity assumptions. That second pass added an explicit project-level
producer decision, staged credential acquisition, registry publication modes,
static-only init discovery, durable post-stage exactness rules, and
exact tag and GitHub metadata comparison. The suggested generic `produce` key
was kept out of schema 2; multiple binary projects instead share the same
project-qualified internal model without adding configuration surface.

The reviews changed the plan in material ways:

- project-level `binary_platforms` identifies the standalone contributor
  inside a multi-project unit without adding a second producer vocabulary;
- destination exactness is separate from source binding;
- bundle metadata is assembled and frozen locally before tag creation;
- GitHub publication has an explicit resumable draft lifecycle;
- ambiguous monorepos no longer receive one default tag per package;
- produced blob kind and public release-asset projection are separate;
- Homebrew consumes an installable contract, not a producer count;
- `binary_platforms` is limited to the current Dart CLI producer;
- non-Git discovery follows native workspace membership rather than a generic
  recursive walk; and
- lost-stage, authorization, namespace, and secret-handling rules preserve the
  current fail-closed boundary.

The reviews also confirmed these choices:

- native package tools own registry payload contents;
- executable declarations expose capability but do not imply an audience;
- release-asset contributions stay destination-neutral;
- GitHub accepts no arbitrary globs;
- the sparse flat `homebrew_tap` override is adequate today; and
- a shared release-bundle abstraction waits for a second release host.

Still deliberately deferred:

- adopting externally managed tags;
- automatic multi-project grouping and coordinated independent versions;
- more than one registry binding of the same kind per project;
- a language-neutral build-matrix or generic producer namespace;
- multiple Homebrew installable contributions and non-GitHub tap transports;
- remote-first OCI and app-store lifecycle implementation;
- arbitrary user asset producers, plugin registries, and a general stage DAG;
- signed-tag policy, attestations, durable remote staging, and cross-machine
  recovery.

No open review question adds another schema key. Future ecosystem adapters may
still force new choices, but they should be introduced by concrete producer or
destination requirements rather than predicted now.
