# Production alpha readiness plan

Status: local implementation complete; supervised live gate pending,
2026-08-08. Pre-alpha simplification landed 2026-08-10: the consumer
probe, `--offline`, and the transient unsigned build are gone; macOS
build and signing are one producer; the pipeline is declared once; the
manifest carries only externally checkable facts; notary evidence is
stage-local; and `--json` is the agent contract at schema 5 with
`release --yes` as the noninteractive answer. This is
the current forward plan.
`doc/plan.md` remains the historical phase plan, review record, and evidence
ledger. Where its forward-looking design differs from this document, this
document is the decision to implement and RFC 0002 must be reconciled before
the affected code lands.

## Goal

Make rk ready for supervised production-alpha releases from the operator's
machine, with an austere surface and no hidden release state:

```text
rk init
rk status [unit]
rk release [unit] [--stage]
```

Bare `rk` remains `rk status`. Remote CI is important, but it follows the
first successful local production-alpha releases. Local tests, simulated
failure drives, real artifact production, and a supervised live release are
the gates in this plan.

The alpha continues to support the destinations implemented today: Git tags,
pub.dev, GitHub Releases, and Homebrew. npm is a plausible future adapter, not
part of this Dart-focused alpha.

## Starting point

This plan was written against baseline `bc2506a` on clean `main`:

- `dart analyze` passes with no issues.
- `dart run tool/validate.dart` reads secret_store, Fleury, and release-kit
  through real `rk status` paths with no crashes.
- `dart test` has 607 passing tests and two deliberate failures. Both failures
  require live release receipts that have not happened; they are not local
  implementation regressions.
- `status` already reads the configured public destinations, but does so
  sequentially. Its exactness is shallow in important places: pub.dev is
  primarily version presence, GitHub is asset-name inventory, Homebrew is a
  version pointer, and a remote tag is not proved against its peeled commit.
- The human status view still exposes `ready`, summarizes pipeline stages by
  platform instead of listing the actual artifacts, and does not inspect the
  work cache as strong staged evidence.
- `release` currently orders tag and pub.dev publication before the binary
  build/sign/notarize/archive chain. A local artifact failure can therefore
  happen after an immutable package version is public.
- `.rk/work/<tag>-<short-head>` is a deletable cache. It has no receipt that
  binds every artifact to the full source, plan, toolchain, signature, and
  notarization evidence.
- `--dry-run` runs the local chain, but it does not create the strong reusable
  stage promised by the agreed `--stage` workflow.
- `rk verify` provides a real but narrow historical pub.dev comparison. It
  does not prove the configured binary destinations and is being removed from
  the alpha surface rather than maintained as a second inspection product.

## Current implementation checkpoint

As of 2026-08-08, phases 0 through 7 below are implemented in the current
worktree. The local acceptance evidence is:

- `dart format --output=none --set-exit-if-changed .` passes;
- `dart analyze` reports no issues;
- the default test lane passes with no deliberate red tests, while the two
  production receipts remain isolated in `test/live_release_checkpoints.dart`;
- `dart run tool/validate.dart` exercises status against
  secret_store, Fleury, and release-kit with zero crashes;
- help exposes only `init`, `status`, and `release`, with `release --stage` and
  no `verify`, `--at`, or release-level `--dry-run` surface;
- a real local bare Git origin proves absent-to-exact annotated-tag creation,
  manifest binding, push read-back, and an idempotent retry;
- producer and receipt fault matrices prove that failed local work cannot
  reach a public act and that only an exact validated draft subset resumes;
- automated status cases cover the final-state matrix, parallel completion
  orders, pipe, JSON, `NO_COLOR`, and `TERM=dumb`; actual CLI review covers an
  ordinary online/unreachable report; and
- the partial-binary/missing-stage recovery case fails closed as
  `RK-STAGE-005` before rebuilding, authorization, or another public act.

The remaining path is deliberately operational rather than more feature work:

