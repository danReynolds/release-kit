# Step timings

Status: built. Settled rows keep their duration, `stage` and `release` end
with a summary line, and `--timings` gives the breakdown and a trace file.
The decisions are under "Decided" below.

## Why

Releasing Fleury 0.1.1 sat silent for about 30 seconds after the last
`Releasing …` heading: no row, no spinner, no elapsed time. On a loaded
machine the same pause ran to 80 seconds. Nothing failed and no test was
wrong; the only symptom was a person wondering whether rk had hung.

Finding the cause took timing a real run by hand, because no step said what it
cost. Once a run could report its own spans, four costs stood out of an
80-second stage reuse, none of them visible in the output:

| Cost | Calls | Time | Cause |
| --- | --- | --- | --- |
| Dart SDK probe | 119 | 23.3s | a temporary script run per compiler-identity read, behind Flutter's `dart` wrapper |
| `git show` per file | 719 | 11.0s | the same manifests re-read from the same commit |
| full stage verification | 20 | 15.6s | every new `StageDirectory` re-hashed every staged file |
| `pub cache preload` (fresh stage) | 220 | 13.5s | one VM start per dependency archive |

The fixes are in the stage-check change; this document is about not needing a
hand-built profiler next time. Two audiences want the numbers:

- **A person watching a release** wants to know what each step cost, so a slow
  step is noticed when it happens rather than felt as a hang.
- **A maintainer** wants to know where a run's time goes, down to subprocesses
  and hashing, to decide which step deserves optimizing.

## Constraints

From `doc/target-progress-plan.md` and the archived RFC 0002:

- TTY output may animate. Pipes and JSON stay deterministic: no spinner frames,
  no elapsed-time events, and "production output never serializes wall-clock
  progress".
- Rows name the work, not rk's internals. A person sees `verifying`, not
  `sha256 × 9,791`.
- Progress observes the release state machine; it never decides anything.

## Three layers

### 1. On a terminal: settled rows and the closing line

A row records how long it was active in all, from its first operation to the
moment it completes or fails, not only since its latest activity. A settled
row shows that duration once it reaches a second, the point at which its live
counter would have ticked, in the counter's own format:

```
✓   package archive                  staged · 1m 41s
·   source snapshot                  verified
```

A row restored from a receipt, or one never begun, never ran and shows none.
A row that ran and was then marked not attempted, a drained lane after a stop
elsewhere, keeps the time it ran. A successful `rk stage` or `rk release`
that took ten seconds or more ends with one line, leaving out phases under a
second:

```
Done in 2m 53s · preparing 2s · checking stages 31s · staging 1m 58s · publishing 22s
```

The phases are the ones the run's boards already name: `preparing` (reading
each unit's public targets), `checking stages`, `staging` and `publishing`.
Until the command names its first phase the run is `starting`, so slow setup
(reading the repository, probing the toolchain) is named too. Time at rk's
confirmation prompt counts toward no phase and no total: a release that
waited at the prompt over lunch did not take an hour. It is measured where rk
asks at the terminal, so `--yes` and `--json`, which never ask, record no
wait. Time in an interactive native tool (a registry sign-in, say) still
counts, because those tools also do the work and rk cannot tell their waiting
from their working.

Pipes and `--json` are unchanged by this layer, so a transcript or report
reads the same from one run to the next.

### 2. `--timings`: the breakdown on request

`rk stage --timings` and `rk release --timings` print, after the run and to
stderr, every phase with every row that ran during it, under the board that
showed it, however fast; for a run that stopped too, ending with a neutral
`Total`. Durations under ten seconds keep tenths, rounded down like the rest,
so quick steps can still be told apart. The same run is written to
`.rk/timings.json` as Chrome trace events, which Perfetto and
`chrome://tracing` open: phases on one track, each row on its own, waits on a
person marked where they fell. The file is rk's own, under `.rk/`, so the
next release does not find it uncommitted, and an earlier run's trace is
removed first, so a trace that could not be written is missing, not stale.
As with the stage store, it is written only into a `.rk` that is a real
directory and never through a link, which could point outside the
repository. A row cut off when the run stopped is listed under the phase it
started in.

