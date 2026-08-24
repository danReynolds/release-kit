# RFC 0002: rk core

> Engineering contract from implementation, not the public pitch. See the
> [README](../../README.md) for what rk is.

- Status: Approved for implementation
- Revision: 6 (2026-08-22) — Formula-only Homebrew publication
- Supersedes: RFC 0001 as build authority; 0001 remains the threat catalog
  and assurance ladder
- MVP scope: Dart packages and Dart CLIs, released **from the operator's
  own machine**, to pub.dev, GitHub Releases, and Homebrew
- CI: designed for, deferred from the MVP. See "CI readiness" — its
  constraints are binding on the MVP.
- First production-alpha canary: rk 0.1.0

The staging and status amendments in this revision are the forward contract
being implemented. [The production-alpha plan](../production-alpha-plan.md)
tracks the sequence and acceptance evidence; historical build evidence remains
in `doc/plan.md`.

## What rk is

rk is a checklist compiler. It reads what native manifests already say plus
one small file of release intent, derives the complete ordered checklist for
a release, and executes it with three behaviours a human cannot sustain: it
validates everything before acting, it inspects reality before every step so
re-running is always safe, and it refuses to guess.

rk manages the release steps and defers authentication to the native tools
that own it — `dart pub`, `codesign`, `notarytool`, `gh`, `git`. It stores
no secrets and keeps no authoritative release ledger. Public targets are the
database. Private stages are disposable outside the interval in which a
binary release is only partially public.

## Principles

1. **One source of truth per fact.** Native manifests own names, versions,
   executables, and dependencies. `release.toml` owns intent. Published
   reality owns identity. The machine owns credentials.
2. **Reality is the database.** Destinations are inspected, never mirrored
   into records.
3. **Inspect, act, inspect again.** Every public target has one exact
   inspection used before and after its act. Effects are idempotent; resume
   is re-run.
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
  own manifest, and the manifests of a unit declare one version — a
  divergence at rest is refused (RK-RES-008), because the tag carries a
  single `{version}` and a unit whose projects disagree has no version to
  put in it. What *is* allowed to lag is published reality: after a partial
  publish some projects are live at the new version and some are not, the
  manifests never having moved, and re-running completes the release. The
  manifests agree; the world catches up.
- **Checklist** — the deterministic ordered set of steps rk derives. Pure
  data, identical on every machine.
- **Step** — one checklist entry with a stable id
  `<unit>/<adapter>/<coordinate>`. A public-target step uses the same exact
  inspection before and after its act.
- **Verdict** — `absent`, `exact`, `conflict`, or `unknown`.
- **Stage** — the immutable, complete set of release inputs, artifacts, and
  evidence under `.rk/work/stages/<stage-id>`. A Git-bound receipt binds the
  full source commit and tree; an unbound receipt is scoped to one invocation
  and deliberately claims no revision. Both bind the canonical plan,
  toolchain, exact source snapshot, artifact digests, signature, and
  notarization evidence. A stage is reusable acceleration, not a
  database of public truth. It is recovery-critical only while an unfinished
  target still needs its local signed or notarized bytes. If GitHub is already
  public and only Homebrew remains, the public assets and their digests are the
  channel's immutable inputs instead.
- **Draft** — the private GitHub release assembled and validated immediately
  before it is made public. It is transactional protection for that target,
  not cross-target storage or rk's recovery ledger.
- **Adapter** — a closed module: ecosystem, build, transform, or
  destination.

## Configuration

One file, `release.toml`, at the repository root. Keybay's complete
configuration:

```toml
schema = 2

[release.core]
path = "packages/keybay"
publish = ["git-tag", "pub.dev"]

[release.cli]
path = "packages/keybay_cli"
publish = ["git-tag", "pub.dev", "github-release", "homebrew"]
binary_platforms = ["linux-x64", "linux-arm64", "macos-arm64"]
```

Rules:

- `schema` is exact; unknown versions and unknown fields anywhere are
  errors.
- A unit with one project declares it inline; a unit with several uses
  `[[release.<unit>.project]]` rows. Both is an error. No empty headers.
- `git-tag` is explicit. When selected, `tag` is optional for a
  single-project unit and derives as `v{version}` when it is the repository's
  only tagged unit. When several units are tagged, every unit declares its
  pattern so adding a unit cannot silently rename an existing public tag
  namespace. A tagged multi-project unit also declares it because a set of
  packages has no native canonical name. Without `git-tag`, no tag is derived
  or reported.
- Git is a capability, not a prerequisite for rk itself. Registry-only
  projects may release from an unbound filesystem source. `git-tag`, GitHub
  Release, and Homebrew require Git and are refused explicitly when the
  source is unbound. They also require a clean working tree because their
  public identity names a commit. Without those targets, a dirty Git working
  tree is captured as an unbound, one-invocation source snapshot and disclosed
  as a warning; the resulting tracked state and untracked, non-ignored files
  are included.
  rk records no invented directory revision in that mode.
- Project paths are canonicalized; duplicates and nesting fail. No
  recursive discovery: a project releases only if listed.
- `publish` is an unordered set of closed target names; duplicates fail.
  Git tag and GitHub Release belong to the release unit; registry and
  Homebrew publication belong to the project. A single-project shorthand may
  list both scopes together; a multi-project unit separates them.
- `binary_platforms` is the explicit standalone Dart CLI production decision.
  At most one project in a unit may declare it. Several registry packages may
  still release together, but separate standalone programs are separate units
  with independent signing identities and public lifecycles.
  It may stand alone as a local release output. GitHub Release publishes the
  archives only when both are selected, and may otherwise carry only metadata;
  Homebrew requires binaries. Its vocabulary is closed and enumerable;
  identifiers match
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