1. Review and commit this implementation on a clean, pushed source commit.
2. Run the supervised production-alpha gate below for the version selected on
   that commit, exercising Git tag, pub.dev, and GitHub Release with the
   configured macOS and Linux artifacts.
3. Record the two live receipts and repeat the release command to prove the
   no-op/idempotent path against real providers.
4. Keep Homebrew explicitly pre-alpha until a configured canary exercises it
   end to end from a clean consumer machine.
5. Add remote project CI after the live alpha; it does not gate the first
   supervised production release.

## Locked product contract

### Init

`rk init` is configuration scaffolding, not a release rehearsal. It stays
local and ordered:

```text
discover git-tracked manifests
  -> propose release.toml
  -> resolve and validate the proposal
  -> print it
  -> confirm
  -> write release.toml and, when needed, add .rk/ to .gitignore
```

It does not inspect public targets, build artifacts, use credentials, or
create a stage. It never edits an existing `release.toml`. Interactive
confirmation remains the normal path and `--write` remains the explicit
noninteractive acceptance of the exact displayed proposal. `--stage` and
`--dry-run` therefore have no meaning on `init`.

### Status

`rk status` is online and read-only by default. It derives the intended
release, checks every configured public target, inspects any exact local
stage, and answers five questions:

1. Are there issues?
2. If so, what are they and how are they resolved?
3. What version is currently published?
4. What version and targets are configured for the next release?
5. Is it safe to start or resume `rk release`?

Its work is ordered as resolve repository/configuration, derive the intended
release, inspect the local stage, inspect independent public targets in
parallel, then render one report. It may perform cheap read-only prerequisite
checks only where the native tool provides a safe one, but never builds, signs,
notarizes, packages, logs in, or writes a stage. Unsupported safe
authentication checks stay silent; there is no authentication-specific green
or unknown state, and normal release preflight owns the check. A report with
no `Issues` section therefore means no currently observable blocker; whether
the artifacts are staged is read off their own rows.

While target reads run concurrently, a TTY shows a fixed transient list:

```text
Release targets
  ⠋ Git tag             checking
  ⠋ pub.dev             checking
  ⠋ GitHub Release      checking
  ⠋ Homebrew            checking
```

Rows update independently. When all reads settle, the transient region is
erased and replaced once with a deterministic final report. There is no
partially assembled report in scrollback.

The final report has one section per configured release target. Each target
shows `current -> target`, its public condition in plain words, and the exact
artifact filenames it consumes. Any concrete issue linked to a target marks
that target's row `✗` and appears once in `Issues`, without changing the
target's public-state verdict. Global, prerequisite, and stage issues remain in
`Issues`; production and validation failures use the affected artifact rows.
Artifact marks have one meaning:

- `✓`: this exact artifact is present and validated in the matching stage;
- no mark: it has not been produced yet and no production problem is known;
- `✗`: rk already knows the artifact cannot be produced or validated.

The text also says `staged`, `not staged`, or the problem, so marks and colour
are never the only signal.

One fact appears once. A set of artifacts that agrees collapses to
`N artifacts` with its shared state; they are named individually the moment
they disagree, and an invalid one is never collapsed, because which and why
are the only questions it raises. Artifacts are not listed at all under a
target that is already public: those files are out there, and their local
staging has stopped being something anyone can act on. The unit's own line
carries `current › target` only when every target agrees there is movement —
otherwise each row carries its own, and none is invented — and it states
`unpublished` or `published` where an arrow would say nothing, because a bare
version cannot distinguish the two. It carries the tag only when the tag is
not the plain `v{version}` convention. Which target owns a shared artifact is
part of explaining a conflict, not part of the steady-state report.

There is no user-facing `ready`, `partial`, or `blocked` vocabulary. `Issues`
appears only when nonempty and every issue has one concrete `Fix:`. Only a
refusal concludes:

