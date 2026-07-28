# RFC 0002: rk core — an austere release tool

- Status: Draft for review
- Revision: 2 (2026-07-28) — incorporates four adversarial reviews
- Supersedes: RFC 0001 as build authority; 0001 remains the threat catalog
  and assurance ladder
- Initial scope: Dart packages and Dart CLIs on macOS and Linux, publishing
  to pub.dev, GitHub Releases, and Homebrew
- Dogfood fleet: keybay, then fleury

## What rk is

rk is a checklist compiler. It reads what native manifests already say plus
one small file of release intent, derives the complete ordered checklist for
a release, and executes it with three behaviors a human cannot sustain: it
validates everything before acting, it inspects reality before every step so
re-running is always safe, and it refuses to guess.

rk manages the release steps; it defers authentication to the native tools
that already own it. Much release security lives in scopes the providers
enforce — per-package trusted publishing, scoped credentials, protected
environments, tag rules. rk's security contribution is to set those scopes
up correctly, verify them relentlessly, keep repository code out of
credentialed contexts, and — because provider scopes are thinner than they
look — verify identity rather than acceptability at every handoff.

## Principles

1. **One source of truth per fact.** Native manifests own names, versions,
   executables, and dependencies. `release.toml` owns intent. Published
   reality owns identity. The environment owns credentials. Nothing is
   written twice, so nothing can disagree.
2. **Reality is the database.** Destinations are inspected, never mirrored
   into records.
3. **Inspect, act, verify.** Every step checks reality before acting and
   confirms reality afterward. Effects are idempotent; resume is re-run.
4. **Humans authorize; providers enforce.** A signed tag is the release
   authorization. Provider-side scopes — which no repository commit can
   edit — are the policy engine, and rk must state honestly where that
   engine has no teeth.
5. **Auth defers to native tools.** rk never stores, receives, or prompts
   for a secret value. It arranges context and lets `dart pub`, `codesign`,
   `notarytool`, `gh`, and `git` do their native work. Local publishers run
   attached to the terminal so native MFA/OTP prompts pass through.
6. **Builds never touch credentials**, and each credentialed step gets
   exactly one credential and no repository or third-party code.
7. **Identity, not acceptability.** An artifact is reusable only when it is
   provably *the* artifact — matching a digest this release produced or an
   immutable public coordinate. "It looks valid" (right signature, right
   architecture, right version string) is not identity and never authorizes
   reuse.
8. **Fail closed.** Unknown fields, ambiguity, version mismatches, missing
   credentials, undeterminable state: stop before any effect, with the exact
   remediation named. No hooks, no templates, no `--force`. Refusal is a
   feature.
9. **Verify public state.** Everything published is re-downloaded and
   compared against what was built.
10. **Complexity must name its failure.** A mechanism enters this design
    only by naming the failure it prevents and showing that failure matters
    for this fleet. RFC 0001 is the priced ladder of deferred mechanisms.

## The failures v1 must address

Ranked by probability times cost for this fleet:

1. **Human error** — wrong version, wrong package, missing step, publishing
   a back-version. Near-certain over years; pub.dev mistakes are permanent.
   Addressed by validation, monotonicity, and reality inspection.
2. **Partial releases** — interrupted CI, scary reruns. Addressed by
   idempotent resume off the draft, including repair of half-uploaded
   staging.
3. **Fleet drift** — bespoke per-repo release code rots independently.
   Addressed by one engine, a fifteen-line declaration, and a caller
   workflow rk itself emits and verifies.
4. **Identity misuse via the repository** — a malicious PR or stolen CI
   credential publishing under the operator's name. Addressed by
   provider-side scopes, caller-workflow verification, OIDC self-assertion
   in credentialed contexts, digest-identity reuse rules, and
   credential-free execution of all repository and third-party code.
5. **Exotic threats** — host equivocation, evidence replay, compromised
   internal principals. Detection only; consult RFC 0001's ladder if the
   fleet's trust reality ever changes.

## Terminology

- **Release** — one unit at one version, identified by its tag, spanning
  authorization to verified-public. Never called a workflow or a pipeline.
- **Unit** — a named set of projects released together at one version under
  one tag pattern (keybay `core`, keybay `cli`, fleury `framework`).
  Independently versioned projects belong to different units.
- **Checklist** — the deterministic, ordered set of steps rk derives for a
  release from the manifests and `release.toml`. Pure data; identical on
  every machine.
- **Step** — one checklist entry, with a stable id. Every step implements
  inspect, act, verify.
- **Run** — one invocation of `rk run` executing a release's checklist,
  locally or in CI. A release completes over one or more runs.
- **Verdict** — the result of inspecting a coordinate: `absent`, `exact`,
  `conflict`, or `undeterminable`.
- **Arc** — a release's position: `declared` → `checked` → `authorized` →
  `in progress` → `complete`. Status is the arc position plus per-step
  annotation (`done`, `ready`, `blocked`), always computed from reality,
  never stored.