### Versions

Versions are compared and rendered often enough — monotonicity, tag
derivation, coordinates — that the grammar is frozen rather than inherited
from whatever an SDK happens to accept:

- SemVer 2.0.0 over Dart's three-component form: major, minor, and patch
  are ASCII decimal integers with no leading zero unless the component is
  exactly `0`, with optional prerelease and build suffixes using the SemVer
  identifier grammar.
- The manifest's version string must already be canonical: parsing and
  re-serializing it reproduces it exactly. Whitespace, a leading `v`, and
  omitted components are rejected rather than normalized.
- The full canonical string, including build metadata, is coordinate
  identity. SemVer precedence does not make two different coordinate
  strings the same coordinate.
- **Prereleases** are ordered by SemVer precedence, so `0.2.0-beta.1`
  precedes `0.2.0`, and monotonicity uses that ordering. They publish and are
  verified as ordinary release coordinates. GitHub marks them as prereleases;
  Homebrew remains on its last stable version until a stable release follows.
  A GitHub prerelease is still assembled in a private draft before publication;
  `draft` is transaction state, not release maturity.
- Frozen parser and comparator test vectors are part of the engine, so two
  implementations cannot disagree about an ordering.

### Changelog

"Has an entry" means the changelog contains a heading whose text, once
stripped of leading `#` characters, punctuation, and surrounding
whitespace, begins with the exact canonical version string. Nothing else is
inspected: rk does not parse, lint, or generate changelog content, and it
never edits the file. A missing entry is a blocking problem naming the file
and the heading rk looked for.

### Diagnostics

Every blocking problem carries a stable code — `RK-<AREA>-<NNN>`, as in
`RK-DART-201` for a project whose build inputs escape the repository — so a
failure is greppable, linkable, and stable across releases even as its
prose improves. Codes are additive and never reused for a different
meaning. The code is secondary in the output: the human reads the sentence
and the remediation, and the code exists for search.

### Identity

Identity facts are derived, not declared, so the check becomes "this
release matches the last one" — impossible to typo and self-maintaining:

| Fact | Derived from |
|---|---|
| Apple team, code identifier | the designated requirement of the macOS binary in the current published release; for the first bare CLI signature, the native executable name |
| Tag signer | the signature on the previous release's tag |
| Homebrew tap | `<repository owner>/homebrew-tap`, Homebrew's convention |

There is deliberately no `code_id` row or `[identity]` block. The producer
reproduces an established published requirement. On the first bare CLI
release, `codesign`'s native convention is the executable name; the stage
discloses the resolved identifier before authorization. App bundles use their
native bundle identifier. `apple_team` and `tag_signer` are also derived rather
than declared. The only identity override currently retained is
`homebrew_tap`, because a real nonconventional destination exists.

The remaining override supports a deliberate tap destination. A new *team* is not
overridable as built: a signature that disagrees with the published
identity is refused (RK-SIGN-003). Changing the team that
distributes a program breaks Keychain continuity for existing users, so it
is a refusal rather than a setting. A **first release** has no baseline: the Apple team
comes from the keychain, filtered to `Developer ID Application` identities
(one is unambiguous; several fail closed with the list; none reports that a
certificate must be installed), and rk does not read `.xcodeproj` files,
which in practice belong to example apps with unrelated identities. The
code identifier for a bare CLI comes from the native executable declaration.
Every release after the first reads the identifier off the binary users
installed. The prompt names both halves of what becomes permanent, the
certificate and the identifier, before the release is authorized. A tag
signer, where earlier tags are unsigned or absent, is the key about to sign,
confirmed once. Keybay needs none of this: its 0.1.0 release supplies every
baseline.

## Release verbs and local maintenance

`rk target` is a static reference command. It reads no repository,
network, or credentials: `target list` describes every release choice in the
installed binary, and `target <name>` explains one choice's requirements,
native sources, RK settings, and minimal configuration.

`rk init` · `rk plan` · `rk status` · `rk release`. Bare `rk` runs `status`.
`rk clean` is a separate repository-local maintenance command; it neither
resolves a release plan nor reads a public target.

`status` takes an optional unit. `release` takes an optional unit: naming one
keeps the operation narrow, while a bare release coordinates all unfinished
units in native dependency order. `--stage` prepares one unit and therefore
requires its name when several are configured. `init` takes no positional.
Bare `rk` remains status across the configured units; naming a release unit
is the explicit way to narrow scope. Initialization has its own per-candidate
selector.

- **`rk init`** — propose `release.toml`. Reads the repository and, on a
  capable terminal, presents a compact per-project matrix of release choices.
  It starts from conservative selections, applies visible prerequisite
  cascades, previews the exact config and `.gitignore` change, and writes only
  on confirmation. Back returns to selection; customization is intentionally
  left to the resulting TOML rather than a field editor. Without a usable TTY
  it prints the conservative proposal and writes nothing; `--write` accepts
  that proposal. No network and nothing irreversible before confirmation. It
  never edits an existing config,
  never adds a project silently, scans **git-tracked manifests only**, does
  not prefill `binary_platforms`, and
  never infers a binary channel from an `executables:` block — declaring an
  executable means `dart pub global activate` works, not "ship a signed
  tarball." A repository with nothing releasable exits 0.
- **`rk plan [unit]`** — derive the complete configured prerequisite, private
  producer, completion, and public-target graph from source. It inspects no
  destination, acquires no credential, builds nothing, and writes no stage.
  Naming a unit narrows the view; JSON retains the graph's direct edges.