- `✗ N issues prevent release` when intervention is required;
- nothing at all otherwise. rk does not congratulate itself: success is the
  absence of a refusal, the rows already say what is published and what is
  staged, and exit 0 says it to anything parsing. The command that would
  advance the work stays in the document as `next[]`, where an agent reads
  it, and off the report, where it told an operator what they had just
  decided to do.

Colour is restrained: green for success, red for a concrete or actionable
problem (including an online target read that failed), yellow for an unknown
with no linked issue such as an unreachable read, dim text for secondary
facts, and bold section headings. `NO_COLOR`, `TERM=dumb`,
non-TTY output, and `--json` contain no ANSI or cursor movement. The final
non-TTY report has the same words and ordering as the settled TTY report.

### Staging and release

Every release has a mandatory internal staging phase. The separate command is
optional:

```text
# One-shot: stage internally, authorize, publish.
rk release rk

# Two-step: prepare and review exact artifacts, then publish them.
rk release rk --stage
rk status rk
rk release rk
```

`--stage` performs every local and package preflight for real: source
snapshot, package dry-run, build and sign as one step, smoke test where
possible, notarization, archives, release notes, release
manifest, and formula rendering. It may read public targets, use signing and
notary credentials, and contact Apple. It must not create or push a tag,
publish a registry package, create a GitHub Release, push a tap, or run
`dart pub login`.

A normal release uses an exact valid stage when one exists. Without one, it
creates the same stage internally before authorization. When at least one
configured pub.dev target is unfinished, a normal interactive release runs
exactly one native `dart pub login` before that private-stage boundary. Login
success proves only a current session, not uploader authority for every
package, and does not make a target green or exact. The publish attempt and
exact public read-back remain final; a retry skips a pub.dev target only after
that target is proved exact. An explicitly created stage is never silently
replaced with different bytes at publication time.

### Public target truth

There is no separate verification command or hidden historical verifier.
Each public destination owns one exact inspection operation. Both `status`
and `release` call that operation:

```text
inspect before acting
  exact    -> skip
  absent   -> act
  conflict -> stop with the difference and remedy
  unknown  -> stop rather than act blindly

inspect after acting
  exact    -> the step completed
  otherwise -> the release did not complete
```

The external command's exit status never establishes success by itself.
Re-running is safe because public reality, not a remembered process result,
decides whether each target still needs work.

Exact-candidate absence is not enough to authorize a version. Before private
production, and again immediately before authorization, `release` also reads
the newest version in every configured immutable public lane concurrently. An
unreadable history refuses; a lane ahead of the intended version requires a
version bump. This protects a shallow checkout whose local tags omit newer
origin history. Homebrew needs no second version-only listing: its authenticated
formula inspection permits an update only from bytes proved to be an earlier
release, and refuses an equal, newer, or unauthenticated formula.

For the alpha, exact means:

- **Git tag:** the remote ref peels to the expected full commit; signing and
  the staged manifest binding are checked when configured.
- **pub.dev:** the expected package version exists and the registry archive's
  contents match the immutable staged package source. Registry failure is not
  absence.
- **GitHub Release:** the exact expected asset inventory exists and every
  artifact digest agrees with the release manifest; names alone are not
  sufficient.
- **Homebrew:** the public formula bytes, version, URLs, and hashes equal the
  formula derived from the released artifacts; a matching version substring
  is not sufficient.

The local stage is not rk's database. It is disposable before the first public
act and after all configured targets are exact. During a partial binary
release it is recovery-critical: signing timestamps and notarization results
cannot be recreated byte-for-byte, while an already-public tag binds the
original manifest digest. `status` reports `RK-STAGE-005`, and `release`
refuses to rebuild, if some public binary-release targets are exact, others
are absent, and that exact stage is gone. The operator must restore the stage
from the staging machine. Durable remote staging would remove this operational
constraint, but remains deliberately outside the local production alpha.

