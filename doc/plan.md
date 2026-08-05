# Implementation plan

Against RFC 0002 revision 3. Milestone 1 is a local release of keybay core
to pub.dev; milestone 2 is the full binary chain for keybay cli.

The sequencing is chosen so that **rk can be pointed at keybay very early
with zero risk** — two of the four verbs change nothing, and keybay already
has a published 0.1.0 to check against.

## Phase 1 — Engine core

Pure computation, no network, no subprocesses.

- Strict TOML subset parser: accepts only the schema's constructs, rejects
  everything else by construction rather than by later validation.
- pubspec reader: name, version, `publish_to`, executables, dependencies.
- Version grammar, comparator, and frozen test vectors.
- Config validation and unit/tag derivation.
- Checklist derivation, including dependency ordering and prerequisites.

**Test fixtures:** keybay-shaped (two units), fleury-shaped (a
multi-project unit plus a single), dune-shaped (must be refused).

**Done when:** `rk` parses keybay's `release.toml` and prints the derived
checklist offline.

## Phase 2 — Output

Built early because everything renders through it and retrofitting output
is miserable.

- Collapse, terseness, and the four-glyph verdict gutter.
- Liveness: expand while running, collapse when done, non-TTY append-only.
- Halt sentences, conflict evidence, remediation commands.
- `--json`, stable and surviving non-zero exit.
- Diagnostic codes and the diagnosis directory.

**Done when:** the phase 1 checklist renders in both TTY and piped form,
with identical content.

## Phase 3 — Probes and `rk status`

- pub.dev API client (`dart:io`, no dependencies).
- GitHub read API for releases and assets.
- git state: tags, worktree cleanliness, HEAD vs remote.
- Verdict classification, including the definitive-negative rule.
- Identity derivation from the last published release.

**Done when:** `rk status` runs against the real keybay repository and
reports core and cli correctly against live pub.dev and GitHub state.

**First keybay checkpoint — read-only, nothing can be published.**

## Phase 4 — the comparator, worn by `rk verify`

Verify is the core primitive, not a sibling verb: phase 5's post-publish
check and phase 7's post-flip check are the same comparison. One engine —
resolve-at-ref via a `SourceTree` reading git blobs, archive-vs-tree logical
compare — and the `verify` command is its thin CLI face. Release calls the
same engine, so the two cannot drift the way the two inspectors did.

Hard constraint, named so it cannot erode: verify needs no state, no
credentials, and no `.rk/` — anyone with a fresh clone can prove a published
artifact against its tag. That property is the tool's differentiator.

- Download a published pub.dev archive and compare logically (the
  `compare_pub_archives.py` port: name, type, mode, size, content, ignoring
  archive timestamps).
- Resolve config and sources at a tag.
- Provenance output, and honest reporting of what is not knowable.

**Done when:** `rk verify` passes against keybay 0.1.0, which is already
published — so the comparison logic is proven against real data before rk
ever publishes anything.

**Second keybay checkpoint — still read-only.**

## Phase 5 — `rk release` for pub.dev

- Confirmation flow, including type-the-version for permanent acts.
- Tag step: create, sign when configured, push, with inspect/act/verify.
- Publish step via `dart pub publish` against the operator's session.
- Consumer resolve and dry-run validation before publishing.
- Post-publish re-download and compare.
- Resume: re-running skips what reality says is done.

**Done when:** keybay core publishes to pub.dev via rk — and the gate kills
rk mid-release and re-runs: once after the tag lands and before the publish,
once after the publish and before the confirming read. "Re-running is the
resume" is the whole recovery story, and a claim that central is proved by
execution or not at all. The confirming read itself polls to a bounded
deadline (the registry may take a moment to list what it just accepted), on
the invalidated cache — never the memo the pre-act inspection wrote.

**Third keybay checkpoint — the first real release.** Requires a keybay
core version bump, which is a product decision, not an rk one. Everything
up to the publish call is exercised by `--dry-run` first.

## Phase 6 — `rk init`

Repository scan of git-tracked manifests, classification, config
generation, confirmation. Late because a hand-written `release.toml` is
enough for phases 1–5, and init's value is clearest on fleury's sixteen
manifests rather than keybay's two.

**Milestone 1 complete.** rk can onboard a repository and release a Dart
package locally, end to end.

## Phase 7a — the local chain

Split from the destinations: this was six subsystems behind one gate, on the
phase with the most unreviewed code. 7a is everything that happens before a
destination is touched — and it ends with `--dry-run`: every local step and
every inspection, stopping before any public act. The failure rehearsal
prevents is discovering the expired certificate or broken notarization at
minute 40 of an announced release.

- Decompose the chain into the checklist's steps (no `_produced` carried
  between them; the workspace interface returns here, around the thing that
  needs it).
- Wire `Activity` into the notarization wait — built, tested, and hand-rolled
  around today.
- `dart-cli` build with per-platform capability resolution (native,
  cross-compiled, emulated smoke test, buildable-unproven, blocked).
- `macos-sign` and `macos-notarize`, with the signature compared against the
  requirement `PublishedIdentity` derives from the release users already
  installed (its gate is red until this wiring lands).
- Deterministic `archive` and `checksums`.

## Phase 7b — the destinations