- **`rk status`** — online and read-only. Resolves the intended release,
  inspects an exact local stage when one exists, and inspects all configured
  public targets in parallel. It reports each target's current and intended
  version, the exact artifacts it consumes, concrete issues and fixes, and
  whether there are no known issues or an exact stage is good to release. It
  never builds, signs, notarizes, packages, or writes a stage.
- **`rk release [unit] --stage`** — perform every local and package preflight
  for real and write a complete immutable stage, but make no public mutation
  and never run a registry login.
- **`rk release [unit]`** — revalidate and reuse an exact stage, or create the
  same stage internally. A unit with only local binary output stops there and
  reports the archive paths; otherwise it authorizes and publishes. It inspects
  each target before acting and with the same operation afterward. `exact`
  skips, `absent` acts, and `conflict` or `unknown` stops. An occupied
  append-only coordinate also skips when its historical stage is unavailable;
  rk reports it as already published rather than claiming byte provenance. In
  an interactive run with unfinished targets, it acquires native publication
  sessions only after the complete private stage is validated and before
  authorization. Re-running is resume.

Session acquisition is not a target verdict or public act. Success proves only
that a native tool has a usable session; it cannot prove write authority for
the intended package or repository. The effective destination is frozen and
rechecked around acquisition. Only the publish attempt followed by exact
public read-back completes a target, and an idempotent rerun records that
already-published result without publishing again.

There is no historical verification verb. Published truth is established by
the exact inspection owned by each configured target and shared by `status`
and `release`; the process that performed a publish is never accepted as its
own proof of success.

### Public reconciliation and mutation

**Versioned artifacts are append-only; channels may only advance.** This is
rk's rule even when a provider exposes edit, delete, yank, retract, or force
APIs.

For a versioned public coordinate:

- absent means create it;
- present with cheap comparable evidence means compare the provider's native
  identity or digest: a match skips and a known mismatch blocks;
- present after the comparable stage has been lost means skip it as already
  published, without claiming historical provenance; and
- unreadable or ambiguous means block.

RK never replaces, deletes, retracts, yanks, or force-updates a public artifact
at the same release coordinate. It exposes no overwrite flag. A bad release is
corrected with a new version. Missing evidence is intentionally asymmetric: it
can remove permission to write, but it can never create permission to rewrite.

Verification stays native and cheap. RK compares a provider-reported digest or
directly hashes a public artifact when it has a trusted current stage to compare
against. It does not rebuild historical artifacts, emulate an ecosystem's file
selection rules, or reconstruct universal cross-target provenance merely to
decide whether to retry.

The target-specific applications are:

- **Git tag:** always compare the remote tag object and peeled commit, because
  that identity remains directly knowable without a stage. Never force-move or
  reuse a published tag.
- **Package registry:** treat the native package coordinate as occupied once
  published. With the retained staged package, compare the registry's native
  digest when available; without it, existence skips. A known mismatch blocks.
- **GitHub Release:** treat a public release and each occupied asset coordinate
  as frozen. A private draft may resume only from a verified subset of the
  retained stage. Once public, missing or different required assets block; rk
  never patches, replaces, or deletes them. Without the stage, a structurally
  complete release is already published.
- **Homebrew and other channels:** the tap formula is a moving pointer rather
  than a versioned artifact. Set it when absent, skip it when it already names
  the intended version and payload, and advance a recognizable older value with
  compare-and-swap. Same-version differences, newer values, unrecognized
  content, and races block; an ordinary release never rolls a channel back.

Only real consumption edges require cross-target integrity. A Homebrew formula,
for example, must carry the digest of the actual GitHub asset its URL downloads.
If the local stage is gone, rk obtains that digest from GitHub or downloads and
hashes that asset; it does not rebuild a local binary and infer equivalence.
This proves the consumer binding, not that every publisher received identical
bytes.

This policy remains behind the existing target inspection seam. It adds no
public reconciliation mode, target class, configuration, repair command, or
generic overwrite mechanism.

### Authorization

A local release is authorized by the operator's presence: publishing
requires their credentials, and rk prompts with the full consequences.
The prompt shows the unit, exact version, remaining targets, and first-time
claims, then asks an ordinary default-No yes/no question. `--yes` answers that
same question for an unattended invocation and skips no inspection. Naming a
unit is the narrow automation boundary. Without either a human or `--yes`, rk
refuses.

### Tagging

**rk never creates the artifact that authorizes it, and creates the ones
that merely record it.** Those are different objects, and conflating them
was an error worth naming: an executor that mints its own authorization is
a confused deputy, but a record written after the human has authorized is
not authorization.

- **Interactive release.** The operator's presence and affirmative answer
  are the authorization, so rk tags on their behalf: an annotated tag at
  the released commit, named by the unit's derived pattern, signed when git
  signing is configured and unsigned otherwise, and it says which. The tag
  binds the complete stage manifest digest as well as the source commit. It
  is an ordinary checklist step — inspect the remote ref, create and push,
  then inspect the remote ref again — and it runs only after the complete
  stage has been revalidated.
- **Non-interactive release.** Consent must still be explicit: `--yes` carries
  the operator's answer as a flag and skips no inspection. For consentless CI
  with no operator anywhere in the
  loop, the tag *is* the intended authorization: it must already exist, rk
  verifies its signature against the expected signer, and rk never creates
  it — creating it there would be minting the permission it acts on. That
  signed-tag path remains ledgered, not built.

