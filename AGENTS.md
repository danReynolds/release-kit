# Working on rk

rk releases an operator's own code from their own machine. It covers Dart
packages and command-line apps, released to pub.dev, GitHub Releases and
Homebrew, with Git tags. The [README](README.md) says what rk does. Design
records in [`doc/archive/`](doc/archive/) explain how rk got here; they do
not decide anything.

## Justified complexity

rk has already paid for treating every input as hostile. Staging four
packages took over two minutes, mostly spent:

- downloading dependencies Pub already had;
- hashing gigabytes to prove nothing had changed.

Don't rebuild that.

- **Every mechanism has to earn its place.** Before adding a check, a cache,
  a proof or a new kind of state, name two things:
  - the realistic failure it prevents for someone releasing their own code;
  - what it costs: time on every release, code to maintain, tests that pin it.

  Add it when the benefit clearly outweighs the cost. "A guarantee could in
  principle be violated" is not enough.
- **Don't ratchet.** A review finding is a question, not an instruction.
  Weigh each one:
  - realistic, and costly when it happens: fix it, as simply as it can be
    fixed;
  - rare or theoretical: note it, and build nothing for it.

  Each added check also adds a test that pins it, and both outlive the
  reason they were added. Deleting machinery that does not pay for itself is
  worth as much as a feature; say so when you find some.
- **Prefer the simplest mechanism that works.** Use a tool's own behaviour
  rather than a parallel model of it.

## What rk trusts

- **Pub, Git and the registries.**
  - Pub resolves dependencies through its normal cache and checks archive
    hashes against the lockfile.
  - Git names a commit's bytes.
  - A version on pub.dev is published.
- **Its own writes within a run.** rk holds the stage-store lock while it
  runs. A step does not re-verify what the step before it wrote.

rk does verify what it publishes:

- Artifacts are hashed when produced, checked against that hash before
  upload, and read back afterwards.
- A saved stage is checked once, when a later run picks it up.

The threat model is someone releasing their own code on their own machine.
It covers a crashed run, a re-run, a half-finished release and a checkout
that changed underneath. It does not cover a compromised machine, a hostile
mirror, or something editing `.rk/` while rk runs.

## Performance

A release that takes minutes for no visible reason looks broken.

- `rk stage --timings` and `rk release --timings` say where a run's time
  went.
- `RK_TIMINGS=1` traces rk's own work: subprocesses, hashing and parsing.

Measure before and after any change to a release path. Don't add work that
grows with the size of the repository or its dependency graph unless the
reason is worth that cost.

## Before a pull request

```sh
dart format --output=none --set-exit-if-changed .  # what CI runs
dart analyze
dart test --exclude-tags publication -j 6          # about a minute
dart test --tags publication --concurrency=1       # loopback pub.dev, about 4
```

Tests that run rk as a process share one compiled binary
(`test/support/compiled_rk.dart`), rebuilt when rk's sources change.

Add an entry under `## Unreleased` in `CHANGELOG.md` for anything a user
would notice.