The `--json` report's optional `took_ms` stays unfilled. Progress rows do not
map onto report steps: staging rows are per artifact, not per build or
completion step, so summing rows by step would have credited a public step
with its readiness check and left the build that took minutes with nothing.
Filling it honestly means timing each step where its outcome is recorded.

It is a flag of its own rather than part of a `--verbose`. rk has no verbose
mode to join, and one would have to decide what else it shows; tying timing
to it would hand a person who wanted timings everything else, and a person
debugging something else the timings. Cargo's `--timings` is the same
shape. A future `--verbose` could include the timings; not the reverse.

### 3. `RK_TIMINGS=1`: the maintainer trace

For a maintainer chasing a slow path, and undocumented on purpose: it shows
rk's internals, which layers 1 and 2 never do. Spans sit at module
boundaries:

- command phases: inspect, restore, eligibility, bind, prepare;
- stage verification, where a stage is actually read;
- subprocesses run through `Tools.run`, `timedRunSync` and the git source
  tree, named by the executable and the leading arguments that say what it
  does, up to the first that looks like data (a path, a ref, a
  `commit:path`), so every `git show <commit>:<path>` is one `git show`
  count (not yet: `runInteractive`, `GitState`'s own reads, and the macOS
  launcher compiler);
- tallies for work too frequent to be a span: digests (with bytes), receipt
  parsing, canonical JSON, stage fingerprints, and stage inspections answered
  from memory.

Spans propagate through zones, so work started under a span is charged to it
across awaits and `Future.wait`. Tallies are charged to the span they ran in.
`RK_TIMINGS_CALLERS=1` adds the first caller frame to each tally, read when
the work starts, which is how the 719 `git show` calls were traced to
`DartStageInputs.read`; it walks a stack per tally, so it is for diagnosis
only. With the variable unset, every call runs its body directly, and hot
paths do not even build a tally's name.

Excerpt, from the run that found the problem:

```
rk timings (wall clock; nested spans overlap their parent)
   0.000s +85.483s   rk
   2.708s +64.190s     resolve stages
   2.708s +12.484s       restore fleury
   6.292s +8.900s          adopt frozen stage
   7.018s +1.266s            inspect stage fleury
   7.085s +1.185s              verify stage files
                 = 0.495s    sha256 × 2452, 56.1 MB
```

## How it is built

- `ProgressRow` keeps the stopwatch of its first operation and freezes `took`
  when it completes, fails, or is marked not attempted after running.
- `LiveProgress` reports each settled row, with its group, to the run's
  `RunTimeline` (`lib/src/output/timeline.dart`), and a row still running
  when its board is discarded, as in a crash, as unfinished.
  `_writeDurableRow` adds the duration on a terminal.
- `release.dart` marks the phases, and `bin/rk.dart` runs its terminal prompt
  through `RunTimeline.waitingOnPerson`.
- `bin/rk.dart` prints the closing line and, under `--timings`, the
  breakdown and `.rk/timings.json`.
- `Timings` (`lib/src/engine/timings.dart`) is the maintainer trace.

## Decided

1. A row shows its duration from one second up. That is when its live counter
   would have ticked.
2. The closing line shows on a terminal for successful runs of ten seconds or
   more, and leaves out phases under a second and time at the prompt.
3. `--timings` is a public flag of its own (see layer 2), speaking only in
   phases, boards and rows. `RK_TIMINGS` stays a maintainer variable.
4. `took_ms` stays unfilled (see layer 2). It was first filled under
   `--timings` from the rows that showed each step, but rows are not steps;
   the trace file is the machine-readable timing until a step's own time is
   measured where its outcome is recorded.
5. No per-run history for now. Timings on a developer machine move with load,
   caches and the network; history can come later if a need shows.
6. Boards do not show a total in their settled title. The closing line covers
   the same question per phase, and a board total would have needed another
   clock read in a path whose tests count them.