Every tag binds the digest of its complete stage manifest to the source
commit. A binary release that selects GitHub also publishes the manifest with
its GitHub assets, so its inventory remains recoverable after the local stage
is deleted. A pub.dev-only release has no separate public artifact to name: its
published coordinate is immutable and its retained stage supplies a digest
comparison while available. If that stage has been deleted, rk reports an
existing package version as already published rather than reconstructing its
historical contents. A signed tag authenticates its binding; an unsigned tag
proves consistency but not signer authenticity.

`--yes` skips only the human confirmation; it prints the same exact plan and
keeps every safety check. There is no `--force`: a permanent registry conflict
cannot be forced because the permanence is server-side, `unknown` needs a retry
which is free, and a wedged draft is unblocked by a command rk prints for the
human to run.

## Output

**Collapse.** Anything already true collapses; only what needs a human
expands. A level with one child collapses onto its parent; a level whose
children agree collapses to their shared fact — three channels at one
version are one line, not three.

**Terseness.** rk does not narrate itself. A line that reads the same on every
successful run is noise.

**Attention.** The verdict leads the line, in a gutter, and the vocabulary
is a small set of marks rather than a symbol per state: `✓` done or proven ·
`·` already satisfied, nothing to do · `✗` blocked, conflicting, or failed ·
`!` nonblocking warning · `→` your next move. A running step shows a spinner
in the same column. Anything
finer — unknown versus conflict, expected-absent versus missing — is carried
by the words on the line, which the reader has to read anyway. Glyphs never
appear without a word; `NO_COLOR` and non-TTY are honoured. Any concrete issue
linked to a target makes that target's row `✗`, without rewriting the target's
public-state verdict. Global, prerequisite, and stage issues stay in `Issues`;
artifact production and validation problems use the artifact rows beneath the
target that consumes them.

### Status report

Status is target-oriented. While independent reads run concurrently, a TTY
shows one fixed transient `Release targets` list with a row and spinner for
each configured target. Rows settle independently; after all reads settle,
the entire transient region is erased and replaced once with the deterministic
final report. A pipe or JSON caller receives no spinner or cursor movement.

The final report has one section per configured target — Git tag, pub.dev,
GitHub Release, Homebrew, or a later adapter — and shows `current › target`
when a release moves forward or `target · behind current` when public reality
is already ahead, plus the public condition and exact filenames consumed.
The machine report also records `source_binding` (`gitCommit` or `unbound`)
and `source_comparison` (`exact` or `unavailable`) independently from the
target verdict. The human report calls out the exceptional unbound case once
rather than repeating it under every target.
Stable diagnostic codes remain in JSON and are omitted from the ordinary
human report. Blocking findings use `problems[]` and `✗`; warnings use the
separate `warnings[]` collection and `!` and never change the exit code.
For artifacts, `✓` means the exact artifact is validated in the matching
stage, no mark means it has not been produced and no production problem is
known, and `✗` means rk already knows it cannot be produced or validated. The
words `staged`, `not staged`, or the concrete problem repeat that meaning.

Status has no authentication-specific green or unknown state. A supported,
safe read-only native check may produce a concrete issue and `Fix:` linked to
its target, which marks that row `✗`. If a native tool has no safe check,
status says nothing about authentication; normal release preflight owns it.

There is no user-facing `ready`, `partial`, or `blocked` lifecycle. An
`Issues` section appears only when nonempty and every issue supplies one
concrete `Fix:`. Only a refusal concludes the report — `N issues prevent
release` — because success is the absence of one, and the rows above already
say what is published and what is staged.

Colour carries no unique information. Static roles are blue for local work,
violet for completion checkpoints and joins, amber for requirements and safety
disclosures, cyan for public destinations and operator actions, and grey for
secondary context. Runtime state overrides that role: active is cyan, newly
completed is green, already exact or skipped is grey, attention is amber, and
failure is red. A source-only plan therefore never uses green. Marks and words
carry the same meaning without colour. `NO_COLOR` disables SGR colour and
emphasis while retaining live cursor rendering on a capable TTY.
`TERM=dumb`, non-TTY output, and `--json` disable both SGR styling and cursor
movement.

Provider and tool text is untrusted terminal input. Human rendering spells
control bytes inertly rather than allowing captured output to move the cursor
or rewrite the screen; JSON and diagnosis evidence retain the original text.

**Every halt opens with a plain sentence** answering the only two questions
an operator has, before any verdict noun: did any public target change, and is
re-running safe. Five distinguish stopped-before-acting, safely stopped
partway, acted-but-lost-track, unfixable without acting, and acted-with-a-bad
read-back. Their sentences state what is **already permanent** before the
remediation, and `doc/json.md` freezes their machine names. In particular,
`beforeActing` means no public target changed; a native login may still have
updated local session state.

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
`rerun_helps` — re-running is safe by construction, so no field says so.
Exit codes: `0` clean, complete, or blocked; `1` refusal;
`2` usage; `3` rk itself crashed.

### Liveness

A release takes minutes and some operations are opaque — notarization waits on
a third party. Silence during that is not austerity, it is anxiety. Staging and
publication therefore share one fixed-height board:

- **The row names the output or public target.** Its status names only the
  meaningful operation: `building`, `testing`, `signing`, `notarizing`,
  `checking sign-in`, `uploading 2/4`, `publishing`, or `verifying`.
- **A TTY shows a spinner and elapsed time** for active work. Target modules own
  their concise activity labels; core owns row lifecycle, layout, and final
  success, failure, and not-attempted states.
- **`rk release --stage` stops at local and package outputs.** A full release
  clears preparation before authorization, then starts a persistent public
  target board only after the operator says yes.
