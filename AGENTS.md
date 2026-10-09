# Working on rk

rk releases an operator's own code from their own machine: Dart packages,
command-line apps and the assets their builds make, to pub.dev, Git tags,
GitHub Releases and Homebrew. The [README](README.md) says what rk does.
Design records in [`doc/archive/`](doc/archive/) explain how rk got here;
they do not decide anything.

## What rk is for

rk makes releasing code simple. A repository says what it releases and where
each piece goes; rk turns that into one plan for the whole repository and
carries it out with one command. Packages that depend on each other are
released in the order they need, and `rk use` switches a command you release
between this checkout's build and a published one.

Three commitments shape every change. Each has an example, and a test that
fails if the example stops being true.

- **Fast.** rk does independent work at once, and nothing twice. Staging
  Fleury's four packages reads all their destinations at once and builds all
  four at the same time, from one read of the commit: a fresh stage takes
  about 9s, roughly what its largest package takes alone, and running it
  again reuses all four in about half a second. A run asks origin for its
  tags once, however many it checks, so releasing those four packages and
  their two tags takes three trips to origin.
  Kept by `reads every unit's destinations at once`,
  `stages its units side by side` and `a repository release reads origin's
  tags once and pushes each tag once` in `test/release_test.dart`.
- **Reliable.** A release can stop anywhere, and running it again finishes it
  without publishing anything twice. When pub.dev accepts an upload but
  `dart pub publish` loses the response, rk reads pub.dev back, finds the
  version, and records it published: one upload, and the release carries on.
  Kept by `accepted upload with lost response reconciles without duplicate
  publication` in `test/native_publication_test.dart`, which runs the real
  `dart pub` against a local pub.dev, and the `resume half` tests in
  `test/end_to_end_test.dart`.
- **Intuitive by default.** The plain command does what you would expect.
  `rk release` with no arguments releases everything that is not yet
  released, in the order the packages depend on each other, building what is
  not built and asking once: there is no order to list, no resume flag and no
  cleanup step.
  Kept by `shows the whole run, and asks once for all of it` in
  `test/release_test.dart`.

## How rk works

A release is one loop over the repository's units:

1. **Look.** Read every destination once. Each target is published, absent,
   conflicting or unreadable: absent is work, published is done, and the
   other two stop the release with their reason.
2. **Build what is missing.** Stage the units side by side, each from its
   commit. A package that needs a sibling not yet on pub.dev builds against
   that sibling's source from the same commit. A stage is named by what it is
   built from (commit, tree, configuration, origin) and holds what will be
   published.
3. **Ask once.** Show every unit's remaining targets in release order. The
   yes covers exactly those.
4. **Publish in order.** Providers go before the packages that need them.
   Each target is published only if it is still absent, and rk confirms
   what happened: a registry is read again just before an upload and read
   back after it, and a tag push is confirmed by git, which refuses to
   replace a tag origin already has. When an act fails, rk reads the target
   before saying what happened.

The principles behind the loop:

- **A release is of a commit.** `rk stage` and `rk release` refuse
  uncommitted changes. `rk status` and `rk plan` read the working tree, and
  say what needs committing.
- **Re-running is the recovery.** A re-run skips what is published, resumes
  an interrupted stage from its recorded outputs, and finishes a half-done
  release. The stage is the only state one run leaves for the next.
- **A stage is kept while public bytes must match it**: built assets partly
  published on a GitHub release or in a formula. Everything else stages again
  from its commit.
- **Native tools do native work.** Pub resolves, validates and packages; git
  tags and signs as its config says; `gh` and the tap publish. rk sequences
  them and confirms the result, trusting a native answer where it is
  definite.
- **Trust the cheap, verify the published.** rk trusts Pub, Git, the
  registries and its own writes within a run. It hashes what will be published
  when it is produced, checks it before upload, and reads it back after. It is
  built for an operator releasing their own code on their own machine,
  through crashed runs, re-runs and half-finished releases.
- **Refuse before acting, and name the fix.** Validation, readiness and
  conflicts found in the snapshot stop the run before any public act, with a
  code and a remedy. Once publishing, a failure starts no new work, and every
  act already started is confirmed before rk stops.
- **New work fits the loop.** A target reads its destination, prepares what
  it needs staged, publishes and confirms; core decides when, and what a
  failure means. A check belongs where rk reads reality: in the snapshot, or
  in the read before an act.

## Changing rk

- **Every mechanism earns its place.** Before adding a check, a cache, a
  proof or a new kind of state, name the realistic failure it prevents for
  someone releasing their own code, and what it costs: time on every
  release, code to maintain, tests that pin it. Add it when the benefit
  clearly outweighs the cost.
- **Weigh review findings, so complexity does not ratchet up.** A finding is
  a question. Realistic and costly when it happens: fix it, as simply as it
  can be fixed. Rare or theoretical: note it, and build nothing for it. Each
  added check also adds a test that pins it, and both outlive the reason they
  were added; removing machinery that does not pay for itself is worth as
  much as a feature.
- **Use the tool's own behaviour** rather than a model of it in rk.
- **Measure.** `rk stage --timings` and `rk release --timings` say where a
  run's time went, and `RK_TIMINGS=1` traces rk's own work: subprocesses,
  hashing and parsing. Measure before and after a change to a release path.
  Work that grows with the size of the repository or its dependency graph
  needs a reason worth that cost.

## Before a pull request

```sh
dart format --output=none --set-exit-if-changed .  # what CI runs
dart analyze
dart test --exclude-tags publication -j 6          # about a minute
dart test --tags publication --concurrency=1       # loopback pub.dev, about a minute
```

Tests that run rk as a process share one compiled binary
(`test/support/compiled_rk.dart`), rebuilt when rk's sources change.

Add an entry under `## Unreleased` in `CHANGELOG.md` for anything a user
would notice.