- **Workspace** — the per-release cache of intermediates, keyed
  `<tag>-<commit>` (`.rk/work/<tag>-<commit>/` locally; run artifacts in
  CI). Disposable; only self-authenticating artifacts are reused from it.
- **Intermediate** — a non-final artifact in the workspace, input to a
  later step.
- **Final asset** — an asset in its shippable form. Produced in the
  workspace; its durable home is only ever the destination.
- **Staged asset** — a final asset delivered to a destination's
  pre-publication area, where one exists (the GitHub draft). A destination
  without one holds no staged assets: its finals wait in the workspace and
  are submitted together by the terminal act.
- **Draft** — the pre-publication GitHub release object: staging and
  aggregation point, mutable by anyone with `contents: write`, therefore
  never trusted as an authenticated input (principle 7).
- **Credential context** — an execution context holding exactly one
  credential (a GitHub environment in CI; a native store locally).
  Credential-free steps run in none. Deliberately not called a "lane"
  (fastlane's term) or an "environment" (GitHub's).
- **Adapter** — a closed module: ecosystem, build, transform, destination,
  or provider.
- **Prerequisite** — a public-reality condition derived from native pins.
- **Expectations** — the identity facts rk holds a release to, derived
  from the last published release unless overridden.
- **Workflow** — reserved for GitHub Actions files: the **caller workflow**
  in each repository (emitted and verified by rk) and the reusable
  **release workflow** shipped by release-kit. The rk lifecycle is never
  called a workflow.

## Configuration

One file, `release.toml`, at the repository root. Keybay's complete
configuration:

```toml
schema = 1

[release.core]                 # tag derives keybay-v{version}
path = "packages/keybay"
publish = ["pub.dev"]

[release.cli]                  # tag derives keybay_cli-v{version}
path = "packages/keybay_cli"
publish = ["pub.dev", "github-release", "homebrew"]
binary_platforms = ["linux-gnu-x64", "linux-gnu-arm64", "macos-arm64"]
```

Ten lines, and no `[identity]` block: every identity fact is derived from
the last published release or from the target's convention (see below).

Fleury's multi-unit shape, for contrast:

```toml
schema = 1

[release.framework]
tag = "fleury-v{version}"      # multi-project: no derivable name

[[release.framework.project]]
path = "packages/fleury"
publish = ["pub.dev"]

[[release.framework.project]]
path = "packages/fleury_test"
publish = ["pub.dev"]

# … fleury_widgets, fleury_web identically

[release.mcp]                  # single project: declared inline
path = "packages/fleury_mcp"
publish = ["pub.dev"]
```

Rules:

- `schema` is exact; unknown versions and unknown fields anywhere are
  errors.
- The toolchain is never declared. rk resolves it from the ecosystem's own
  files — for Dart, the pubspec SDK constraint, since neither pubspec nor
  `pubspec.lock` records an exact version by design — verifies the resolved
  toolchain satisfies that constraint before building, and records which
  one built each artifact. An ecosystem with a real pin file
  (`rust-toolchain.toml`, `.nvmrc`, `Gemfile.lock`) is deferred to
  likewise. To harden the pin, tighten the native constraint.
- A unit's `tag` is optional for a single-project unit and derives from the
  **publication target's documented convention**, never from a rule rk
  invents. An explicit `tag` always wins. A multi-project unit must declare
  one, because a set of packages has no canonical name. Patterns are a
  literal prefix/suffix around exactly one `{version}`; a tag must match
  exactly one unit; overlaps fail. See "Tag conventions" below.
- A unit with exactly one project declares it inline on the unit table; a
  unit with several uses `[[release.<unit>.project]]` rows. Declaring both
  is an error. No empty unit headers are required.
- Project paths are canonicalized; duplicates and nesting fail. No
  recursive discovery, ever: a project releases only if listed.
- `publish` is an unordered set of closed channel names; duplicates fail.
- `binary_platforms` is required by platform-bearing channels and rejected
  without one.
- Archive contents are conventional and not configurable: the executable,
  LICENSE, and README. Shipping a package's `example/` tree wholesale is
  unsafe — keybay's contains a full Flutter app and build artifacts — and
  cherry-picking from it is a product choice no rule can infer, so rk ships
  neither. Test material that a post-install check needs lives in the
  repository, which that check already has.
- System runtime dependencies are not declared. Dart manifests cannot
  express them, users will not know to write them, and modeling them drags
  rk into a per-platform package vocabulary. An application that needs a
  system tool reports that itself, at the moment it needs it. Linked
  libraries are derivable from ELF `DT_NEEDED` entries if this ever earns a
  mechanism; subprocess dependencies are not detectable by anyone.
- The generated Homebrew formula takes `desc` and `homepage` from the
  pubspec, omits `license` (Homebrew does not require it and no Dart
  manifest holds it), and asserts only that `--version` equals the release
  version; content assertions are commands in disguise.
- Native vetoes are absolute: `publish_to: none` cannot be overridden.
- Versions come from manifests; the tag must agree exactly.
- **Monotonicity:** the release version must exceed every version already
  published for that package and every existing tag in the unit's
  namespace. Otherwise `conflict`. Per-coordinate verdicts are structurally
  blind to "older than what is live"; this rule is what keeps failure #1
  from publishing a back-version.