- **A failed row stays in the transcript**, downstream rows become `not
  attempted`, and the normal issue immediately below supplies the explanation
  and fix. Ambiguous command failures are read back before RK chooses mutation
  failure versus verification failure.
- **Native prompts remain native on an attached terminal.** RK leaves one
  durable handoff line, yields the terminal to login or publish, then restores
  the board below that output. JSON and redirected releases never inherit a
  native prompt; they require an existing token or session.
- **On completion, the public result is printed** — the URLs and install
  command a person actually wants next — not a count of internal checks.

A non-TTY receives no cursor movement or spinner frames. An operation that
outlives the display delay emits its activity once; the final board remains a
clean append-only transcript. `NO_COLOR` removes colour without removing live
progress, and an unknown or unsafe terminal width disables fixed-height redraw.

This is not the narration terseness forbids. rk still does not report on
its own internals — reading files, resolving config, counting checks. It
reports the work, while the work is the thing the user is waiting for.

**Diagnosis.** Reality records what exists and nothing about why a run
failed. When a failed run may have acted, or whenever an operational command
crashes, rk writes a diagnosis directory inside the workspace with the report
and its attachments. `rk plan` keeps its stricter read-only promise even on an
internal crash and reports the error without writing evidence. A refusal that
provably acted on nothing remains entirely in its human or JSON report. rk
never reads a diagnosis back; deleting it is always safe.

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
- `exact` — complete under the target's reconciliation policy; skip. Evidence
  distinguishes payload equality from an occupied append-only coordinate whose
  historical comparison is unavailable, so human output says either `exact` or
  `already published` without adding a second action state.
- `conflict` — halt; a human decides, with the evidence.
- `unknown` — rk could not determine state. Never collapsed into `absent`.
  Two shapes needing different guidance: **pre-act**, where rk never wrote
  and the world is unchanged; **post-act**, where rk wrote and lost the
  response, so the next run must classify what it finds rather than blindly
  retrying.

After rk's own act on a coordinate, inspection polls to a bounded deadline
before concluding anything — destination APIs lag their own writes.

### Staging and reuse

Every act that creates a versioned publication consumes a complete, atomically
receipted stage. A moving-channel-only recovery may instead consume the
authenticated public artifact set it points to, without rebuilding it. A
Git-bound stage id binds its schema, full commit and tree
identity, and canonical release plan. An unbound stage id instead includes a
one-invocation nonce: it may proceed through a one-shot registry release, but
cannot be handed to a later authorization run. Both plans include the exact producer implementation and the
version plus digest of the PATH-resolved compiler executable. Production
invokes that resolved path rather than resolving `dart` a second time, without
depending on the SDK's private on-disk layout. The receipt then binds every
artifact by name, size, and digest together with the source snapshot, package
preflight, toolchain, signature, and notarization evidence. An incomplete
directory is not a stage.

A normal release reuses a stage only after a read-only inspector validates
that complete receipt and all referenced bytes. An explicitly created stage
is never silently replaced with different bytes. If no exact stage exists,
the normal release creates the same stage internally. A file on disk is not
evidence of itself, and no artifact is re-signed or otherwise mutated after
the receipt that names it.

*Amended (as built):* verifying a stage — re-reading it and re-hashing
every artifact — is answered once and then remembered for as long as the
stage holds still. A release asks whether the stage is still good dozens of
times, and re-hashing tens of megabytes to answer again cost more than
everything else it does locally. Every ask still re-reads the directory;
only hashing is skipped, and only while every entry's path, kind, size,
mode, and both timestamps are unchanged. This is a memo, not a promise: the
first ask verifies bytes, and anything that writes to the stage — rk's own
producers included — moves a timestamp and forces the next ask to verify
again. What a stale answer would take is a rewrite of identical length that
also preserves change time, which the writer cannot set; on a volume whose
timestamps are only second-accurate the claim weakens to size and mode
within that second. Concurrent writers are excluded separately, by the
stage lock.

*Amended (as built):* the same applies one level down. Confirming that a
staged artifact is unchanged — which every receipt write does for
everything already recorded, and sealing the source snapshot does for every
tracked file — reads and digests it once, and afterwards asks only whether
that file has moved. A confirmation binds both halves: the file's size,
mode, and timestamps, and the digest that reading it produced. A file that
moved, one whose recorded digest is not the digest being confirmed, one
that has become a link, and one this process never digested are all read
again. What this cannot see is narrower than the stage-level memo: a
rewrite in the same microsecond, at the same size and mode, with no
directory above it consulted.

*Amended (as built):* platform chains stage concurrently — each platform's
build, notarize, and archive is an independent lane until the
complete-stage barrier, and a failure drains: in-flight steps finish and
are recorded, nothing new starts, and the strongest halt any failure asked
for is spoken once after the drain. Execution order is scheduling; the
record is canonical: progress receipts are always written in contract
order, and an in-progress receipt is valid when its steps are an ordered
subsequence of the contract — gaps are lanes that have not caught up. The
loosening from strict prefix is backstopped, not trusted: a recorded step
whose producer is missing fails the causal input check, and a stale input
digest fails its comparison. A complete receipt still requires the exact
pipeline, in order, with no gaps.

### The draft

A forge cannot publish several assets in one atomic act: a release object is
created, then assets are uploaded to it. An interrupted upload would
otherwise leave a permanent, immutable release missing files. A draft is
the fix — fill it privately, verify it, publish once — and that is the
whole of its job in this revision.