When a binary release selects GitHub, the public release carries the manifest
with the artifact inventory, digests, source commit, and plan identity needed
after `.rk/work` is deleted. Its digest is also bound into the annotated
release tag. A pub.dev-only release has no honest standalone artifact filename
to invent: its public truth is recovered directly from the tag's peeled source
commit and the registry archive's exact contents. Its stage manifest remains
local evidence; the tag retains its digest, but that digest alone is not
presented as a downloadable public manifest. A signed tag authenticates its
binding; an unsigned tag proves consistency but not signer authenticity,
which remains an explicit alpha limitation.

## Alpha invariants

These are phase gates, not aspirations:

1. No tag, registry package, GitHub Release, or formula mutation occurs until
   a complete stage has been revalidated.
2. Every public target uses the same inspection in status, pre-act release,
   and post-act release.
3. Presence is never exactness where bytes or identity matter.
4. A retry never repeats a public act already proved exact, never acts on
   conflict, and never guesses through an unread target.
5. Deleting `.rk/work` before publication or after every target is exact may
   cost time but cannot lose public-release truth. During a partial binary
   release, a missing exact stage is reported and publication refuses rather
   than rebuilding different bytes or appearing safe.
6. Human and JSON output are recorded from the same observations; there is no
   parallel readiness state machine.
7. The default local validation lane is green without a real publish. Live
   receipts are explicit production-alpha gates.
8. Status and `release --stage` never run `dart pub login`. A normal interactive
   release runs it once only when unfinished pub.dev targets exist; login is a
   session preflight, while publish plus exact read-back establishes authority
   and completion.

## Implementation sequence

Each phase lands with formatting, analysis, the full default test suite, and
`tool/validate.dart` green. A later phase must not be used to excuse a red
earlier gate.

### Phase 0 — Make the contract and local lane honest

- Separate the two live-release receipt checks from the default Dart test
  lane. Keep them executable as an explicit live/checkpoint lane.
- Remove the `verify` verb from help, parsing, dispatch, README, RFC 0002, the
  JSON contract, and conformance tests.
- Delete `VerifyCommand`, its command tests, `--at`, historical verification
  reporting, and historical-ref source machinery that has no remaining user.
- Retain only code with a current release call site. The pub archive comparator,
  `.pubignore` handling, and registry archive download remain because the
  pub.dev target inspection needs them; move or rename them so they belong to
  that adapter rather than to a hidden verifier.
- Update `doc/plan.md` only where its current forward contract would otherwise
  contradict the three-verb alpha; preserve its historical evidence.

**Done when:** the default suite is entirely green, help exposes three verbs,
no `verify`/`--at` product surface remains, and post-publish pub comparison is
still exercised through release-target tests.

### Phase 1 — Give every release target one exact inspection

- Introduce the smallest structured target expectation/observation model that
  can carry destination, coordinate, current version, target version, public
  verdict, expected artifact names, evidence, and linked issues.
- Make the existing inspector delegate to destination adapters rather than
  carry shallow, command-specific answers.
- Deepen Git-tag inspection to compare the remote peeled commit.
- Move pub.dev lookup, polling, archive download, and source comparison behind
  one pub.dev target adapter.
- Deepen GitHub inspection from asset names to exact inventory and digests.
- Deepen Homebrew inspection from a version pointer to exact formula bytes.
- Give every provider bounded timeouts. Timeouts and malformed responses are
  unknown, never absence.
- Freeze each target contract with vectors for absent, exact, conflict, and
  unavailable worlds.

**Done when:** status and release cannot disagree about a target; a wrong byte
under the right name is detected; a same-version edited formula is detected;
a moved remote tag is detected; and no target is skipped on presence alone.

### Phase 2 — Build the immutable stage and receipt

- Define a stage identity from a versioned stage schema, full HEAD commit,
  HEAD tree, canonical resolved unit plan, rk implementation digest, and the
  version plus digest of the PATH-resolved compiler executable. Invoke that
  resolved path for production so the identified compiler is the compiler
  that builds, without depending on the SDK's private on-disk layout.
- Store it under `.rk/work/stages/<stage-id>/`; do not key trusted reuse by a
  tag plus shortened SHA.