### Tag conventions

Each ecosystem adapter declares the tag convention its registry documents,
and rk applies it rather than imposing a house style. The convention is a
function of the repository's shape, which rk already knows from the
complete set of project rows:

- **`dart` / pub.dev** — pub.dev documents `v{version}` for a repository
  publishing one package, and recommends a per-package pattern such as
  `<package>-v{version}` where a repository publishes several. rk applies
  exactly that: one declared project in the whole file yields `v{version}`;
  two or more yields `<package>-v{version}` for every unit.
- **Binary-only units** (no registry channel, as with a future Dune) follow
  the GitHub Releases convention, `v{version}`, subject to the same
  repository-shape rule.
- **Future adapters** declare their own — npm, RubyGems, and Cargo have
  their own documented forms, and an adapter that cannot cite one requires
  an explicit `tag`.

Whether a repository is single- or multi-package is a property of the whole
`release.toml`, not of one unit, because tags share one namespace per
repository. If a unit's channels resolve to conflicting conventions, rk
fails closed and requires an explicit `tag` rather than picking a winner.

### Identity: derived, overridable

Identity facts are not declared; they are derived from what you already
published, which makes the check "this release's identity must match the
last one" — impossible to typo, self-maintaining, and compared against
external reality rather than against the credential doing the work:

| Fact | Derived from |
|---|---|
| Apple team, code identifier | the designated requirement of the macOS binary in the current published release |
| Tag signer | the signature on the previous release's tag |
| Homebrew tap | `<repository owner>/homebrew-tap`, Homebrew's documented convention for a personal tap |

An optional `[identity]` block overrides any of them, and matters in
exactly two situations: a **deliberate migration** — a new tap or team,
where the operator overrides a `conflict` on purpose — and a **first
release**, where no baseline exists yet. In that case:

- **Apple team** comes from the keychain, filtered to `Developer ID
  Application` identities, the only certificate type that can distribute a
  signed binary outside the App Store. Exactly one is unambiguous; several
  fail closed with the list; none reports that a certificate must be
  installed. rk does not read Xcode projects: a repository's `.xcodeproj`
  files typically belong to example or sample apps whose signing identity
  is unrelated to the released binary, so scanning for them finds a
  confident wrong answer.
- **Code identifier** has no source, because it is a name a human chooses
  and then cannot change without breaking Keychain continuity for existing
  users. rk proposes reverse-DNS from the repository and package
  (`io.github.<owner>.<package>`) and requires it to be confirmed in
  `[identity]` before a first signed release. This is the one permanent
  product decision the schema asks for, requested once, at the only moment
  it can be made.

`rk tag` states plainly what a first release will establish. Keybay needs
none of this: its 0.1.0 release supplies every baseline.

A derived fact is verified against reality, so it needs the network; an
offline `rk check` reports identity as unverified rather than pretending.
`code_id` is semantically unit-scoped and moves under its unit if a
repository ever ships two signed binaries.

## The six verbs

Configuration files have no type checking, so discoverability is a design
obligation, met three ways: `rk init` writes the file so fields are
proposed rather than memorized; fail-closed diagnostics name the missing
field, why it applies, and the values rk can offer; and a published JSON
Schema gives editors autocomplete and inline validation.

- **`rk init`** — analyze the repository and write a commented
  `release.toml`: the packages it found, which declare executables, which
  are vetoed by `publish_to`, existing tags and published releases, and
  `binary_platforms` prefilled with every target rk can build for this
  project. It proposes; the human prunes and commits. It never adds a
  project to an existing file silently.
- **`rk check`** — offline validation plus the derived checklist, annotated
  with read-only reality probes. Also verifies the caller workflow on disk
  byte-matches what rk emits.
- **`rk tag`** — the authorization affordance: run `check`, print exactly
  what the signature will create (unit, version, commit, every public
  coordinate), confirm, then exec `git tag -s` and `git push`. Signing
  stays in git; rk touches no key. Refuses off-tip HEADs and any failing
  check — a typo'd tag is permanent under the creation ruleset.
- **`rk run`** — execute the checklist. Inspect before act at every step;
  halt on `conflict` or `undeterminable`; safe to re-run at any point.
- **`rk verify`** — re-download everything public and compare.
- **`rk setup`** — operator-local: derive required registrations and
  secrets from the declared channels, create what the API allows, instruct
  for the rest, and report each check as `verified`, `deferred`, or
  `manual`.

### Output contract

Every step has a stable id: `<unit>/<adapter>/<coordinate>`. `check` and
`run` emit one line per step, `STATUS  step-id  note`. Exit codes: `0`
clean or complete, `1` refusal (validation error, `conflict`, or
`undeterminable`), `2` usage. `blocked` is informational and never nonzero
by itself.

## Execution model

A release's arc: **declared** → **checked** → **authorized** (the signed
tag) → **in progress** across one or more runs → **complete**.

