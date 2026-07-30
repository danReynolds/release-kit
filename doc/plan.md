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
