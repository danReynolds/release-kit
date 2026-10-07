# Practical staging

Status: accepted, being implemented. Supersedes the dependency-staging design
in [`archive/dependency-staging-plan.md`](archive/dependency-staging-plan.md).

## Why

A fresh `rk stage` of Fleury's four packages took 2m 9s; reusing their saved
stages took about 30s. Profiling showed where the time went. Almost none of
it was building or packaging:

- **39s resolving dependencies.** rk ran its own resolution through a local
  placeholder registry, then downloaded every hosted dependency's archive
  from pub.dev one at a time, separately for each unit: 54 archives per unit,
  217 downloads, nearly all the same ones. `pub get` itself took 2.6s.
- **25s hashing 2.7 GB** to produce four 60 MB stages:
  - every stage held a full copy of the repository (website, docs and all);
  - every step re-verified everything rk had just written;
  - every file inside every dependency archive was hashed for each unit.
- **9s listing** stage directories, 283 times, to notice changes.

That came from a design that set out to prove every byte, of every input and
every intermediate, at every step. It also rejected public truth that was
plainly true: a re-packed archive whose tar timestamps differ from the one
already on pub.dev refused the release.

## Principles

Complexity has to be justified by a release going wrong without it.

1. **Verify what gets published.**
   - Package archives, binaries, assets, the Homebrew formula and the release
     manifest are hashed once, when produced, and recorded in the receipt.
   - Each is checked against that record once more, right before upload.
   - Published artifacts are read back afterwards, as now.
2. **Trust Pub and Git for inputs.**
   - Pub resolves dependencies, through its normal cache and with its own
     lockfile hashes.
   - Git content-addresses the source: a stage is of a commit, and the commit
     id names its bytes.
3. **Trust rk's own writes within a run.** rk holds the stage-store lock, so
   nothing else writes a stage while rk runs. A step does not re-verify what
   the step before it wrote.
4. **A version is the registry's truth.**
   - If pub.dev has `fleury 0.1.2`, that target is published.
   - rk does not compare archive bytes with what is already public.
5. **Verify a saved stage once, when a later run picks it up**, by checking
   the recorded hashes of what it will publish.

## Dependencies

- A package is staged in a scratch export of its commit, never in the
  working tree.
- Pub resolves it there once, as its consumers will: as a root of its own,
  with no lockfile, through the normal pub cache. rk's own
  `pubspec_overrides.yaml` replaces any tracked override and takes a
  workspace member out of its workspace.
- A sibling goes in through a path override to its source in the same
  export when it cannot come from pub.dev yet:
  - one the package needs at runtime, directly or through other such
    siblings, whose version satisfies the requirement and is not published;
  - one only the package's development needs, which consumers never resolve.

  This applies whether the sibling is in the same unit or another. Every
  other dependency, a published sibling included, comes from pub.dev like any
  other, even when this source has unreleased changes at that version.
- The pub archive is built from that export with
  `dart pub publish --to-archive`, and binaries with `dart compile`, using the
  Dart rk identified for the stage.
- Pub leaves overrides files out of archives, so the override never changes
  what is published. Pub's validation warning about overridden dependencies is
  expected, and rk says why.
- Publication order comes from the source dependency plan: providers before
  consumers. A consumer's upload waits until each sibling it pins is public.

The following are removed:

- the placeholder registry;
- rk's own archive downloads and their offline replay;
- frozen dependency choices and their lookup, restoration and authorization;
- portable proofs;
- imported and external stage inputs;
- the pre-upload public-consumer probe (`RK-PUB-018`);
- the earlier resolution of the whole workspace before the consumer one,
  with its override checks (`RK-PUB-008`, `RK-PUB-016`). Since Pub validates
  in the consumer resolution, a tracked override cannot reach what is
  published.

A later run resolves again with Pub. That is what any `pub get` does, and the
lockfile and Pub's hashes keep it honest.

## The stage

- A stage holds what will be published, plus its receipt:
  - `producers/**`;
  - `release-notes.md`;
  - `release-manifest.json`;
  - `stage.json`.
- It no longer holds a copy of the repository or of any dependency.
- The stage id is computed from the commit, its tree, the unit's plan and the
  toolchain. rk finds a stage by its id, with no scan of saved receipts.
- Builds run in their own scratch export of the commit, outside the
  repository. Producers that run at the same time do not share one.
- What makes a saved stage reusable:
  - its receipt is complete and names this id and plan;
  - every published output still has its recorded size and hash.

## Recovery

- A partial release resumes by publishing what is not public yet.
- **A stage must be kept only for bytes that must match what is already
  public:**
  - built assets on a GitHub release;
  - a formula that names their hashes;
  - a manifest whose hash a tag annotation records.

  `RK-STAGE-005` keeps exactly that case.
- **A pub package needs no saved stage to recover.**
  - If its version is on pub.dev, it is done.
  - If not, rk stages it again from the commit and publishes it.
- The tag guards are unchanged:
  - a tag on another commit;
  - a release with everything published but no tag;
  - a tag rk cannot read.

## Not changed

- Targets, consent, drift checks before acting, read-back after publishing,
  the stage-store lock, and the progress boards.
- `rk plan`, which was always source-only.

## Delivery

1. **Dependencies through Pub.**
   - Path overrides in a scratch export, in one Pub resolution per package.
   - Source-ordered publication.
   - The dependency-staging machinery and the workspace pre-resolution
     deleted: about 10,000 lines of code and 21 test files that covered only
     them.
2. **Registry truth.**
   - A version on pub.dev is published; no archive comparison before acting.
   - The narrowed recovery rule.
3. **The stage model.**
   - Output-only stages and direct stage ids.
   - Verification of published outputs only.

Stages saved by rk 0.1.14 are not read by the new rk. A partly published
release staged with 0.1.14 finishes with 0.1.14, as schema-12 stages already
did.