The checklist is a deterministic function of the manifests plus
`release.toml`. Ordering comes from native dependency pins: within a unit,
publication order follows first-party dependencies; across units, an exact
first-party pin becomes a public-reality prerequisite. No `requires`
language exists.

### Verdicts

- `absent` — proceed. Concluded **only from a definitive provider negative**
  (an authenticated 404 or empty list).
- `exact` — verified equal; skip and continue.
- `conflict` — halt loudly; a human decides.
- `undeterminable` — timeout, 403, 429, 5xx, or network failure. Halt
  without effect. Never collapsed into `absent`.

After rk's own act on a coordinate, or when an act returns "already
exists," inspection polls to a bounded deadline before concluding anything
— destination APIs lag their own writes. Deadline expiry is
`undeterminable`.

### Identity of reusable artifacts

Principle 7 governs every reuse decision. An artifact — staged or in the
workspace — is reused only when its digest equals one this release
produced, or one re-fetched from an immutable public coordinate. Anything
else is `conflict`. Consequences:

- **Deterministic archives are a requirement, not polish.** Fixed entry
  order, zeroed mtimes/uid/gid, normalized modes, no gzip timestamp.
  Without byte-reproducibility, "is this the asset I would have made" is
  undecidable, and reuse predicates degenerate into acceptability checks.
- **The draft is not an authenticated input.** Any principal with
  `contents: write` can create or mutate a draft, and Linux assets carry no
  signature or team to check. A staged asset whose digest is unknown to
  this release is `conflict`, never adoption.
- **Only self-authenticating artifacts are reused.** A file on disk is not
  evidence of itself, and rk mints no signatures of its own: a manifest of
  digests written beside the artifacts would be forged by the same attacker
  who swapped them, and any keyed alternative just moves the question to
  where the key lives. So reuse is limited to artifacts whose identity an
  external authority can confirm:
  - a **signed** macOS binary — `codesign` verification plus team and
    designated requirement; forging one requires the Developer ID
    certificate, and an older correctly signed binary fails the embedded
    version check;
  - an artifact **staged at a destination** — identity is the digest the
    destination reports, not the local copy;
  - **notarization state** — confirmed against Apple, not from local
    evidence.

  Everything else — unsigned binaries, archives not yet staged, pub
  package archives — is rebuilt rather than reused. Rebuilding a compiled
  binary costs a compile; the genuinely expensive steps (notarization,
  upload) sit downstream of an artifact that is already
  self-authenticating, so this rule costs almost nothing and removes an
  entire class of local-tampering question. It also bounds the damage of
  the residual case honestly: an attacker who can write to the workspace
  can usually also write to the source, so the workspace is not where that
  fight is won.
- **No cross-run workspace warming.** The workspace is keyed
  `<tag>-<commit>`, so successive local runs of the same release share one
  workspace and reuse everything in it; but a workspace is never seeded
  from a *different* run's artifact store — not CI-to-CI, not CI-to-local.
  A tag deleted and re-pushed at a different commit would otherwise let rk
  sign and publish binaries from the wrong source while every
  acceptability check passed. The cost is one rebuild per fresh CI run,
  which this design already declares acceptable; local retries lose
  nothing.

### The draft: adoption, staging, repair, and the flip

- **Adoption.** REST lookup by tag returns published releases only, and
  GitHub permits multiple drafts sharing one `tag_name`. Adoption therefore
  lists all releases, filters by `tag_name`, and requires exactly one
  candidate: zero → create, then immediately re-list and `conflict` if a
  twin appeared; two or more → `conflict`, naming both ids for human
  deletion.
- **Staging is hash-idempotent.** Release assets expose a SHA-256 digest,
  so `exact` is name plus digest with no download.
- **Repair is permitted, narrowly.** While the release is still a draft, an
  asset that is not in state `uploaded`, or whose digest does not match
  this release's artifact, may be deleted by asset id and re-uploaded.
  GitHub leaves `starter` corpses after interrupted uploads and rejects
  same-name re-upload with 422; without this, the most probable failure
  wedges the release permanently. This is repair of staging, not cleanup of
  product. rk still never deletes a draft, tag, or published release.
- **The flip re-verifies against reality, not the workspace.** Immediately
  before publishing: enumerate the draft's assets, require the exact frozen
  inventory, confirm every digest, recompute `SHA256SUMS` and the formula
  from those digests and compare to the staged copies, and require an
  attestation for every archive digest. Only then publish once. This closes
  the window in which a racing writer mints a permanently self-inconsistent
  immutable release.
- **Attestation verification is pinned** to the release-kit reusable
  workflow at its pinned commit (`--signer-workflow`); otherwise any
  workflow in the repository with `attestations: write` can mint an
  attestation rk would accept.
- **After publishing, verification failure is terminal.** Immutable
  releases cannot be edited, and deleting one permanently burns the tag
  name. rk retries immutability/attestation verification to a bounded
  deadline (provider state lags the flip), then states the only honest
  remedy: ship the next version; retract on pub.dev where supported; never
  delete or re-tag. Because attestations are CI-only, a locally staged
  release is blocked *before* the flip with "trigger CI to attest the
  staged digests" rather than published unattestable.