- Materialize the committed tracked source into the stage and build/package
  from that immutable snapshot, not from a worktree that can change midway.
- Write a strict `stage.json` atomically. An artifact is atomically placed
  before the receipt may reference it.
- Record, per completed step, input digests and output path/type/mode/size/hash,
  smoke evidence, signature identity and certificate fingerprint,
  notarization binding/result/log, archive inventory, and notes/formula
  digests.
- Produce a separate publishable `release-manifest.json` containing no local
  secrets or paths. Publish it with binary releases; pub.dev-only exactness is
  recovered from the tagged source and registry archive instead.
- Add a read-only stage inspector. It may hash files, parse archives, and run
  signature/notarization checks; it may not execute candidate binaries,
  contact Apple, or modify the stage.
- Treat correctly named files without a valid receipt as unstaged, never as
  reusable evidence.

**Done when:** commit/config/target/platform/toolchain changes cannot reuse the
old stage; crashes cannot create a falsely complete receipt; planted, missing,
changed, extra, symlinked, or path-escaping artifacts are rejected; and
deleting a stage can never authorize or disguise different bytes. A missing
recovery-critical stage during partial publication must fail closed.

### Phase 3 — Make every producer stageable and reusable

- Change build, sign, notarize, archive, notes, manifest, and formula
  operations to return structured outcomes for the receipt writer.
- Run package-manager dry-run and consumer-resolve evidence as stage inputs.
- Derive every public filename through the one `ReleaseAssets` grammar.
- Reuse only after stage inspection proves the exact artifact and all of its
  dependencies.
- Never force-sign a valid staged binary: signing again changes the bytes and
  invalidates notarization reuse.
- Preserve honest platform evidence when a cross-built binary could not be
  executed.

**Done when:** a second identical stage performs no compile, sign, notary
submission, archive, notes, formula, or manifest generation; cheap authority
checks may rerun;
and a fully validated incomplete prefix resumes after its last recorded step.
If any recorded dependency differs, rk discards and rebuilds the still-private
stage instead of maintaining a second dependency-repair engine. A completed
stage that was reviewed is never replaced implicitly.

### Phase 4 — Put staging before every public act

- Make the checklist's stage and public phases explicit rather than relying on
  incidental list order.
- Enforce this dependency order:

  ```text
  inspect and preflight
    -> [normal interactive release with unfinished pub.dev: dart pub login]
    -> source snapshot
    -> package/build+sign/notarize/archive/notes/formula
    -> complete stage
    -> tag
    -> dependency-ordered registry packages
    -> GitHub Release
    -> Homebrew
  ```

- Require every public step to depend transitively on the complete stage.
- Recompute HEAD, tree, plan, signing baseline, stage receipt, and public
  observations immediately before authorization.
- For each public target, inspect immediately before acting and again after
  acting. Poll eventually consistent registries only to a bounded deadline.
- Treat `dart pub login` as one native interactive preflight before private
  staging, never as a public act, target verdict, or proof of uploader
  authority. A login failure is `RK-PUB-007` and halts with no public target
  change.
- Preserve what completed, what failed, and what was not attempted in human
  and JSON output.
- Make an ambiguous act outcome rely on read-back truth: exact means complete;
  unread means rk lost track; conflict is terminal.

**Done when:** fault injection proves every local act precedes the first public
mutation, all destination changes between preflight and act are observed, and
every interruption can be resumed without repeating an exact public act while
the recovery-critical stage is retained; deleting that stage must instead fail
closed with a specific restore instruction.

### Phase 5 — Expose `--stage` and remove `--dry-run`

- Route both one-shot release and `release --stage` through the same staging
  implementation.
- `--stage` stops after complete receipt validation, performs no release
  authorization, runs no registry login, and performs no public mutation.
- A normal release revalidates and reuses an exact stage, then performs only
  the remaining public acts.
- Replace `--dry-run`; do not keep aliases for one job. Status already owns
  read-only preview, while stage owns real private preparation.