It is deliberately **not** memory. The local stage holds every artifact
locally, so a draft contains nothing that cannot be re-uploaded from the
retained exact stage. Before publication begins an invalid private stage may
be rebuilt. Once signed or notarized bytes are public, the stage remains
recovery-critical only while an unfinished target still needs those local
bytes. A Homebrew-only remainder instead consumes the already-public GitHub
assets and their digests. This reduces the draft rule to three cases:

- **no draft** — create it and upload the full inventory;
- **a draft containing a verified subset of this release** — upload the
  difference, re-verify the complete inventory, and publish;
- **a draft that is anything else** — refuse and name the mismatch. rk never
  deletes a draft it did not prove it owns.

Adoption requires exactly one same-tag draft whose metadata and assets are a
digest-verified subset of the frozen local request. Inventory order carries no
meaning. Local paths,
sizes, and digests are validated before the first API mutation. A new draft is
created only when none exists, then every staged asset is uploaded, its full
inventory is re-read, and one `draft: false` update makes it public. Thus no
permanent release is intentionally created with a partial asset set and no
remote draft is deleted as cleanup.

**The flip re-verifies against reality**: enumerate the draft's assets,
require the exact inventory, confirm every digest, and compare the staged
formula against the manifest-bound archive digests.
Only then publish once, and confirm the release reports immutable.

The post-create inspection downloads or hashes the public assets and compares
their complete inventory and digests with the public release manifest. Asset
names alone are not exactness.

If the retained stage no longer exists, rk still requires the public release's
structural inventory but does not reconstruct the old build merely to reproduce
its digests. The occupied public release is skipped, never repaired in place.

**After publishing, verification failure is terminal.** Immutable releases
cannot be edited and deleting one permanently burns the tag name. rk
retries verification to a bounded deadline, then states the only honest
remedy: ship the next version.

When CI arrives, the local stage becomes ephemeral and a half-filled draft
may be the only surviving copy of expensive work. Only then does the draft
also become memory, and only then are adoption by enumeration, per-asset
repair of an interrupted upload, and the concurrent-writer cases worth
their complexity. Deferring them costs nothing today.

### Mutable pointers

The Homebrew formula updates compare-and-swap: inspect (absent / exact /
recognizable-older / conflict), apply only if the inspected blob is still
current, then re-read the public tap as the post-act check. A same-version
difference, a newer version, or content rk cannot recognize as its generated
formula yields `conflict`; retry never reconstructs every historical release
just to authorize a forward move.
A clean consumer install from the public tap remains a supervised live-canary
gate rather than part of the mutation.

The inspection compares the public formula bytes, version, URLs, and hashes with
the intended channel value. That value comes from the retained stage when it
exists, or from the actual public GitHub assets and their digests when Homebrew
is the only unfinished target. The swap applies against a fresh `--depth 1`
clone, first requiring its formula to match the exact blob authorized by
inspection; a rejected push then catches movement after that check. The
authoritative pre-act and post-act public reads use the GitHub contents API —
REST, not a CDN path; the API serves blob content, not cached pages.

### Cleanup

Published assets are the product and are never cleaned up. Git-bound local
stages become disposable acceleration after release because public truth is
recoverable from target inspection. An unbound stage is the only retained
expected payload unless the provider durably binds its digest. Deleting it
blocks creation when the immutable coordinate is still absent; when that
coordinate already exists, it skips as already published and never becomes
permission to publish again. A failed step or non-clean verdict keeps its
evidence for diagnosis.
Residue from an abandoned release is deleted only by a human. `rk clean` is
that explicit deletion surface. It inventories only
`.rk/work/stages` beneath the current repository, preserves `.rk/diagnosis`,
and requires a typed yes or `--yes` after disclosing that partial-release
recovery may depend on those exact bytes. It does not infer safety from age or
from current configuration, and it never runs automatically or across
repositories. A shared repository stage-store lock prevents cleanup from
racing an active RK release.

## Credentials

Two rules. **Facts** come from the manifests, published reality, or an
explicit override on the unit — never from the environment. **Secrets and
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

Native tools remain the credential owners and rk never reads their secrets.
For a normal release, rk performs safe readiness checks first, builds and
validates the complete private stage, refreshes public observations, then
acquires native sessions before authorization. `dart pub login` remains
attached only for a human release with both terminal ends visible; JSON and
redirected releases require an existing token or session. GitHub checks its
existing `gh` session. `status` and `release --stage` never acquire sessions.
Failure is target-specific and halts before acting. Success proves a usable
session, not write authority; provider acts are non-interactive and captured,
and exact read-back remains the final proof.

## Adapters

Every public target owns one exact inspection, used by status and on both
sides of release's act:

```text
inspect(expected) -> absent | exact | conflict | unknown
act(expected, stage)
```

- **`dart`** (ecosystem): parses pubspec, workspace, lockfile, and any
  `pubspec_overrides.yaml`; validates version↔tag agreement, changelog
  entry, and native package archive validation; derives ordering and
  prerequisites. Two
  rules learned from real repositories: lockfile enforcement applies to
  **compiled-binary units only**, because Dart's own guidance tells library
  authors not to commit one and requiring it would refuse the most common
  package shape; and a **consumer resolve** — resolution with development
  overrides disabled — is mandatory before publishing, because pub excludes
  `pubspec_overrides.yaml` from the archive but honours it locally, so a
  validation can pass while the published package is unresolvable for everyone
  else.