### Concurrency

The Actions concurrency group serializes CI against CI; one human
serializes local against local. The unserialized pair is local against CI,
so a local mutating run first probes for an in-progress release workflow
run for the same tag and refuses to mutate while one exists.

### Workspace and cleanup

The workspace holds no authority: deleting it, or CI artifact expiry, is
always safe and costs only recomputation. rk keeps no run ledger — status
is derived fresh on every invocation, so it can never be stale.

Staging is incremental durability: each staged asset banks progress at the
destination the moment it is done. A stagingless destination gets
all-or-nothing durability per terminal act, with the workspace as
accumulator and rebuild as recovery. When a destination offers a
pre-publication area, its adapter must use it.

Published assets are the product and are never cleaned up. The workspace is
deleted by the run that brings its release to `complete`; a failed step or
non-clean verdict keeps it for diagnosis. In CI, provider retention expires
it. Residue of an abandoned release is surfaced by `rk check` with sizes,
and deleted only by a human.

### Mutable pointers

The Homebrew formula updates compare-and-swap style: inspect (absent /
exact / older-clean-base / conflict), apply only if the inspected blob sha
is still current (Contents API `PUT` with `sha`, 409 on staleness),
re-read, then install from the public tap as a final check. "Older clean
base" is derived from reality — the tap formula must byte-equal the
`keybay.rb` asset of the release it names — so a hand-edited formula
correctly yields `conflict`. Verification reads via git fetch, never a
CDN-cached raw path. A 409 is re-inspect-and-reclassify, never a blind
retry.

## Secrets and auth resolution

Three rules, applied at every step:

1. **Facts** come only from the native manifests, published reality, or an
   explicit `[identity]` override. Never from the environment, never inferred.
2. **Secrets and sessions** resolve by one branch — `GITHUB_ACTIONS=true`
   and nothing else. In CI: the conventional secret names injected by this
   job's environment. Locally: the platform's native store under a
   conventional name. No mapping file; no ambient pickup; no interpolation.
3. **Coherence before use.** Every resolved credential is checked against
   the declared facts. A wrong credential fails as loudly as a missing one.

Conventional homes, v1. Environment names match what the fleet already
uses — the pub.dev name in particular is registered on pub.dev's side and
cannot be renamed unilaterally:

| Need | CI (environment → secrets) | Local |
|---|---|---|
| macOS signing | `macos-signing` → `APPLE_CERTIFICATE_P12_BASE64`, `APPLE_CERTIFICATE_PASSWORD` | keychain identity matching `identity.apple_team` |
| Notarization | `macos-notarization` → `APPLE_NOTARY_KEY_P8_BASE64` (secret); `APPLE_NOTARY_KEY_ID`, `APPLE_NOTARY_ISSUER_ID` (variables) | `notarytool` profile `rk-notary` |
| pub.dev publish | `pub.dev` → **no secret**; OIDC exchange (see below) | `dart pub login` session |
| GitHub release | `publish-github` → per-job `GITHUB_TOKEN` | `gh auth` session |
| Attestation | **none** (OIDC); CI only | not available locally |
| Tap update | `homebrew-tap` → `HOMEBREW_TAP_TOKEN`, a fine-grained token scoped to the tap repository only | normal git auth to the tap |
| Tag signing | **never in CI** | operator SSH signing key |

Adapter obligations these impose: the certificate is base64 in transit and
imported into an ephemeral keychain with `set-keychain-settings -lut`,
`import -T /usr/bin/codesign`, and `set-key-partition-list -S
apple-tool:,apple:,codesign:` (without which `codesign` hangs on a UI
prompt on hosted runners), with `--keychain` passed explicitly; the notary
key is materialized to a file because `notarytool` accepts only a key
path.

**pub.dev OIDC is not automatic.** `dart pub publish` does not perform the
GitHub OIDC exchange; the token is minted and registered by the
`dart-lang/setup-dart` step (or equivalently ~5 lines: fetch the JWT with
audience `https://pub.dev`, then `dart pub token add`). The `pub-dev`
adapter's CI path must do this explicitly and require `id-token: write`.
"Auth defers to native tools" does not mean "no code."

Native login commands (`dart pub login`, `xcrun notarytool
store-credentials`, later `npm login`, `gem signin`) are named by
diagnostics, run by the user, never read by rk. Local publishers run
attached to the terminal so MFA/OTP prompts pass through.

## Trusted execution boundary

A credential context contains only: rk itself, delivered as a prebuilt
binary verified by digest (never a checkout plus dependency resolution),
and the native tools it invokes. Concretely:

- **rk has no runtime dependencies at all** — `dart:*` and its own sources,
  nothing else, enforced by a test over the import graph and by an empty
  `dependencies:` block. A single transitive package in the signing path
  would put every upstream maintainer beside the Developer ID key. This
  also makes rk's own bootstrap trivial: a SHA-pinned checkout resolves
  nothing from any network, so a credential context can run rk before rk
  is able to release itself.