- Disclose before staging that signing/notary credentials may be used and
  Apple may be contacted even though nothing is published.

**Done when:** call traces prove `--stage` has no tag/pub/GitHub/tap mutation;
status immediately recognizes its exact artifacts; and the following release
performs zero producer/sign/notary/archive work.

### Phase 6 — Land the agreed status experience

- Build one `Release targets` view from the same target observations and stage
  inspection used by release. Do not reconstruct it from prose or step IDs.
- Inspect independent public targets concurrently while preserving configured
  order in the final report.
- Add a narrowly scoped multi-line transient target region for TTYs. Delay it
  briefly to avoid flicker, update fixed rows independently, cancel every
  timer on completion/error/close, erase the region, and render the final
  report once.
- Always show the final target tree, including when every target is already
  published.
- Show an agreed aggregate `current -> target` only when public targets agree;
  otherwise show each target's current value and do not invent one.
- List exact artifact filenames beneath their owning target. Show stage marks
  only from the stage inspector, never from file existence.
- Remove the human `ready` header and platform pipeline strings.
- Group every repository, prerequisite, artifact, target conflict, and unread
  target into one deduplicated `Issues` section with a concrete `Fix:`.
- Mark a target row `✗` whenever any concrete issue is linked to that target.
  Do not add an authentication lifecycle state: unsupported safe checks stay
  silent and release preflight owns them.
- End with one natural conclusion and at most one next command.
- Record the same structured target/artifact/issues facts in JSON without a
  second lifecycle enum.

**Done when:** concurrency tests prove at least two target reads are in flight;
final ordering is deterministic; normalized settled TTY output equals piped
output; colour and marks are redundant with words; `NO_COLOR`, `TERM=dumb`,
non-TTY, and JSON contain no transient control sequences; and snapshots cover
clean, first release, unstaged, fully staged, safely resumable, conflicting,
unreachable, and fully published cases.

### Phase 7 — Exercise every distinct failure and resume boundary

The stage has one shared atomic artifact writer and one shared receipt writer.
Exercise each invariant-bearing primitive and provider boundary; multiplying
the same test by every filename would add cases without adding a safety claim.
Inject failure or interruption:

- before and after artifact placement and receipt replacement;
- during each producer operation class;
- before and after each public-target act class;
- after a registry accepts a package but before the client receives success;
- when the one interactive `dart pub login` exits unsuccessfully, proving the
  run halts before private staging or any public target change;
- during GitHub upload and read-back;
- after a tap push but before formula read-back;
- while a representative three-target status read finishes in every possible
  order.

Also exercise a real filesystem stage twice, tamper every recorded artifact
type, change source/config between stage and release, and use local bare
remotes plus fake registry/forge/tap worlds for public transitions.

**Done when:**

1. `dart format --output=none --set-exit-if-changed .` passes.
2. `dart analyze` passes.
3. The default `dart test` lane passes with no deliberate red tests.
4. `dart run tool/validate.dart` passes against the three real repositories.
5. One-shot release traces show no public act before stage completion.
6. `--stage` traces show no public act at all.
7. A second identical stage has zero expensive producer calls.
8. Every retry skips exact public targets, acts only on absent targets, and
   refuses conflict or unknown.
9. No kill point can make a receipt bless different bytes.
10. A missing stage during a partial binary release refuses before rebuilding
    or acting and names the exact recovery requirement.
11. Manual TTY review confirms the transient target list and representative
    final reports are clean at narrow and ordinary terminal widths; automated
    snapshots cover the complete status-state matrix.
12. Status and `--stage` traces contain no `dart pub login`; a normal
    interactive release with unfinished pub.dev work contains exactly one,
    and only publish plus exact read-back completes the target action ledger.

## Supervised production-alpha gate

The live gate is intentionally after every local gate above and does not wait
for remote CI.

Before the first command, prove the native credentials and transports that rk
deliberately delegates rather than stores:

- `security find-identity -v -p codesigning` must show the intended Developer
  ID Application identity. Zero or ambiguous identities stop the gate.