- `github-release`: sweep-and-recreate over same-tag drafts (adoption is
  deferred to CI per the RFC's own paragraph), create delegated to gh's
  draft-first create, confirm by read-back — reading the forge through
  `gh api` status codes, not porcelain message strings ("release not
  found" means three different things).
- `homebrew-tap`: formula render, compare-and-swap, public install check.
- The expected asset set grows what 7a/7b actually produce — notary log and
  result, the formula — so the equality check stays equal. Real keybay 0.1.0
  reads as a conflict today precisely because these are published and rk does
  not yet count them; the next rk-made release settles it.
- The changelog entry becomes the release body (drop `--generate-notes`):
  one source of release prose, so the notes and the CHANGELOG cannot
  disagree.

**Done when:** keybay cli releases three platforms end to end — signed,
notarized, published immutable, formula updated, installed from the public
tap.

**Milestone 2 complete.**

## Phase 8 — Fleury

Bootstrap its packages by hand (pub.dev requires an interactive first
publish), then rk owns every subsequent version. Exercises multi-project
units, derived ordering, and cross-unit prerequisites — the paths keybay
never touches.

## The austerity pass on the surface

Two ways to ask one question is a bug in the surface, so the flags were
held to the same test the code is: **name the failure it prevents that
nothing else prevents.**

- `--rehearse` and `--dry-run` were two flags for one job, and the weaker
  one duplicated a whole verb: "inspect and stop before acting" is what
  `rk status` says. One flag survives, `--dry-run`, with the semantics
  worth having — every local act for real, nothing public touched.
- `-v` / `--verbose` was a second, worse rendering of the default view: it
  carried *less* verdict information than the lanes it replaced, and the
  diagnostic codes it used to gate now ride every problem line in every
  mode. `--json` is the surface for everything-at-once. Cut, along with the
  renderer behind it.
- `--offline` survives, and the test says why: nothing else gives a
  network-free answer. It stopped being a mode the verb branches on,
  though — it is now wiring (a null registry and null tools, exactly like
  an absent forge), so offline renders through the same lanes as a live
  run and says "not read: --offline" where it did not read. The
  offline-only renderer went with the branch, and offline gained honesty:
  it reads git, so a missing tag reads `absent` rather than shrugging.

What is left is one flag per job: `--json`, `--dry-run`, `--offline`,
`--write`, `--at=<ref>`, `-h`.

### …and on the config

The same test, applied to `release.toml`, found three things:

- **`tag_signer` was dead.** Accepted by the parser, stored on the config
  object, read by nothing. A promise with no implementation is the worst
  kind of surface. Cut.
- **`apple_team` was drift, not design.** The RFC always specified the
  keychain rule — one Developer ID certificate is unambiguous, several
  fail closed with the list, none says a certificate must be installed —
  and the implementation had grown a declaration requirement instead. rk
  discovers it again, so the key is gone, and a first signed release now
  *states* which certificate it made permanent rather than asking to be
  told.
- **`[identity]` was a modelling footgun.** It was global; a code
  identifier is per-unit. A repository with two binary units would have
  signed both as the same program. The table is gone: `code_id` and
  `homebrew_tap` are unit settings now, both optional, and `code_id` is
  consulted only for the one release that has no published binary to
  derive it from.

`release.toml` is now: `schema`, `[release.<unit>]` with
`tag`/`path`/`publish`/`binary_platforms`/`code_id`/`homebrew_tap`, and
`[[release.<unit>.project]]` rows for a unit with several projects.

### …and on the code, by workflow

Eleven agents surveyed the codebase, proposed three decompositions of
`release.dart` independently, judged them by austerity, spec-fidelity and
risk, and synthesised one staged plan. **The minimal-cut proposal won**,
two judges of three ranking it first. Six stages landed, each gated at
579 passing / 2 deliberate reds; `release.dart` went 1226 → 1200, which
was not the point.

What actually moved:

- **`engine/assets.dart`** — the published asset grammar was spelled in
  four places. That is a latent, permanently unfixable failure, not
  untidiness: `GithubRelease.inspect` calls *any* expected-vs-published
  difference a conflict, a published release cannot be edited, and the
  publish step's verify leg compares only against what it just uploaded.
  One name out of step between producer and inspector lets rk publish a
  release and read it back, next run, as an unfixable conflict against a
  release it made itself. The comment claiming the checklist and the
  inspector "cannot share code (they would import each other)" was
  written during the asset-count fix and was false — verified before
  deletion.
- **`GitState.uncommittedProblem()`** — RK-GIT-001 meant two `--json`
  payloads: status pluralized and named up to eight paths, release said
  "1 paths are uncommitted" and named none. `unpushedProblem`'s own doc,
  one method away, already forbade exactly this.
- **`RK-GIT-002`** — a missing origin refused through `Output.line`, which
  writes only to the sink, so a `--json` caller got an empty `problems`
  array. Same invisibility RK-BREW-001 was created to end.
- **Four derivations onto the resolved model** — `binaryProject`,
  `tapFor`, `fileAt`, `directoryIn`, replacing ten sites, two of which
  were `firstWhere` calls throwing StateError (a crash at exit 3) for an
  invariant RK-RES-009 already refuses.
- **`destinations/git_tag.dart`** — the git protocol leaves the verb, with
  a sealed three-way presence type so "unknown never collapses into
  absent" is structural for the tag rather than a discipline each caller
  remembers.

**What was refused, and why it is worth recording.** `_release` stays one
ordered pipeline: the proposed preflight/execute split formalises the
CI-seam-1 violation instead of removing it, and the three wires it
re-plumbs are pinned by nothing (every sign step in the suite receives a
null `publishedRequirement`, and `notes` is read by no test), so under a
frozen tally the pins cannot be added first. `_authorize` stays welded to
the pipeline — every disclosure is computed at the point of the decision
it discloses, and separated, the reason a sentence is true stops being
visible beside it. The pub.dev block stays: RFC 0002 assigns the publish
dry-run and the consumer resolve to the **ecosystem** adapter, not the
destination, so extracting them would put ninety lines in the module the
spec says they do not belong to.

### Deferred, with the condition each waits on

1. **`destinations/pub_dev.dart`, partial** — `_publish`,
   `_refuseFirstPublish`, `_confirmPublishedBytes` and the poll policy.
   Condition: the tally may move, so RK-PUB-002/003 become directly
   testable, which is the only thing the extraction buys.
2. **Pins for four blind spots** — RK-HOST-001 through injected
   capabilities; a *non-null* `publishedRequirement` at the sign step;
   `notes` against the CHANGELOG body; RK-TAG-001 by code. Plus a
   `git_tag_test.dart`. Condition: consent to raise the count.
3. **`_act`'s two out-of-band parameters** — reading the baseline from the
   workspace by name would make "no earlier signed release" and "the
   baseline was never written" the same observation, and the second
   silently *skips* the signing proof. Unknown collapsing into absent, at
   the signing gate. Needs an explicit no-baseline record and pin 2 first.
4. **`engine/forge.dart`** — three implementations of the gh-404
   definitive-negative rule, and two divergent contents decoders, one of
   which (`binary_chain`'s tap read-back) collapses every failure to null.
   The honest justification is fixing that collapse, which is a behaviour
   change no test distinguishes.
5. **The first-publish fact, derived four ways** — already ledgered above.
6. **`report.acted` / `report.halted` as an out-of-band return channel** —
   `_act` returns bool, which cannot say *which* halt occurred.

## Constraints to hold throughout

From RFC 0002's CI-readiness section, binding on every phase:

1. No state between steps — each executable in isolation from the
   checklist, its step id, the workspace, and reality.
2. One credential chokepoint — never an inline lookup in an adapter.
3. The workspace is an interface, not a path.
4. Assurance is recorded data, not a branch.
5. Authorization is a signal with carriers.
6. Optional evidence degrades honestly.

Plus: zero runtime dependencies, enforced by a test over the import graph.

## Review doctrine, amended after phase 4

Three rules added, each from a failure this project had:

1. **Reviewers run in isolated clones, never the shared working tree.** Two
   phase 4 reviewers ran concurrently in one tree; the mutation reviewer's
   live mutations were observed by the spec reviewer as an intermittent
   "conflict read as exact" — three sightings, a preserved artifact whose
   field combination no shipped branch constructs, and hours spent ruling
   out the VM before the collision was recognized. The artifact was
   manufactured by a mutation the mutation reviewer was explicitly
   instructed to try. An isolated 400-run soak at the same commit was clean.
   The comparator was sound; the process was not.
2. **A gate for an unstarted phase is skipped with its reason, and
   unskipping it is part of starting the phase.** Deliberately-red gates
   made "is the suite green" a judgment call, which is the ambiguity gates
   exist to remove.
3. **Acknowledged partials are written where the code is.** The comparator
   does not compare file modes (SourceTree exposes none); it says so in its
   own doc, and mode verification is a 7a obligation, where rk builds the
   archives whose modes it controls. A crash during a read-only verb writes
   `.rk/diagnosis` — the one write such a verb may make, because a crash is
   a bug in rk and the stack is the only copy of what went wrong.

## Review record

A phase is done when its group in `test/phase_conformance_test.dart` passes.
Each phase gets an adversarial review before the next one starts, and what the
review found is recorded here — the point of writing it down is that "we
reviewed it" is otherwise indistinguishable from "we meant to".

**Phase 1 — engine core.** Two rounds. Round two found ten, of which two were
fail-open: `Checklist.derive` took its `Diagnostics` as an optional argument no
production caller passed, making `RK-DEP-001` — the top-ranked failure class —
unreachable code; and a pubspec written with flow collections parsed as an
opaque scalar, so a package pinned by path looked like a package with no
dependencies and dune, the repository the plan says must be refused, was
accepted. The rest: shared prerequisites duplicated as steps, a key indented
into a block sequence escaping to the root map, sequences at their parent key's
column refused, the tag convention counting registry packages so two units
could derive one tag, a tag pattern git would refuse caught only at tag time, a
`tag` on a project row silently ignored, a dependency circle crashing the sort,
and `permanent` marking steps rk itself deletes and recreates.

**Phase 2 — output.** Five findings. One severe: a repeating timer keeps a Dart
isolate alive, so a step abandoned by a thrown exception turned a crash into a
hang. Then: a crash produced no JSON despite `--json`'s one contract being that
it survives a non-zero exit; `Activity` wrote prose into the `verdict` field a
caller keys on; `rk init --json` wrote its prompt past the sink `--json`
silences; and the diagnosis path was announced only in prose. Read-ahead into
`GithubRelease` found three more cardinal-rule violations, fixed with it.

**A note on what the reviews keep finding.** Both phases' worst findings were
the same shape: a safety check that could not fire, and a failure path that
answered with a definite negative. Neither shows up in a passing test suite,
which is why the review is a phase gate rather than a nicety.

## Assessment of the code phases 3–7 already have

Written before resuming phase 3, from reading what an earlier abandoned run
left behind. The question for each was: keep, iterate, or rebuild.

**Phase 3 — probes and `rk status`. Iterate.** The registry client is the best
code in the repository — every failure path becomes `unknown`, only a 404
concludes absence — and it now has tests against a real server that prove it.
`StatusCommand`'s shape is right. What is missing is what the plan says:
nothing reads the forge (every non-pub.dev channel is collected into
"not checked"), there is no identity derivation, and the online path never
calls `output.step`, so `rk status --json` returns units with an empty `steps`
array — the machine surface is empty exactly where a caller needs it.

**Phase 4 — `rk verify`. Rebuild the substance, keep the reporting.** What
exists asks pub.dev "does this version number exist?" and, if so, prints
"verified". No archive is downloaded, nothing is compared, no config or source
is resolved at a tag. `Provenance` is written but never constructed anywhere;
`latestPublished` is never called. Worse than incomplete, it is dishonest in
the one direction this tool must never be: an unreadable pub.dev maps to
`notChecked`, `notChecked` is not counted as a failure, so `rk verify` prints
`✓ verified` and exits 0 having verified nothing. The `_Check` rendering and
the "what rk cannot know" idea are worth keeping. The verification is not
written yet.

**Phase 5 — `rk release`. Substantial iteration; the skeleton survives.**
validate → inspect → authorize → act is the right shape and the authorization
flow is real. Three things are wrong underneath it:

- `_inspect` handles three step kinds and answers `default: absent` for the
  other seven. So a github-release that already exists, a formula already
  moved, an archive already built are each asserted to be *definitely not
  there* without anything being asked. "Re-running is the resume" does not
  hold for any of them, and it is the cardinal rule broken by default clause.
- A prerequisite that is not published yet is classified `conflict`, which
  halts with "this cannot be fixed by re-running" — when publishing the
  dependency and re-running is precisely the fix.
- The whole binary chain runs inside the first `build` step and the other
  steps return true, carrying `_produced` between them (seam 1). The checklist
  promises ten steps and one of them does everything: the per-step verdicts in
  `--json` are fiction, a mid-chain failure is reported against the wrong
  step, and CI cannot split what one step does.

**Phase 7 — binary chain. Keep; wire and finish.** Better than expected and
mostly proven rather than asserted: SHA-256 against the published vectors and
agreeing with the system tool, `SHA256SUMS` that `shasum -c` reads, archives
demonstrated byte-reproducible and readable by real `tar`, capability
resolution that discovers rather than declares, and a formula renderer tested
against Ruby quote injection. What is outstanding is narrow: signing is not
checked against the designated requirement derived from what is already
published, and the chain needs decomposing into the steps the checklist
already names.

**The common thread.** Everything unreviewed fails the same way: a definite
negative concluded without evidence — `default: absent`, `notChecked` counted
as success, an empty asset list standing in for an unread one. The parsers and
transforms, which were reviewed, do not have this defect anywhere. That is the
argument for the review being a gate rather than a courtesy.

## What "done" means, after the phase 2 review

Two independent reviewers found the same thing, and it is worth stating as a
rule rather than as a finding. Phase 1's fix replaced "assert a source file
contains a string" with "assert a *test* file contains a string" — the same
anti-pattern displaced one level, and strictly weaker, because the matched text
was test names and comments that nothing executes. Rename a test and the phase
failed; delete the feature and it passed. A reviewer unwired five of phase 2's
headline deliverables one at a time and the gate reported done every time.

So, binding from here:

1. **No assertion in `phase_conformance_test.dart` may match the contents of a
   file under `test/`.** A phase's group runs `bin/rk.dart` and asserts on what
   comes back.
2. **The gate is the whole suite plus the phase's group.** The group answers
   "is this phase's work wired into the product"; the unit tests answer "is it
   correct". Neither alone is sufficient and pretending otherwise is what
   produced the last two rounds of findings.
3. **Every phase ends with a mutation pass.** Pick the two or three invariants
   the phase exists to protect, break each one in the production code, and
   require the suite to notice. A green suite proved nothing both times; a
   deliberate break proved something immediately.
4. **Reviews are independent.** The phase 2 self-review found five real bugs
   and missed the structural one, which is exactly the blind spot a self-review
   has.

## Obligations carried into later phases

Recorded because the reviews found them claimed-as-shipped when they are not:

- **Phase 3** — `output.unit`/`output.step` on the *online* status path.
  `rk status --json` currently answers `units: []` in normal use; only
  `--offline` records anything. Confirmed against the real keybay repository,
  not a fixture: the human sees two units and the document carries none.
- **Phase 3** — a repository-level problem is reported once per unit. Running
  against the real fleury, which declares six, produced six identical
  `RK-GIT-001` entries for one uncommitted worktree. A fact about the
  repository belongs to the repository.
- **Phase 3** — a blocked unit never says what rk did not read. `_printPlan`
  and the "not checked: github-release, homebrew" line both sit after the
  early return for problems, so a unit blocked on anything at all shows a ✗
  with no hint that two of its three channels were never consulted. The
  comment in that method says saying nothing about an unreadable channel
  "would let a half-finished release look complete" — which is what happens in
  the branch it does not cover. Also found by running against real keybay.
- **Phase 4** — conflict evidence that prints the *difference* rather than
  the fact of one. The forge reader now produces evidence and it reaches the
  report; what phase 4 adds is content diffs from the comparator. Also the
  pub.dev `first-publish` refusal, which today returns `absent` — "proceed" —
  for a package that has never existed. Also: freeze the step-id grammar in
  the RFC as a compatibility promise with frozen vectors, the way the version
  grammar is — agents key on ids, and an id that drifts breaks every caller
  silently. And reconcile RK-RES-008 with the RFC's "projects in a unit are
  not required to be identical" sentence — the code refuses divergence, the
  RFC text permits it, and fleury is where the difference will bite.
- **Phase 5** — the wedged-draft command printed for the operator to run; and
  the public result (URLs and the install command) on completion. (`.rk/`
  added to the repository's ignore rules by `rk init`: shipped in the phase 6
  closeout, named in the confirm prompt.)
- **Phase 5 residue, second review.** The resume path proves presence, not
  bytes: a re-run that finds the version published answers "already
  released" and points at `rk verify` rather than re-running the byte proof
  itself — an operator caution until an auto-confirm lands. A package with a
  `.pubignore` can never confirm `exact`, so its first release through this
  path ends "an effect may exist" and needs the pointed-at verify —
  keybay_cli has one, so phase 7's cli publish meets this. Both deliberate,
  both to revisit when release learns to re-verify on resume.
- **Phase 5 residue, ledgered by the independent review.** The RFC's
  Authorization says release "verifies the authorizing tag's signature where
  one exists"; nothing runs `git tag -v`, and unattended runs simply refuse —
  fail-closed, but the promise is unimplemented and now recorded. Same for
  the tag step's remote-verify leg (push is trusted from its exit code; a
  failed push now deletes the local tag so re-running starts clean, which
  closes the trap without the leg). The consumer-resolve probe models a Dart
  consumer on this SDK: a Flutter-constrained package or one requiring a
  newer SDK than the probe's pubspec is refused with the solver's words and
  this ledger entry named in the remedy. The diagnosis still lacks per-step
  durations.
- **Phase 7a** — done in the 7a build and hardened in its review closeout:
  `PublishedIdentity` wired (the baseline resolves in preflight, RK-SIGN-004
  when unreadable), `Activity` carried by the build and the notarization
  wait, and the workspace interface reintroduced around the binary chain —
  seam 3 where it matters. Still open from this entry: a failed step must
  stay expanded (`Output.line` clears the transient line first, collapsing
  the detail that is the diagnosis).
- **Phase 7b** — a multi-platform command-layer drive: done, in the 7b
  build (three platforms, both directions). Deleted as collateral when
  `--rehearse` was cut — it sat beside the flag test it shared a group
  with, and the commit enumerated every flag it removed without ever
  saying a DONE WHEN gate went with them. These two lines went on
  asserting it existed. Restored, and rebuilt to assert set equality
  against the derivation rather than a literal list. The lesson is in the
  review record below: a stage gated on a *count* cannot tell coverage
  that moved from coverage that was deleted.
- **Verify, owed by the unproven-platform change** — a release whose
  Linux binaries shipped unexecuted carries that fact only in the run's
  own output. `rk verify` should say it too, per platform, so a reader
  months later learns which artifacts were ever run. The natural home is
  the same pass that owes binary-channel verification.
- **Verify, owed by 7b** — the formula inspection's exactness is the
  version pointer, not bytes: the sha256 values inside a formula are
  digests of assets a pre-build inspection cannot have. The act compares
  bytes before pushing and reads the public tap back after, but proving a
  *previously released* formula byte-faithful — digests against the
  published archives, formula against what rk would render — belongs to
  `rk verify`, which runs when the assets are published facts. Until then,
  a hand-edited formula that keeps the version line reads `exact` to
  status. The same verify pass owes the release's other assets their digest
  re-proof (the RFC's flip re-verification, amended in 7b to a
  name-inventory confirm): download each published asset, prove it against
  SHA256SUMS, and SHA256SUMS against the archives.

**Phase 3 — probes and status.** Self-audit before the independent review,
prompted by the question "are we ready for phase 4". The audit found the worst
kind of finding: the phase 3 commit message claimed release shared the
Inspector — "that walk is gone" — while release.dart still ran its own
`_inspect` with the `default: absent` clause. The conformance test passed
because "any use outside inspect.dart" was satisfied by status alone. Fixed by
actually wiring it, and the gate now requires both verbs to call
`inspector.inspect(` and release.dart to not define its own. With the shared
inspector, release's halting had to learn the distinction the old code
blurred: local steps answer unknown by design (they are the work), so unknown
halts only where state was supposed to be readable, and the one absence that
blocks is a prerequisite — as beforeActing, since publishing the dependency
and re-running is the fix. Also: two `isPublic`s with different answers
renamed apart; an unused Inspector field deleted; the verdict at the Output
boundary is now the Verdict enum, so prose in that field is unrepresentable
rather than merely wrong. Mutation pass: three invariants broken on purpose;
two caught, one survived — a prerequisite that is not live reading as live
broke nothing, because FakeRegistry.lookup answered null for unreachable,
violating the real client's contract (throw, never null) and teaching callers
the exact collapse the real client refuses. The fake now throws; the mutation
now fails seven tests.

**Phase 4 — the independent reviews.** Twenty-five mutations, eight
survived — down from thirteen of twenty in phase 3 — plus two false definite
negatives proven live. The engine held ("sound to build phase 5 on"); the
verb did not, and the survivors clustered on it. Fixed in closeout: the
version-at-ref regex — a second pubspec reader that read a quoted version's
quotes as part of the version and declared a published release "not on
pub.dev" — replaced with the hardened parser; a verify conflict now lands in
`problems` with the unit named and turns `rerun_helps` off, where before the
one finding rk itself calls unfixable was reported to a machine as clean and
retryable; the honest partial fails with a mark, a problem, and no-retry
instead of reading as a note; `alwaysExcluded` replaced by pub's actual rule
(any hidden path segment, plus pubspec.lock) as a frozen predicate with
vectors, after the four-basename version accused the genuine dart-lang/args
2.5.0 release of tampering — and the closeout's own vector test then caught
the first replacement checking basenames where the args evidence shows
segments; a symlink in an archive is a conflict rather than invisible;
verifications are keyed by the frozen step id; a mixed-channel unit names
the channels it did not examine on both surfaces as a disclosure that fails
nothing; --at across several units, an empty --at, and a silently-dropped
third argument are usage refusals; and the fake registry's archive method —
the fourth contract divergence in the same fake — now refuses a missing URL
and can serve tampering, so the whole RK-VER-004 path is executed by tests.
The conformance group's one test/-file grep (the doctrine's own first rule,
broken in the first phase gated under it) now reads the engine, and the
RFC's import-graph promise is a real test.

**Phase 3 — the independent reviews.** Two reviewers, mutation-first and
spec-fidelity, both against b5f4b97. Twenty mutations: thirteen survived,
clustering exactly where the self-audit had just changed the code — every
halting rule in release, the whole forge-reader inspect arm, the moot
machinery in both directions, and status's blocked-readiness rules. The
ranked findings, all since fixed:

- The registry cache made release's post-publish verification structurally
  unable to succeed: the confirming read answered from the memo the pre-act
  inspection wrote, so every genuinely successful publish would have reported
  failure — one commit before the first real publish depended on it. The
  client forgets a package after rk acts on it, and the fake now memoizes
  like the real one, because a double without the cache cannot reproduce the
  bug.
- Monotonicity was enforced only by status, the verb that does not act;
  release would have run `dart pub publish --force` on a back-version — the
  tool's #1 ranked failure. It moved into the Inspector and both verbs call
  it.
- A halted release was prose-only under `--json`; the checklist with verdicts
  is now recorded before anything is decided, so a halt is data whatever
  happens next.
- status recommended the command release refuses (absent prerequisite), and
  concluded "not published" from a socket error in its headline while every
  step line below it was honest. Both verbs now share one blocking
  classification, and the summary says "could not be read" or says nothing.
- Forge `exact` meant subset: the real keybay release carries ten assets, rk
  checked its expected four and said published. Exact means equal now, extras
  named in evidence.
- `--offline` was accepted and ignored by release — a live read under a flag
  promising none, in the file whose own comment calls that worse than an
  error. Flags are per-verb now.
- Two hazards no single step could see, found by asking where the tag
  points (which nothing read before): a fully published version with no tag
  must not be tagged after the fact at whatever HEAD happens to be, and a tag
  at another commit with registry work remaining would publish HEAD's content
  under a name that points elsewhere. Both are guards now, shared by both
  verbs, refusing with the exact command for the operator to run.
- `IdentityReading`'s "nothing published" and "could not read" were
  distinguishable only by prose — the class whose docstring forbids exactly
  that collapse. It is an enum now.

The survivors became tests: the forge reader's whole arm, the blocking
classification tables (frozen like the version vectors), the moot fold in
both directions, isClean's false direction, and the cache-forget contract.
The phase 7 signing gate was green before its deliverable existed — the
displaced-string anti-pattern again, an unwired file proving another file is
used — and is now red until the wiring lands, which is what a gate is for.

**The output review — three developer personas, three rounds.** After the
operator called the status output messy, three persona reviewers (a
package maintainer, a release engineer, a first-time user) reviewed real
transcripts of all four verbs, three rounds, fixes between each. Round 1
landed the convergent findings: init's refusal was the only one in the
tool without a door (--write is the flag-shaped yes now); diagnostic codes
ride every ✗ line in every mode; offline --json silently dropped
repository problems (a real parity bug, found from the outside);
'permanent' stopped parsing as 'permanently not published'; roadmap-speak
and forge/tap jargon left the output; -h grew flags, exit codes, a mark
legend, and a definition of 'unit'. Round 2's meta-finding, named by all
three independently: the review pack's changelog claimed fixes its
transcripts did not demonstrate — fixtures had drifted. Round 3 fixed the
remainder (the verify tally counts the failure it omitted, failures
first; inline arrows became › so the gutter's → means only 'your next
move'; exit 3 = rk itself crashed; found/expected counts on the asset
conflict; the authorize screen marks the permanence boundary) and
regenerated everything on frozen fixtures, adding the two screens no
round had shown: the happy path and the confirmation moment.

Ledgered from the reviews, deliberately not squeezed into the polish:
- Per-step `cause` on unknown verdicts pointing at an existing problem
  code (design agreed with the release-engineer persona; needs Inspection
  to carry it through every inspect arm — landing it half-wired would be
  the claims-outrun-evidence pattern again).
- The release record: an NDJSON step-event stream during `rk release`
  and a final digested record (HEAD, digests, notary ids, URLs, timings)
  that `rk verify` re-proves — the org-rollout capability.
- Tag excavation: when the tag is missing, walk candidate commits and
  byte-compare against the published archive, printing the proven commit
  instead of a placeholder — verify's machinery, pointed at the operator's
  scariest chore.
- A one-line gloss for sign/notarize where --dry-run mentions them.

Sign-offs, round 3: the first-timer — "no warning label"; the maintainer —
"ship, and stop polishing"; the release engineer — status and verify
org-wide via --json, blocker cleared by doc/json.md (the schema, the
verdict enum, and the blessed gate rule: problems[] empty, no conflict
verdicts, unknown never auto-proceeds, offline gates nothing). Their final
catches landed: status no longer recommends the command release refuses on
a never-published package (the next move is the manual dart pub publish);
drift is recorded as RK-DRIFT-001 in problems[] as well as on its step and
tagged on the ✗ row; the last inline → became ›; the authorize decline and
init's --write door say their whole truth.

**Phase 7b — the independent review.** Twenty mutations, ten survived —
the same signature a third time: the paths all behave as documented when
driven (the reviewer probed every one), and the new safety mechanisms were
the unpinned ones. The high finding was better than a survivor: **the
first real keybay cli release would have halted mid-release** — after the
tag and the pub.dev publish were public — because rk signed with the
project-name identifier while the published 0.1.0 binary carries
`io.github.danreynolds.keybay.cli` (read live from the real release), and
the RK-SIGN-003 halt would then have said "rk did not act", with a remedy
whose claim ("declare [identity] anew to remove the baseline") no code
implements. Fixed in closeout, by the doctrine the team id already
follows: **the identifier is derived from the published requirement**
(declared `[identity]` only fills what no release states), a declaration
that *contradicts* the published identity is refused before anything acts
(RK-SIGN-005, both values named), the RK-SIGN-003 remedy lost its false
claim, and the sign-mismatch halt is acted-aware. The release body is now
read in preflight too — the last refusable input, resolved before the
first act, validated but not written under --dry-run — and an empty
changelog entry refuses (RK-CHG-004) instead of publishing a body nobody
wrote. The ten survivors are tests: `Changelog.entry` in both closing
directions (stop at the next version heading; subsections stay inside)
plus the bare-heading and decorated-heading vectors; the formula
inspection's four arms, including exact-only-at-this-version; the draft
sweep by id across slurped pages with a published release and another
tag's draft both surviving; the terminal read-back (published short of its
assets, with the permanent sentence) and the lostTrack read-back; the tap
read-back in all three directions (proven, mismatched, unreadable);
RK-NOTARY-003 (an accepted submission whose log cannot be fetched fails
the step); and same-length-different-bytes is still a change. A push that
fails for any reason other than a rejection no longer blames "the tap
moved" (F8). Spec drift was reconciled in the RFC itself, marked *Amended
(7b, as built)*: sweep-and-recreate instead of adopt (adoption stays
deferred to CI), name-inventory confirm with per-asset digest re-proof
ledgered to verify beside the formula byte-proof, and contents-API reads
in place of git fetch.