- **`dart-cli`** (build): `dart compile exe` per platform, then smoke-runs
  what it produced. Capability is resolved per platform and reported:
  **native** for the host; **cross-compiled** for Linux targets, which
  `dart compile exe` supports and which requires the project to have no
  native assets, since the SDK ships no C cross-toolchain; **emulated
  execution** through a container runtime for smoke-testing a
  cross-compiled binary; **blocked** otherwise, naming the missing
  capability.

  *Amended (as built):* producing and proving are separate answers. The
  host's own platform always smoke-runs, because that costs nothing and
  catches the commonest real failure — a binary that compiles and reports
  the wrong version. A cross-compiled target with no runtime to execute it
  is **buildable-unproven**, not blocked: it ships with the smoke test's
  absence stated on its step, at the confirmation prompt, and in the
  document. Refusing the release instead made a daemon that is not running
  a hard blocker on shipping, which is a heavier claim than an optional
  check earns — and constraint 6 says optional evidence degrades honestly. An x64 macOS binary can be neither cross-compiled nor built
  natively on Apple Silicon. Capabilities are discovered, never declared:
  which platforms to ship is a product decision, where a binary can be
  produced is a fact about the machine.
- **`macos-sign`** (transform): selects one exact Developer ID Application
  identity from the operator's login keychain, signs by its identity token,
  then runs `codesign --verify --strict` and compares the output requirement
  against the published release's designated requirement, not against the
  signer that just produced it. The certificate SHA-256 fingerprint is stage
  evidence. Ephemeral-keychain import is deferred with remote CI.
- **`macos-notarize`** (transform): `notarytool submit --wait`; the result
  and log are receipt-bound stage evidence — a consumer verifies the binary
  with Apple directly, so they are not release assets. A reusable stage
  retains and revalidates that exact evidence instead of resubmitting.
  `codesign -R=notarized --check-notarization` remains the binding check on
  the exact signed bytes.
- **`archive`** (transform): deterministic tar.gz per
  platform — fixed entry order, zeroed mtimes, normalized modes, no gzip
  timestamp — containing the executable, LICENSE, and README, with frozen
  public asset names. The release manifest records each archive's size and
  SHA-256. Determinism is a requirement, not polish: without
  byte-reproducibility, "is this the artifact I would have made" is
  undecidable and reuse degenerates into acceptability.
- **`pub-dev`** (destination): native packaging produces the exact private
  archive that publication uploads. While that stage remains, the registry's
  archive digest is compared directly; after it is gone, an existing
  package/version is already published and skips without a historical rebuild
  or logical source-tree comparison. A known digest mismatch blocks. A package
  that has never existed yields `first-publish`, which prints the ordered
  interactive bootstrap commands and refuses to act, because pub.dev
  accepts a first version only from an interactive publish.

  *Amended (as built):* there is no such refusal. The premise above is
  false — pub accepts a first version exactly as it accepts any other.
  `lish.dart`'s `_confirmUpload` begins `if (force) return;`, so `--force`
  skips one thing, the confirmation prompt; the prompt text does not vary
  by whether the package exists; there is no terms acceptance in the flow,
  only a link to the policy; and the command has no first-time branch at
  all. rk performs a first publish like any other. What it adds is
  disclosure, because the thing a first publish really takes is the *name*,
  permanently: the consent block states each name claimed for the first
  time — the pub.dev package and, when it applies, the macOS code
  identifier — with its consequence, before the release is authorized.

  A normal release invokes one native `dart pub login` after the private stage
  is complete when at least one configured pub.dev target is unfinished.
  Stage-only runs never log in. A successful login creates no auth-specific
  target state and proves no package-level uploader permission; the actual
  publish and public coordinate read-back decide completion, while an
  idempotent retry reports the target already published and performs no second
  publish. When the staged archive is still retained, its native digest also
  proves the public bytes. The adapter capability-detects the Dart SDK's native
  archive staging/upload support before work begins; an SDK without that support
  fails clearly rather than falling back to custom ignore or packaging logic.
- **`github-release`** (destination): draft creation, upload, public flip, and
  exact public asset inspection as above.
- **`homebrew-tap`** (destination): stable releases only; Formula from a closed
  renderer plus staged digests plus derived identity; compare-and-swap update;
  public byte-for-byte read-back. Prereleases leave the tap unchanged. A clean
  consumer install from the public tap,
  without release credentials or the source checkout, is the supervised
  Homebrew canary rather than part of the mutation.

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
  non-zero exit and carrying `rerun_helps`. An agent decides whether to
  retry from data rather than by parsing prose.

  Step ids are a frozen wire format, like the version grammar: an agent
  that polled yesterday and diffs against today must see the same id for
  the same fact, so a change to these forms is a breaking change made
  deliberately or not at all. The forms, exhaustively:

  ```
  <unit>/tag/<tag>
  <unit>/requires/pub.dev/<package>/<version>
  <unit>/pub.dev/<package>@<version>
  <unit>/build/<platform>       (on macOS the build signs too)
  <unit>/notarize/<platform>
  <unit>/archive/<platform>
  <unit>/github-release/<tag>
  <unit>/homebrew/<project>/<executable>
  ```

  `test/checklist_test.dart` holds them as frozen vectors.
- **The read-only verb is always safe.** `status` changes nothing, so an agent
  may run it freely, including across a fleet by invoking rk once per
  repository.
- **Idempotence.** Re-running is the resume, so an agent that loses track
  of a run recovers by running the same command again.
- **Next actions are data.** `status --json` names the command that would
  advance the release, so an agent can chain without inferring intent from
  formatting.