- `xcrun notarytool history --keychain-profile rk-notary` must authenticate
  with the profile the macOS adapter uses. If it is absent, create it
  interactively with `xcrun notarytool store-credentials rk-notary`; both
  commands contact Apple.
- `gh auth status --hostname github.com` must prove GitHub CLI access.
- `git push --dry-run origin HEAD:refs/heads/main` must prove push transport
  after the release commit exists. A dry run publishes no ref.

Do not put credentials or their raw values in the receipt.
Do not run `dart pub login` as a separate manual prerequisite: the stage-only
command below must not invoke it, and the normal interactive release must run
it exactly once when it sees the unfinished pub.dev target. Its success proves
a session, not package uploader permission.

1. Choose and record the canary unit/version and exactly which adapters it
   exercises. release-kit itself currently exercises pub.dev and GitHub
   Release with macOS and Linux artifacts. Homebrew needs a configured canary
   before that adapter is called alpha-tested.
2. Start from a clean, pushed commit with the intended version and changelog.
   For release-kit's self-hosted first release, run every command from that
   checkout as `dart run bin/rk.dart ...`; do not use an older globally
   installed `rk`. First require `dart run bin/rk.dart --version` to report the
   intended version and `dart run bin/rk.dart --help` to show the locked
   three-verb surface.
3. Run `dart run bin/rk.dart status rk` and confirm every target coordinate,
   current/target version, artifact filename, issue, and remedy is correct.
4. Run `dart run bin/rk.dart release rk --stage`; its complete transcript must
   contain no `dart pub login` invocation.
5. Copy the exact `.rk/work/stages/<stage-id>` path printed by rk into an
   external transcript. From that directory, independently:
   - hash `release-manifest.json` with the exact command
     `shasum -a 256 release-manifest.json`;
   - hash each archive with `shasum -a 256 <archive>` and confirm the digest
     matches its `release-manifest.json` entry;
   - list each archive with the exact command `tar -tzf <archive>` and confirm
     its inventory is exactly `rk`, `LICENSE`, and `README.md`;
   - extract each runnable archive into a fresh temporary directory and require
     its `--version` output to equal `0.0.1`;
   - extract the macOS archive into a fresh `alpha_macos_dir`, run its exact
     `rk --version`, and bind every native check to
     `"$alpha_macos_dir/rk"`: run
     `codesign --verify --strict --verbose=2 ... && echo "signature valid"`,
     `codesign -d -r- --verbose=4 ...`, and
     `codesign --test-requirement=notarized -v ... && echo "notarization
     valid"`; and
   - print both notary JSON files with `cat` and require the result file's
     `id` and the log file's `jobId` to be the same submission with an
     `Accepted` status in each.
   Preserve command output, not a prose assertion that these checks passed.
6. Run status again. It must show every artifact staged and raise no issue.
7. Run `dart run bin/rk.dart release rk`. Require exactly one attached native
   `dart pub login` before the private-stage boundary, review the final
   consequences, and type the version. If login fails, preserve `RK-PUB-007`,
   run `dart pub login` from a terminal as instructed, and rerun the unit
   release; do not treat a successful login as proof of uploader permission.
8. Require the actual pub publish and post-act exact inspection for every
   configured target before the command reports completion. Login alone must
   not complete or green a target.
9. Run `dart run bin/rk.dart status rk` from a fresh process. It must report
   the published versions and public target contents correctly without relying
   on process memory.
10. Run `dart run bin/rk.dart release rk --json` again. With every target now
    exact, it must run no second login and perform no public act. Preserve the
    report proving every configured public step is `exact` with action
    `already_exact`.