- **`verify()` never runs in a credential context.** A destination's
  verification never holds that destination's credential —
  `brew install` executes tap-authored Ruby, which must never run beside
  the tap token.
- **No repository-defined and no third-party-defined commands** run in any
  credential context.

## Provider-side enforcement

Derived from the declared channels. Each check reports `verified` (queryable
now), `deferred` (provable only inside a credential context, at the first
credentialed run), or `manual` (not queryable at all — rk prints the exact
values to confirm in the UI). "Clean" means no queryable check failing;
deferred items name the first credentialed run as their verifier of record.

- **pub.dev trusted publishing** — pinned to **repository, tag pattern, and
  Actions environment**. There is no workflow pinning; pub.dev's own
  documentation states that anyone with push access can publish, with tag
  protection and environments as the mitigation. Registration is not
  readable by any documented API, so this check is `manual`, with the
  publish step's 403 as the fail-closed runtime check. rk requires the
  environment field to be set (it is optional, therefore the easy thing to
  skip, and the only claim distinguishing the publish job from any other)
  and the tag pattern to equal the unit's derived pattern exactly.
- **Tag ruleset** restricting *creation* of the release tag namespaces.
  No provider rule can require a tag be signed — signature verification is
  rk's own, against `identity.tag_signer`.
- **Immutable releases** enabled. Not retroactive: pre-rk releases stay
  mutable and `rk verify` must not expect attestations on them.
- **Deployment tag policies** on every credentialed environment, restricted
  to that unit's tag patterns. This is the only provider control here
  enforced without a human click, and it is load-bearing precisely because
  the tag ruleset restricts who can create matching tags — the pairing is
  the mechanism, not belt-and-suspenders.
- **One secret per environment**; repository visibility is public (GitHub
  Free provides environments for public repositories only — the entire
  enforcement stack silently vanishes if a fleet repo is private on a free
  plan, so `rk setup` checks visibility).
- **Tap token** scoped to the tap repository only.
- **Deferred:** the signing certificate's team equals
  `identity.apple_team`; the notary credential authenticates; the tap token
  opens only the declared tap.

`rk setup` creates what the API allows with the operator's own credentials
(environments, deployment tag policies, rulesets) and prints exact commands
for the rest (`gh secret set … --env …`, so values flow through `gh` and
never through rk). It is an **operator-local verb**: `GITHUB_TOKEN` has no
`administration` permission, so these settings cannot be re-read from
inside a release run, and adding an admin token to a release context would
place the policy editor inside the context it polices.

### The caller workflow is trusted code

GitHub runs the caller workflow **as defined at the pushed tag's ref**. A
PR that lands real work plus a rewritten caller — same filename, same
trigger, its own job body declaring `environment: macos-signing` — steals
that environment's secret at the next release, with the deployment-approval
prompt arriving exactly when the operator expects a release. Therefore:

- `rk check` renders the caller workflow rk would emit and byte-diffs it
  against the file on disk, failing on any difference. This runs *before*
  the tag exists, and the signed tag covers `.github/workflows/`, which is
  what makes the signature meaningful.
- The reusable release workflow is pinned by 40-hex commit SHA, with the
  version tag in a trailing comment.
- Inside every credential context, before touching any credential, rk
  asserts the provider-signed OIDC claims — `repository`, `ref`,
  `environment`, and `job_workflow_ref` — against the checklist, and halts
  on mismatch. `job_workflow_ref` names the release-kit reusable workflow
  at its pinned ref, making this the one assertion a malicious caller
  cannot forge.

## Adapters

Every adapter step implements inspect, act, verify; destination adapters
share one interface:

```text
inspect(coordinate) -> absent | exact | conflict | undeterminable
stage(final asset)          # only where a staging area exists
publish()
verify(public vs expected)  # never in a credential context
```

v1 inventory:

- **`dart`** (ecosystem): parses pubspec/workspace/lockfile; validates
  version↔tag agreement, changelog entry, `dart pub get
  --enforce-lockfile` from a clean resolve, publish dry-run; derives
  ordering and prerequisites from exact first-party pins.
- **`dart-cli`** (build): `dart compile exe` per platform; native runners in
  CI (arm64 Linux runners are GA and free for public repositories), and
  native, cross-compiled, or emulator-assisted locally per the capability
  resolution above. Always smoke-runs the binary it produced.
- **`macos-sign`** (transform): ephemeral keychain with the incantation
  above; `codesign` parameterized by the derived team and code identifier;
  verifies against the published release's designated requirement, not
  against its own input.
- **`macos-notarize`** (transform): `notarytool submit --wait`; the notary
  log ships as a release asset. Default on resume is resubmission —
  identical bytes may be resubmitted and cost minutes. History-based
  adoption is optional and legal **only** when a per-submission
  `notarytool log` reports a sha256 equal to the exact bytes rk holds;
  name and recency are not evidence. `codesign --check-notarization`
  remains the binding verification.
