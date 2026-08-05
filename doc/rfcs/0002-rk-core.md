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
no secrets and keeps no state.

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
  precedes `0.2.0`, and monotonicity uses that ordering. A prerelease is
  otherwise an ordinary release: it publishes, it is verified, and it is
  never treated as a draft or a lesser artifact.
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
| Apple team, code identifier | the designated requirement of the macOS binary in the current published release |
| Tag signer | the signature on the previous release's tag |
| Homebrew tap | `<repository owner>/homebrew-tap`, Homebrew's convention |

*Amended (as built):* there is no `[identity]` block. Two optional
settings live on the unit that owns them — `code_id` and `homebrew_tap` —
because a program identity and a tap belong to what is being shipped, and
a repository with two binary units has two of each; a single global table
would have signed both as one program. `apple_team` is gone entirely: the
keychain rule below was always the specification, and requiring the
declaration was drift. `tag_signer` is gone too — it was accepted,
stored, and read by nothing.

The remaining override matters in two cases. A **deliberate migration** — a new tap or team — overrides a
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
  progress, and anything blocking. Prints the next command.
- **`rk release`** — execute. Refuses at the start anything it cannot
  finish; re-validates independently rather than trusting `status`;
  verifies the authorizing tag's signature where one exists; then inspects
  before acting at every step. Halts on `conflict` or `unknown`; safe to
  re-run at any point.