11. Consume each configured public destination without using the checkout or
    the stale global installation. First clone what was published into
    `alpha_consumer_repo`, a fresh directory outside the release checkout:
    `git clone --depth 1 --branch v0.0.1
    https://github.com/danReynolds/release-kit.git "$alpha_consumer_repo"`.
    Each consumed binary is then exercised against it.
    - Set `alpha_pub_cache` to a fresh temporary directory. Activate with
      `PUB_CACHE="$alpha_pub_cache" dart pub global activate release_kit 0.0.1`,
      then run `"$alpha_pub_cache/bin/rk" --version` and
      `"$alpha_pub_cache/bin/rk" --help` by that exact path.
    - In another fresh directory, download the selected GitHub archive and the
      published `release-manifest.json`. Select that archive's digest, compare
      it with `shasum -a 256 <archive>`, extract the archive, and run the
      extracted `./rk --version` and `./rk --help`. The manifest URL and
      archive URL must both be the public `v0.0.1` GitHub Release.
    - Then make each consumed binary do rk's actual work, which `--version`
      and `--help` do not: from `alpha_consumer_repo`, with that binary's
      directory first on `PATH`, run `rk status rk` **by bare name** —
      `cd "$alpha_consumer_repo" && PATH="$alpha_pub_cache/bin:$PATH" rk status rk`,
      and the same with the extracted archive's directory. Require exit 0 and
      every target `published`. A bare name is not a nicety: an
      installed binary derives its own identity from `argv[0]`, and rk once
      shipped a build that answered `RK-STAGE-002` for every repository whose
      directory did not happen to contain a file named `rk`. `--version` and
      `--help` inspect no stage and would have reported that build healthy.
    For Homebrew, use a machine or environment that has not seen the repository
    checkout.
12. Until the idempotent rerun is complete, preserve every command transcript,
   stage identity, public manifest digest, notary submission id, target URL,
   and any divergence in a file outside the tracked checkout. Editing the
   receipt earlier would dirty the release tree and invalidate the retry
   exercise. When transferring evidence into the receipt, normalize command
   lines as `$ <exact command>` so each command's unchanged output has an
   unambiguous boundary.
13. Fill `doc/production-alpha-receipt.md` from that evidence, set its status
   to exactly `completed`, run
   `dart test test/live_release_checkpoints.dart`, then commit and push the
   receipt so the live evidence is durable.

A target adapter becomes production-alpha-ready only after one real release
and an idempotent rerun exercise it. The tool may enter a narrower alpha with
pub.dev and GitHub Release while Homebrew remains explicitly pending its own
canary.

## Deferred until after the live alpha

- Remote CI, OIDC/trusted publishing, remote artifact transport, concurrency
  leases, and CI-generated evidence.
- npm and other package ecosystems.
- A standalone historical audit/verification command. It should return only
  if real operator demand justifies reconstructing and authenticating older
  releases independently of the current release plan.
- Cross-machine stage reuse and durable remote stage storage.
- Reproducible-build claims, DSSE/Sigstore-style attestations, and a threat
  model that protects against a malicious same-UID local user modifying both
  receipt and artifacts.
- pub.dev archive mode comparison. Alpha exactness proves regular entry type,
  inventory, and every file byte in both directions; `SourceTree` does not
  expose modes.
- Hooks, plugins, version bumping, changelog generation, and generalized task
  running.

## Main code areas

- CLI surface: `bin/rk.dart`
- Commands: `lib/src/commands/status.dart`, `lib/src/commands/release.dart`
- Plan and observations: `lib/src/engine/checklist.dart`,
  `lib/src/engine/inspect.dart`, `lib/src/engine/resolve.dart`
- Stage: `lib/src/engine/workspace.dart` plus new identity, receipt, and
  inspection modules
- Targets: `lib/src/destinations/git_tag.dart`, a pub.dev destination adapter,
  `lib/src/destinations/github_release.dart`, and
  `lib/src/destinations/homebrew.dart`
- Artifact production: `lib/src/binary_chain.dart`, `lib/src/builds/`, and
  `lib/src/transforms/`
- Human and JSON surfaces: `lib/src/output/`
- Gates: command, status, release, workspace, target, output/liveness,
  conformance, and new stage/failure-injection tests under `test/`