- **`archive` + `checksums`** (transforms): deterministic tar.gz per
  platform containing the executable, LICENSE, and README, frozen public
  names; `SHA256SUMS`.
- **`pub-dev`** (destination): inspection via the pub.dev API; OIDC mint in
  CI; publish via `dart pub publish`; post-publish re-download and logical
  content compare (pub rewraps archives — name, type, mode, size, content;
  gzip mtime ignored). The exact-archive flags (`--to-archive` /
  `--from-archive`) are undocumented and pinned-SDK-dependent: feature-test
  at run start and fail closed with remediation if absent or changed. A
  package that has never existed yields a fifth outcome, `first-publish`,
  which prints the ordered interactive bootstrap commands and refuses to
  act.
- **`github-release`** (destination): adoption, staging, repair, flip, and
  verification as specified above.
- **`homebrew-tap`** (destination): formula from a closed template plus
  staged digests plus derived identity; Contents API CAS; public
  install check outside any credential context.
- **`github-actions` / `local`** (glue): the reusable release workflow with
  one environment per credential context and the rk-emitted caller per
  repo; the same binary run TTY-attached locally.

A proposed destination adapter must document: verdict semantics, terminal
act atomicity, post-crash inspectability (a platform that cannot be
classified after a partial submit fails the proposal), whether a
pre-publication area exists, and native auth flows in CI and locally.

## Local releases

The local path is first-class, and a complete multi-platform release from
one machine is a goal, not an accident. Two independent capabilities decide
whether a platform is producible on the current host: whether its binary
can be **built**, and whether that binary can be **executed** for the
acceptance smoke test. Both are required; a binary that cannot be run
cannot be accepted, and rk never lowers that bar for local convenience.

The `dart-cli` adapter resolves both per platform and reports the result in
`rk check`:

- **Native** — the host's own OS and architecture. Build and execute
  directly.
- **Cross-compiled** — `dart compile exe --target-os --target-arch`
  supports Linux targets only (`linux_x64`, `linux_arm64`, `linux_arm`,
  `linux_riscv64`), and only for projects with no native assets, since the
  SDK ships no C cross-toolchain. Measured on an Apple Silicon host with
  SDK 3.12.2, both keybay Linux targets cross-compile in seconds and
  produce correct ELF binaries with permissive glibc floors. The adapter
  must feature-detect this rather than assume it: a project with native
  assets, or a target the SDK declines, is not silently skipped.
- **Emulated execution** — a cross-compiled binary is smoke-tested through
  a container runtime (native speed for a matching architecture, emulation
  otherwise). Without a runtime available, the platform is blocked.
- **Blocked** — anything remaining reports
  `blocked: <platform> requires <capability>` with the missing capability
  named, and the release proceeds in CI or from a host that has it.

The capability set is discovered, never declared in `release.toml`:
platform intent is a product decision, and where a binary can be produced
is a fact about the machine.

Note the one target this rules out: an x64 macOS binary can be built
neither natively nor by cross-compilation on an Apple Silicon host, so a
unit declaring it requires CI or an Intel machine. Keybay does not declare
it, which is what makes a complete keybay release producible from one
Apple Silicon Mac — macos-arm64 natively, both Linux targets
cross-compiled and smoke-tested in containers.

Attestations remain CI-only: a locally published release has none,
`rk verify` reports that as expected-absent rather than `conflict`, and the
draft flip refuses to publish archives lacking attestations when the unit
declares them — so a fully local release is a deliberate, lower-assurance
mode, honestly labelled.

## Module layout

```text
release-kit/
  bin/rk.dart
  lib/src/engine/        # toml, checklist, runner, verdicts, diagnostics, setup
  lib/src/ecosystems/dart/
  lib/src/builds/dart_cli/
  lib/src/transforms/    # macos_sign, macos_notarize, archive, checksums
  lib/src/destinations/  # pub_dev, github_release, homebrew_tap
  lib/src/providers/     # github_actions, local
  doc/rfcs/
  test/                  # black-box fixtures: keybay-shaped, fleury-shaped,
                         # dune-shaped (must fail); import-graph test for
                         # credentialed paths
```

## What rk is not

Not a version bumper, changelog generator, CI system, test runner, task
runner, or plugin host. No hooks, no templates, no `--force`, no recursive
discovery, no override of native vetoes. Version preparation stays in
project tools; product tests stay in product CI.

## Keybay compatibility commitments

- Public asset names frozen: `keybay-<version>-linux-x64.tar.gz` style.
- Release archives contain the executable, LICENSE, and README. The
  `example/quickstart` files the current script packages are dropped, and
  the generated formula loses its `depends_on "libsecret"` and `license`
  lines. The post-install acceptance check runs the repository's quickstart
  against the installed binary instead of one shipped inside the tarball.
  Linux Homebrew users lose install-time resolution of `libsecret` and rely
  on keybay's own runtime error, which should name the missing tool.
