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
destination is touched — and it ends with `--rehearse`: every local step and
every inspection, stopping before any public act. The failure rehearsal
prevents is discovering the expired certificate or broken notarization at
minute 40 of an announced release.

- Decompose the chain into the checklist's steps (no `_produced` carried
  between them; the workspace interface returns here, around the thing that
  needs it).
- Wire `Activity` into the notarization wait — built, tested, and hand-rolled
  around today.
- `dart-cli` build with per-platform capability resolution (native,
  cross-compiled, emulated smoke test, blocked).
- `macos-sign` and `macos-notarize`, with the signature compared against the
  requirement `PublishedIdentity` derives from the release users already
  installed (its gate is red until this wiring lands).
- Deterministic `archive` and `checksums`.

## Phase 7b — the destinations

- `github-release`: draft create/adopt/recreate, upload, flip, verify —
  reading the forge through `gh api` status codes, not porcelain message
  strings ("release not found" means three different things).
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
- **Phase 5** — the wedged-draft command printed for the operator to run; the
  public result (URLs and the install command) on completion; and `.rk/` added
  to the repository's ignore rules by `rk init`.
- **Phase 7a** — `PublishedIdentity` is built and proven but wired to
  nothing, and the binary chain requires a declared `[identity]` instead of
  deriving one — the opposite of "identity facts are derived, not declared".
  Its conformance gate is red until the wiring lands.
- **Phase 7a** — wire `Activity` into the binary chain. It is built and tested
  but has no production caller, while `binary_chain.dart` hand-rolls a worse
  version for the notarization wait: one static line for a five-minute wait,
  no spinner, no elapsed time, no "longer than usual". That is precisely the
  failure `Activity` exists to prevent, live in the product. Also reintroduce
  a workspace abstraction *there* — the interface was deleted in phase 2
  because it abstracted a two-file diagnosis writer while the component that
  actually produces artifacts took a `String` path, which is seam 3 honoured
  where it does not matter and violated where it does. Also: a failed step
  must stay expanded; today `Output.line` clears the transient line first, so
  a failure collapses the detail that is the diagnosis.

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

1. In keybay: commit `release.toml` (it is untracked, which also defeats
   "anyone with a fresh clone can verify" for keybay itself).
2. Retro-tag the released 0.1.0 at the commit that produced it, as rk
   instructs: `git tag keybay-v0.1.0 <that commit> && git push origin
   keybay-v0.1.0` — RK-GIT-004 names it. v0.1.0 exists at the right commit
   already, so: `git tag keybay-v0.1.0 v0.1.0^{} && git push origin
   keybay-v0.1.0`. Same for keybay_cli if desired (keybay_cli-v0.1.0
   already exists).
3. Bump packages/keybay to 0.1.1 (or the intended next), add the CHANGELOG
   entry, commit, push.
4. `rk status` — expect core ready with `→ rk release core`.
5. `rk release core`, type the version at the prompt.
6. Paste the transcript here as "## Phase 5 checkpoint", which turns the
   gate green.