**Consent is explicit, or the release refuses.** An agent may run status
freely and prepare a private stage through the same explicitly invoked
command. Publication requires yes at a terminal or `--yes` for that invocation,
not a standing `--force`, and is never guessed. Naming a unit provides the
narrowest unattended scope. Consentless publication stays refused; signed-tag
authorization remains the intended future CI path, its signer policy and
non-interactive execution ledgered rather than implied by the current
implementation.
The late native `dart pub login` session acquisition does not change this boundary and
is not a CI credential design; trusted publishing remains part of the deferred
remote-CI work below.

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
6. **Optional evidence degrades honestly.** Target inspection distinguishes
   expected-absent from missing, so attestations attach later as one more
   evidence type rather than a new concept.

**What CI must not require.** Reshaping the checklist, changing a verdict,
altering an adapter's inspect/act contract, or introducing state that outlives
a run. If adding CI needs any of those, the MVP got a seam wrong and the seam
is the thing to fix.

## Deferred by principle 8

On RFC 0001's priced ladder: the Release Registry in every tier, the
protected policy document and policy key, claim/envelope identities and
DSSE receipts, capability fencing, the multi-party tag ceremony, plan
admission by a separate control plane, toolchain content-addressed
materialization, the credential mapping file, global identity with
overrides, and cross-run workspace warming. Any returns only by naming the
concrete failure it prevents.

## Production-alpha canary and compatibility drives

1. **Self-host release-kit.** Stage and release `rk` 0.1.0 to pub.dev
   and GitHub Releases from the clean release-kit checkout, including its
   signed/notarized macOS and cross-built Linux artifacts. Prove fresh public
   read-back, an idempotent zero-act rerun, and clean pub.dev/GitHub consumers.
   Homebrew remains outside this canary because release-kit does not configure
   a tap target.
2. **Engine + `dart` + `pub-dev`.** As a later compatibility drive, stage and
   release keybay core from the
   operator's machine: `rk init`, `rk status`, `rk release core --stage`,
   `rk release core`, then `rk status core`. First production use of every
   verb in Keybay, with no binaries, signing, draft, or tap.
3. **Binary chain + `github-release` + `homebrew-tap`.** Release keybay
   cli: three platforms — macos-arm64 native, both Linux targets
   cross-compiled and smoke-tested in containers — signed, notarized,
   archived, staged, published, Formula updated, then installed and
   smoke-tested from the public tap.
4. **Fleury**, after its five packages are bootstrapped by hand, exercising
   multi-project units and derived ordering.

Keybay compatibility: public asset names are frozen; archives contain the
executable, LICENSE, and README; Apple team `5AHFA9FUZG` and code
identifier `io.github.danreynolds.keybay.cli` are enforced against the
published release's designated requirement; the CLI tag namespace is
unchanged and core migrates to the derived `keybay-v{version}`;
`macos-x64` is dropped, taking the release to six assets.

## Module layout

*Amended (as built).* The block below described a tree that never existed —
it named `ecosystems/dart/`, `builds/dart_cli/` as a directory, four
`transforms/` modules none of which is a filename, and `pub_dev` under
destinations while omitting `git_tag`. Documentation contradicting
structure is the failure this section is supposed to prevent, so the rule
is stated once and applied: **where the code is right, move the spec;
where the spec is right, move the code.**

```text
release-kit/
  bin/rk.dart            # the entry point, and the composition root
  lib/src/
    binary_chain.dart    # the local production chain: neither verb nor adapter
    commands/            # init, status, release, clean, and target reference
    targets/             # the closed target catalog and lifecycle modules
    destinations/        # lower-level provider protocol clients
    builds/              # capability, dart_cli
    transforms/          # archive, digest, macos
    output/              # output, report, diagnosis — the two surfaces
    engine/              # the model and the readers: config, resolve,
                         # checklist, inspect, compare, registry, git,
                         # identity, assets, and the format parsers
  doc/rfcs/  doc/plan.md  doc/json.md
  examples/              # five repository shapes the tests drive end to end
  test/                  # flat, deliberately: mirroring couples test paths
                         # to source paths and doubles every future move
  tool/                  # validate.dart, outside the test tally
```

Two adjudications the rule forces. **A target is a complete lifecycle, while a
destination is a protocol client.** `targets/pub_dev_target.dart` owns the
pub.dev expectation, exact/latest reads, stage preflight, session preflight,
publish, settling, and failure semantics; `destinations/pub_dev.dart` and
`engine/registry.dart` supply the lower-level read protocol. The other three
built-ins follow the same boundary. Each stage-producing target also supplies
one in-memory contribution contract; the coordinator executes it and the stage
inspector validates the same descriptor, rather than maintaining a second
provider grammar in `engine/stage_contract.dart`. `binary_chain.dart` therefore
contains only local build, sign, notarize, and archive operations.
**`ecosystems/` is removed from this block
rather than created on disk** — a directory hosting a taxonomy with one member
and no second member in sight is complexity naming no failure.

`engine/` is the residue by design. It is the largest directory and the
vaguest name, and it stays that way: a directory name that is wrong
excludes falsely, which is worse than one that merely fails to narrow.

rk has **no runtime dependencies** — `dart:*` and its own sources only,
enforced by a test over the import graph and an empty `dependencies:`
block. This keeps third-party code away from the signing path and makes
rk's own bootstrap trivial.

## What rk is not

Not a version bumper, changelog generator, CI system, test runner, task
runner, or plugin host. No hooks, no templates, no `--force`, no recursive
discovery, no override of native vetoes.

## Open items

1. Verify container smoke tests for cross-compiled Linux binaries, and that
   cross-compiled and natively built binaries carry the same glibc floor,
   since the platform profile fixes that floor as a compatibility contract.
2. Publish a JSON Schema for `release.toml`.
3. `rk doctor` — fleet-consistency checker; build only when drift is real.
4. Final name.

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