- **`rk verify`** — proves the version each unit's manifests declare
  against what the registry serves for it, comparing byte-for-byte with the
  **sources at the ref** — the derived tag, or one named with `--at=<ref>`
  for a release made under an older tag scheme. After a completed release
  the manifest version *is* the latest published one; older releases are
  reached by naming their tag. Configuration is read from the working tree,
  deliberately: the version, the sources, and the comparison come from the
  ref, while `release.toml` locates the packages — a repository's early tags
  predate its release.toml (keybay's do), and refusing to verify them would
  make the tool's own history unprovable. What the config supplies is
  *where to look*, and a package that moved directories is caught by the
  ref's own manifest being missing there (RK-VER-002). On success it prints
  provenance — the ref proved against and when the registry received it —
  and names what is not knowable rather than omitting it: a version with no
  tag has no commit to bind to, and rk does not pretend otherwise. Signer
  identity arrives with authorization (phase 5).

### Authorization

A local release is authorized by the operator's presence: publishing
requires their credentials, and rk prompts with the full consequences.
Where the act is permanent, the confirmation is **typing the version**, not
a keystroke — "wrong version" is the highest-ranked failure and this is the
only defence that targets it. Without a human present, rk refuses.

### Tagging

**rk never creates the artifact that authorizes it, and creates the ones
that merely record it.** Those are different objects, and conflating them
was an error worth naming: an executor that mints its own authorization is
a confused deputy, but a record written after the human has authorized is
not authorization.

- **Interactive release.** The operator's presence and typed confirmation
  are the authorization, so rk tags on their behalf: an annotated tag at
  the released commit, named by the unit's derived pattern, signed when git
  signing is configured and unsigned otherwise, and it says which. This is
  an ordinary checklist step — inspect (does the tag exist, and at this
  commit?), act (create and push), verify (confirm it on the remote) — and
  it runs first, because a GitHub Release attaches to a tag.
- **Non-interactive release.** An agent or CI run has no operator presence,
  so the tag *is* the authorization: it must already exist, rk verifies its
  signature against the expected signer, and rk never creates it. Creating
  it here would be minting the permission it acts on.

Because every release therefore carries a tag, a published version is
always bound to a commit, and `rk verify` can resolve configuration and
sources at that tag rather than comparing against a working tree that may
have moved on. No project has to remember to tag, and none has to skip the
proof.

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

**Attention.** The verdict leads the line, in a gutter, and the vocabulary
is four marks rather than a symbol per state: `✓` done or proven · `·`
already satisfied, nothing to do · `✗` blocked, conflicting, or failed · `→`
your next move. A running step shows a spinner in the same column. Anything
finer — unknown versus conflict, expected-absent versus missing — is carried
by the words on the line, which the reader has to read anyway. Glyphs never
appear without a word; `NO_COLOR` and non-TTY are honoured.

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

### Liveness

A release takes minutes and some steps are opaque — notarization waits on a
third party. Silence during that is not austerity, it is anxiety, so rk
shows what is happening while it happens and collapses it once it has:

- **A running step expands**, with a spinner, the sub-activity it is on,
  and elapsed time. Its children are visible while they matter — three
  platform builds are three lines during the build.
- **A completed step collapses** to one line with its result, and a
  duration only when the duration is notable. The children that agreed
  fold into their shared fact. Scrollback is therefore the terse transcript,
  not a log of everything that scrolled past.
- **A failed step stays expanded**, because that detail is the diagnosis.
- **Steps that wait on someone else declare how long that normally takes.**
  "waiting on Apple · typically 3–5 min" is the difference between patience
  and a cancelled release, and a step running far past its expectation is
  itself worth surfacing.
- **On completion, the public result is printed** — the URLs and install
  command a person actually wants next — not a count of steps.

None of this applies when stdout is not a TTY. There, each line is printed
once, on completion, in the same words: no spinners, no cursor movement, no
rewriting. A log, a pipe, and an agent see a clean append-only transcript
whose content is identical to what the terminal ended up showing.

This is not the narration terseness forbids. rk still does not report on
its own internals — reading files, resolving config, counting checks. It
reports the work, while the work is the thing the user is waiting for.

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

A forge cannot publish several assets in one atomic act: a release object is
created, then assets are uploaded to it. An interrupted upload would
otherwise leave a permanent, immutable release missing files. A draft is
the fix — fill it privately, verify it, publish once — and that is the
whole of its job in this revision.

It is deliberately **not** memory. The workspace holds every artifact
locally, so a draft contains nothing that cannot be rebuilt or re-uploaded,
which reduces the rule to three cases:

- **no draft** — create it and upload the full inventory;
- **a draft matching this release exactly** — adopt and publish;
- **a draft that is anything else** — delete it, recreate, upload the full
  inventory.

*Amended (7b, as built):* the middle case is folded into the third — every
same-tag draft is deleted by id and the release recreated, because with
the workspace holding every artifact, proving a draft exactly right costs
more than rebuilding it. Adoption returns when CI makes the draft the only
copy, per the paragraph below. The create is delegated to
`gh release create`, which is itself draft-first (draft → upload → publish),
so the safety outcome — no permanent release ever missing files — holds by
delegation.

Deleting is safe precisely because the draft is not the only copy. Its
worst case is re-uploading a few files, which is cheaper than the machinery
required to repair one in place. Draft deletion is the only deletion rk
performs, it applies only to unpublished drafts, and it is announced.

**The flip re-verifies against reality**: enumerate the draft's assets,
require the exact inventory, confirm every digest, recompute the checksums
file and formula from those digests and compare against what is staged.
Only then publish once, and confirm the release reports immutable.

*Amended (7b, as built):* the post-create confirmation compares the asset
inventory by name; per-asset digest re-proof of a published release belongs
to `rk verify`, which runs when the assets are public facts — ledgered in
the plan.

**After publishing, verification failure is terminal.** Immutable releases
cannot be edited and deleting one permanently burns the tag name. rk
retries verification to a bounded deadline, then states the only honest
remedy: ship the next version.

When CI arrives, the workspace becomes ephemeral and a half-filled draft
may be the only surviving copy of expensive work. Only then does the draft
also become memory, and only then are adoption by enumeration, per-asset
repair of an interrupted upload, and the concurrent-writer cases worth
their complexity. Deferring them costs nothing today.

### Mutable pointers

The Homebrew formula updates compare-and-swap: inspect (absent / exact /
older-clean-base / conflict), apply only if the inspected blob is still
current, re-read, then install from the public tap as a final check. "Older
clean base" is derived from reality — the tap formula must byte-equal the
formula asset of the release it names — so a hand-edited formula correctly
yields `conflict`. Reads use git fetch, never a CDN path.

*Amended (7b, as built):* the inspection's exactness is the version
pointer (absent / exact / unknown); the byte-equality that would surface
`conflict` for a hand-edited formula needs digests of published assets and
belongs to `rk verify` — ledgered in the plan. The swap applies against a
fresh `--depth 1` clone (the clone is the read; a rejected push is the CAS
failing), the act reads the pushed formula back from the public tap
byte-for-byte, and both reads use the GitHub contents API — REST, not a
CDN path; the API serves blob content, not cached pages.

### Cleanup

Published assets are the product and are never cleaned up. The workspace is
deleted by the run that completes its release; a failed step or non-clean
verdict keeps it for diagnosis. Residue from an abandoned release is
surfaced by `status` with sizes and deleted only by a human.

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

  Step ids are a frozen wire format, like the version grammar: an agent
  that polled yesterday and diffs against today must see the same id for
  the same fact, so a change to these forms is a breaking change made
  deliberately or not at all. The forms, exhaustively:

  ```
  <unit>/tag/<tag>
  <unit>/requires/pub.dev/<package>/<version>
  <unit>/pub.dev/<package>@<version>
  <unit>/build/<platform>
  <unit>/sign/<platform>
  <unit>/notarize/<platform>
  <unit>/archive/<platform>
  <unit>/checksums/SHA256SUMS
  <unit>/github-release/<tag>
  <unit>/homebrew/<formula>
  ```

  `test/checklist_test.dart` holds them as frozen vectors.
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
    commands/            # the four verbs: init, status, release, verify
    destinations/        # git_tag, github_release, homebrew — see below
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

Two adjudications the rule forces. **`pub.dev` is absent from
`destinations/`** and that is honest, not an omission: its read half is
`engine/registry.dart`, parameterised over host rather than named for one,
and its act half is in `commands/release.dart`. `doc/plan.md` carries the
extraction and the condition it waits on. **`ecosystems/` is removed from
this block rather than created on disk** — a directory hosting a taxonomy
with one member and no second member in sight is complexity naming no
failure.

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