- **`macos-x64` is dropped** — Intel Macs are out of scope as of this
  revision. The layout becomes six assets: three archives (linux x64,
  linux arm64, macos arm64), the notary log, `keybay.rb`, and
  `SHA256SUMS`. This is a deliberate, consumer-visible narrowing: an Intel
  Mac has no fallback, since it cannot run arm64 binaries. It is clean to
  do now because keybay 0.1.0 has no external downloads, and the 0.1.0
  release already differs from the current layout (it carries ten assets,
  with per-architecture notary logs and results). Reintroducing the
  platform later means adding one CI job and an Intel or CI build host —
  it cannot be produced on an Apple Silicon machine.
- Apple team `5AHFA9FUZG` and code identifier
  `io.github.danreynolds.keybay.cli` frozen; enforced against the published
  release's designated requirement.
- CLI tag namespace `keybay_cli-v{version}` unchanged; core migrates to the
  derived `keybay-v{version}` going forward (pre-rk `v{version}` tags remain
  history). This follows the target's own convention rather than diverging
  from it: pub.dev documents `v{{version}}` for single-package repositories
  and recommends a per-package pattern like `my_package_name-v{{version}}`
  for repositories with several packages. Keybay is the latter, and its CLI
  already uses the prefixed form. Migration requires one manual change —
  updating keybay's trusted-publisher tag pattern on pub.dev — which
  `rk setup` reports as a `manual` item; nothing external references core's
  tag namespace, since core publishes only to pub.dev.
- Existing environment names (`pub.dev`, `macos-signing`,
  `macos-notarization`, `homebrew-tap`) and existing secret and variable
  names are kept verbatim, so migration re-enters no secret values; only
  `publish-github` is new, and it holds no secret.
- The release body remains `--generate-notes` at creation time. Post-publish
  editability of an immutable release's body is undocumented and must not be
  relied upon.

## Dogfood plan

1. Engine + `dart` + `pub-dev` → release keybay core (`keybay-v0.2.x`).
2. Binary chain + `github-release` + `homebrew-tap` → release keybay cli.
   Retires the 806-line workflow.
3. Fleury: `rk check` prints the ordered interactive bootstrap for the five
   packages (`first-publish`), the human runs them in dependency order,
   trusted publishers are registered after each package exists, then rk
   owns every subsequent version.
4. Dune: only after it meets RFC 0001's hermetic-input admission criteria.

## Deferred by principle 10

Removed from v1, each on RFC 0001's priced ladder: the Release Registry
(every tier), the protected policy document and policy key, claim/envelope
identities and DSSE receipts, capability fencing, the multi-party tag
ceremony, plan admission by a separate control plane, toolchain
content-addressed materialization, the SQLite state lane, the credential
mapping file, global identity with overrides, and cross-run workspace
warming. Any of these returns only by naming the concrete failure it
prevents.

## Open items

1. Port `tool/compare_pub_archives.py` into the `pub-dev` adapter.
2. Verify container smoke tests for cross-compiled Linux binaries, and
   confirm that a cross-compiled Linux binary and a natively built one
   carry the same glibc floor, since the platform profile fixes that floor
   as a compatibility contract.
3. Whether to keep a CI macOS signing context at all. The Developer ID
   certificate is the one credential whose theft is unrevocable in
   practice, and local signing is already first-class; the cost of dropping
   it is that binary releases require the operator's Mac.
4. Publish a JSON Schema for `release.toml` so editors validate and
   autocomplete it.
5. `rk doctor` — fleet-consistency checker across repositories;
   build only when drift is real.
6. Final name. `release_kit` / `release-kit` / `releasekit` are unclaimed on
   pub.dev and Homebrew, and no significant project holds them on GitHub;
   `rk` is unclaimed on pub.dev and Homebrew and is not a common command.
   The one real consideration is [release-it](https://github.com/release-it/release-it),
   a popular and adjacent release-automation CLI whose name is one syllable
   away — worth a deliberate decision before anything is published.

## Relationship to RFC 0001

RFC 0001 remains authoritative for the threat model and residual-risk
analysis, the peer survey with pinned evidence, the Dune admission
criteria, and the assurance ladder. It is no longer the build plan.
Promotions from the ladder go through principle 10, recorded here.

## Review history

Revision 2 incorporates four independent adversarial reviews (security,
reliability, developer experience, platform realism). Findings adopted
include: the caller workflow as trusted code with byte-diff verification
and OIDC self-assertion; identity-not-acceptability as a first-class
principle; draft adoption by enumeration, hash-idempotent staging, narrow
staging repair, and pre-flip re-verification; deletion of cross-run
workspace warming; version monotonicity; the `undeterminable` verdict;
external verification of `code_id`; `rk tag`; the three-outcome setup
vocabulary and operator-local scoping; corrected pub.dev pinning semantics
(no workflow field) and explicit OIDC minting; SSH tag signing; the
trusted-execution-boundary section; the output contract; and terminology
fixes. Subsequent austerity passes removed the `[toolchain]`, `[archive]`,
and `[homebrew]` tables and the required `[identity]` block in favour of
derivation, and added `rk init`. Rejected:
restoring any mechanism from RFC 0001's ladder — no finding required one.