**Phase 7b — the destinations, built.** The forge is read through `gh api`
status codes end to end: existence keys on `(HTTP 404)` — with the
404-means-private discipline kept, since GitHub deliberately 404s a
repository the token cannot see — instead of prose gh rewords between
versions; drafts are swept with `--paginate --slurp`, killing the silent
`--limit 100` cap; deletion is by release id, which several same-tag drafts
made ambiguous by tag. The release body is the changelog entry, extracted
through the same heading parse that validated its presence — one source of
release prose, where `--generate-notes` shipped a commit-log digest that
could disagree with the CHANGELOG. The asset set grew to the real keybay
0.1.0 ten-asset shape and `gatherAssets` and `expectedAssets` mirror it:
archives per platform, `.notary-result.json` and `.notary-log.json` per
macOS platform (the notarize step now publishes Apple's verdict and its
log, and its skip requires the evidence files, not just Apple's word), the
formula riding with the release so it is self-describing, and the
checksums. The formula step got a real inspection — the tap read publicly
via `gh api contents`, 404-disciplined, exact meaning "points at this
version" — where the stub answered `unknown` and, once homebrew was
actually driven, blocked every release carrying it. And `HomebrewTap` held
two bugs the 7a review never reached because nothing drove it: the formula
was written with `cat` and no stdin — the `contents` parameter was never
used, so what it committed was empty — and `git commit -a` never stages a
new file, so a first-ever formula read as "already current" and pushed
nothing. It writes for real now, stages by name, decides unchanged by
bytes, compare-and-swaps against a fresh clone, and reads the formula back
from the public tap byte-for-byte after pushing (RK-BREW-001/002/003). A
three-platform drive — native macOS plus two cross-compiled linux targets
under injected capabilities — proves the whole shape at the command layer,
in both directions: the full release (seven assets, ordering, notes,
read-back) and the dry run that runs every local step and touches nothing
public. The published set is asserted as *set equality against
`Inspector.expectedAssets`* rather than against a literal list, so the
producer is pinned to the party it has to agree with rather than to a
spelling. The DONE-WHEN live gate is deliberately red until the real
keybay cli release is recorded as "## Phase 7b checkpoint".

**Phase 7a — the independent review.** Fifteen mutations, nine survived —
and the split was the finding: all seven mutations in 7a's two *new* safety
mechanisms survived, while everything they plug into (the frozen inspect
tables, the rehearse predicate, notarize reuse, naming) caught its
mutations. The structure was judged sound to build 7b on; the content of
the new mechanisms was not, and both highs were confirmed against live
codesign behaviour. Fixed in closeout:

- Build reuse was by acceptability, not identity: the gate was `exists` +
  `codesign -d -r-` + a version string, and `-d -r-` is a *display* command
  — it prints the requirement, exit 0, for a binary modified after signing.
  A foreign binary seeded into `.rk/work/` (invisible to git status, which
  ignores `.rk/`) walked out signed, notarized, and published. The gate is
  now three external legs, all mandatory: `codesign --verify --strict`
  (the bytes match the signature), designated-requirement equality against
  the identity users already installed (a Developer ID requirement carries
  no content hash, so equality proves who signed and leg one proves the
  bytes are theirs), and the version. No published baseline means nothing
  vouches, so a first release always rebuilds. All four directions are
  pinned by execution.
- The team parser required quotes; codesign only quotes an OU that needs
  quoting, so every letter-leading team id (`= Q6L2SF6YDW`, unquoted —
  confirmed live) derived no team, and the one repository this was tried
  on, keybay, has the digit-leading team that happens to work. Both forms
  parse now, with a decoy-quoted-token vector pinning the anchor and an
  extends-the-published-requirement vector pinning equality-not-prefix.
- `_signingBaseline` (né `_publishedRequirement`) had no test at all and
  resolved *inside the sign step*, so an unreadable published identity
  surfaced as RK-INT-001 — "a bug in rk" — after the tag was public. It
  resolves in preflight now, before anything acts and inside `--dry-run`,
  refusing as RK-SIGN-004 with the baseline tag named; the
  newest-lower-version selection is pinned by which tag the identity read
  downloads.
- Most chain failures exited 1 with no halt sentence and no `halt` key; a
  formula failure recorded no problem at all. Every act-loop failure now
  halts — with a fifth sentence, `stoppedPartway` ("everything already done
  is real and stays done; re-running resumes after it"), because a chain
  failure after a pushed tag makes both "nothing changed" and "lost sight
  of the result" false — and specific halts recorded where they were
  diagnosed win over the default. The formula path records RK-BREW-001.
- `--dry-run --rehearse` silently ran as a dry run — both flags
  individually valid, so the pair passed the per-verb check, and the class
  the CLI's own comment forbids recurred. It is RK-CLI-008 now: two
  different promises, refused together.
- The two workspaces disagreed about a file a native tool wrote at
  `pathOf` before any ingest — which made the reuse branch unreachable
  under MemoryWorkspace, and was the mechanical reason every reuse
  mutation survived. They are interchangeable now, under a contract test
  that runs every assertion against both, including the `..` escape guard
  MemoryWorkspace lacked.

Ledgered to 7b, whose done-when already demands it: a multi-platform drive
(the reviewer ran one by hand: the product is correct — checksums covers
both platforms and the ordering holds — the gap is coverage, not
behaviour).

**Phase 6 — the independent review.** Thirteen mutations, six survived, and
a "not yet" verdict on the one mutating verb outside release. The high
finding was real and unattended: `rk init < /dev/null` wrote the file — EOF
read as null, null collapsed to the empty string, and empty means Yes, while
macOS reports a terminal for `/dev/null`, so `hasTerminal` never guarded it.
The parse is now `InitCommand.consented`, where EOF declines; its vectors
are pinned (a harness cannot fake a terminal at EOF, which is itself why the
inline closure was untestable), and a gate holds the entry point to routing
its answer through it. The rest, all since fixed: init's three exit-0 states
encoded byte-identical empty documents, so already-configured,
nothing-releasable, and awaiting-a-human are each data now (RK-INIT-002/003,
the attachment), distinguishable by the fleet-sweeping caller init exists
for; init bypassed the reading rules every other verb goes through, so an
unreadable `release.toml` crashed as "a bug in rk" claiming an effect may
exist — it is RK-CONF-034 now, the crash sentence keys on the report's own
`acted` flag rather than the verb, and a tracked-but-deleted manifest is
named instead of skipped in silence; an untracked manifest is named with its
`git add`, never proposed from; RK-INIT-001 turns `rerun_helps` off (the
same manifests derive the same refusal) and attaches the refused proposal so
its problems' line references have a referent, under a name
(`release.toml.refused`) a caller cannot mistake for the accepted one;
`rk init somepkg` is a usage refusal instead of a silently unscoped write;
`trackedFiles` on a repository git cannot list throws instead of answering
"tracks nothing" (RK-GIT-006 in init; the same lie is now impossible under
the comparator); and the `.rk/` ignore-rule obligation from the phase 5
ledger shipped — written with the config, named in the prompt, idempotent.
The six survivors are tests now: the consent vectors, the refusal document's
contents, the executable comment's presence and absence, the sanitization
rules, and — against real repositories, which the memory tree cannot model —
the untracked and tracked-but-deleted cases.

## Phase 4 checkpoint — real keybay, live pub.dev, 2026-07-30

The done-when, run against the real repository (read-only throughout):

```
$ rk verify
  core             0.1.0 → keybay-v0.1.0
✗   the ref keybay-v0.1.0 does not exist, so there is no source to prove
    the published version against
      nothing binds the published version to a commit — no tag records it.
      If it was released under an older tag scheme, name that tag:
      rk verify core --at=<ref>

  cli              0.1.0 → keybay_cli-v0.1.0
✓   keybay_cli 0.1.0    82 files, byte-identical against keybay_cli-v0.1.0
                        · published 2026-07-18
exit 1

$ rk verify core --at=v0.1.0
  core             0.1.0 → v0.1.0
✓   keybay 0.1.0        40 files, byte-identical against v0.1.0
                        · published 2026-07-18
exit 0
```

Both published packages proved byte-for-byte against the tags that released
them, from the archives pub.dev actually serves, each download verified
against the digest the registry states. core's default-tag refusal is
correct: the release predates today's derived scheme, no keybay-v0.1.0
exists, and minting or guessing would be the provenance lie verify exists to
catch — `--at=v0.1.0` is the honest path and it proves out.

The run also settled a fact by evidence rather than memory: pub excludes
`.gitignore`, `pubspec.lock`, `.metadata` and `.pubignore` by basename at
any depth — the keybay_cli tag tracks all four shapes and its archive
carries none of them. `Comparator.alwaysExcluded` encodes exactly that,
with the confirming archive named in the comment; the first run reported
those six files as honestly unjudgeable, and the refined rule turned the
verdict into the full byte-identical pass above.

Mutation pass: a differing file reading as identical, tampered bytes handed
over anyway, the ref tree quietly reading HEAD, and direction two silently
dropped — every one caught.

## Phase 5 — built, awaiting the live checkpoint

Everything but the permanent act is in and proven at the command layer with
an evolving world — the acts change the same fake registry and tag set the
next inspection reads, and a fresh drive is a fresh process (the world
persists; the per-process cache does not — a cache that survived "restarts"
hid a double publish in the gate's own first draft):

- The consumer resolve gates the permanent act: resolution with development
  overrides disabled, in a scratch consumer that depends on the package the
  way everyone else will. A failing resolve blocks the publish.
- The confirming read polls the invalidated cache to a bounded deadline
  (60s, every 5s); a version the registry never lists ends in lostTrack —
  "an effect may exist" — not in a spin and not in a success claim.
- The version existing is not the right bytes existing: the post-publish
  check downloads what the registry now serves and proves it byte-for-byte
  against this tree through the same comparator verify wears. A mismatch is
  RK-REL-002 — terminal, evidence named, rerun_helps off.
- Killed after the tag, a re-run finishes without re-tagging. Killed after
  the publish, a re-run confirms without publishing twice. Both proven by
  execution in the phase gate.

The one red gate is the forcing function: "DONE WHEN, live half" stays red
until the real keybay publish is recorded here as the Phase 5 checkpoint.
That act is the operator's — permanent, outward-facing, and requiring their
terminal for the typed confirmation. The path to it, in order:

0. Both phase 5 reviews are addressed; the remaining red gate is this
   checkpoint. Operator cautions from the mutation review, still true:
   after any run ending "an effect may exist", run `rk verify` rather than
   trusting a re-run's "already released".
1. In keybay: commit `release.toml` (it is untracked, which also defeats
   "anyone with a fresh clone can verify" for keybay itself).
2. Retro-tag the released 0.1.0 at the commit that produced it, as rk
   instructs: `git tag keybay-v0.1.0 <that commit> && git push origin
   keybay-v0.1.0` — RK-GIT-004 names it. v0.1.0 exists at the right commit
   already, so: `git tag keybay-v0.1.0 v0.1.0^{} && git push origin
   keybay-v0.1.0`. Same for keybay_cli if desired (keybay_cli-v0.1.0
   already exists).
3. Bump packages/keybay to 0.1.1 (or the intended next), add the CHANGELOG
   entry — and in the same commit, move keybay_cli's exact pin to the new
   version. The repository is a pub workspace: bumped alone, the workspace no
   longer solves, and the preflight refuses with pub's solver message. One
   commit, both files, no trap.
4. `rk status` — expect core ready with `→ rk release core`.
5. `rk release core`, type the version at the prompt.
6. Paste the transcript here as "## Phase 5 checkpoint", which turns the
   gate green.
7. Then the cli, for the phase 7b checkpoint: bump packages/keybay_cli
   (with its CHANGELOG entry — the entry becomes the release body), run
   `rk status`, then `rk release cli --dry-run` (every local step, signing
   and notarization included, nothing public), then `rk release cli`. No
   `[identity]` is needed: rk derives the team and the code identifier from
   the published 0.1.0 binary, and a declaration that contradicted it would
   be refused before the tag (RK-SIGN-005). After the run: `brew install`
   from the public tap on a machine that has never seen this repo is the
   install check. Paste the transcript as "## Phase 7b checkpoint".

**Phase 7a — the local chain, built.** The monolith dissolved: `produce()`
ran the whole chain inside the first build step and handed `_produced` to
the steps after it, making the checklist's ten steps a fiction. Each step is
now its own act over the workspace interface — read by name, do one thing,
write by name — and the gate proves it by driving a full binary release at
the command layer with a fresh chain instance per step: build, sign,
notarize, archive, checksums, publish, each acting separately and in order.
Reuse follows identity, not existence: only a signed binary codesign
re-verifies at the right version and a zip Apple already notarized are
reused; everything else rebuilds. Signing derives its requirement from the
release users already installed — `PublishedIdentity`, wired at last, with
the team read out of the published requirement itself — and a signature that
does not reproduce it is refused with both requirements as evidence, before
anything public exists. `Activity` finally has its production callers: the
build and the notarization wait. And `--rehearse` is real: every local step
runs for real, nothing public is touched, nothing is authorized because
nothing permanent happens — proved by a gate that counts the tool calls both
ways.
