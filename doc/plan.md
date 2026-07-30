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

## Phase 4 — `rk verify`

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

**Done when:** keybay core publishes to pub.dev via rk.

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

## Phase 7 — Binary chain

- `dart-cli` build with per-platform capability resolution (native,
  cross-compiled, emulated smoke test, blocked).
- `macos-sign` and `macos-notarize`.
- Deterministic `archive` and `checksums`.
- `github-release`: draft create/adopt/recreate, upload, flip, verify.
- `homebrew-tap`: formula render, compare-and-swap, public install check.

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
  `--offline` records anything.
- **Phase 4** — conflict evidence that prints the difference rather than the
  fact of one. Nothing produces a diff yet. Also the pub.dev `first-publish`
  refusal, which today returns `absent` — "proceed" — for a package that has
  never existed.
- **Phase 5** — the wedged-draft command printed for the operator to run; the
  public result (URLs and the install command) on completion; and `.rk/` added
  to the repository's ignore rules by `rk init`.
- **Phase 7** — wire `Activity` into the binary chain. It is built and tested
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
