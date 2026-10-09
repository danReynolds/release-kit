# Changelog

## Unreleased

rk now stages and releases a commit, reads each destination once, and asks
one question for the whole run. A fresh stage of Fleury's four packages takes
about 10s (2m 9s with 0.1.14), reusing it under a second (about 30s), and
releasing them and their two tags takes three trips to origin.

Stages an earlier rk saved are not reused, and `rk clean` removes them: a
release an earlier rk left partly published finishes with that rk.

### Releasing

- A release is of a commit. `rk stage` and `rk release` refuse uncommitted
  changes for every unit and a directory outside Git (`RK-GIT-001`,
  "commit first"); `RK-SRC-001` and `RK-SRC-002` are gone.
  `rk stage` no longer needs HEAD on origin; only the tag `rk release` pushes
  does.
- A release reads public state once and asks one question for every unit's
  remaining targets; the yes covers exactly those. rk signs in to pub.dev and
  GitHub once a run, after the yes, and no longer logs out of a pub session
  it created. The re-checks it made at a dozen boundaries are gone, with
  `RK-DEST-001`, `RK-AUTH-003`, `RK-SIGN-013` and `RK-STAGE-004`.
- Right before an upload rk reads the registry again and checks the staged
  bytes. A run lists origin's tags once, and a tag push is confirmed by git,
  which refuses to replace a tag origin has; a refused push reads origin's
  tag and reports the conflict with the usual advice (`RK-TAG-003` and
  `RK-TAG-004` are gone).
- The release tag is made on the staged commit. rk signs it when
  `tag.gpgSign` asks, as git does: a signing key alone, or an earlier signed
  tag, no longer signs tags, and rk no longer verifies the signature git
  made, so an expired or absent key no longer makes a published tag a
  conflict (`RK-TAG-006`, `RK-TAG-007`).
- A version on pub.dev counts as published: rk no longer compares a fresh
  stage's archive with one already there. After its own upload it still
  reads the archive back. After an upload pub.dev refused, it reads back for
  ten seconds, not ten minutes; after one it accepted, a read that fails is
  asked again until the version shows or ten minutes pass. It no longer
  downloads each published package into a fresh Pub cache (`RK-PUB-013`,
  `RK-REL-004`).
- A stage is needed only while public bytes must match it: assets on a
  GitHub release, or a Homebrew formula that names their hashes
  (`RK-STAGE-005`). A published package no longer requires its original
  stage. Without its stage, a Homebrew formula is rendered from the digests
  GitHub reports for the published archives, and a formula already at the
  release's version counts as published.
- `rk release` publishes a package's dependencies from this repository before
  it. A named release whose package needs a sibling not on pub.dev yet says
  to release them together (`rk release`) or the sibling first.
- A GitHub release whose title or notes were edited after publishing is still
  the release. A package pub.dev lists under another repository refuses
  before anything is pushed, and says what to do when the repository moved
  (`RK-PUB-010`).
- A tag on origin that matches the release pattern without naming a version,
  such as `v1.0` under `v{version}`, no longer refuses every release. A
  release tag only this clone has, made by hand, is refused with
  `git tag -d <tag>` as the fix, rather than as a public tag to leave alone.
- `rk stage` says to push first when origin lacks the commit a release's tag
  would name, rather than offering a release that would refuse.
- With no pub session stored, `dart pub login` runs at once, not after
  twenty silent seconds.
- A release whose lanes ran at once no longer says nothing public changed
  after one of them published.

### Staging

- A stage is named by what it is built from: commit, tree, configuration and
  origin. Updating rk, Dart or Xcode, or setting up a signing key, no longer
  orphans a stage a partly published release needs. Reuse checks the
  receipt and the size and digest of every published file; files the receipt
  does not name are ignored.
- Units stage side by side, from one read of the commit, and `rk stage` and
  `rk release` read every unit's destinations at once.
- Pub resolves each package once, the way its consumers will, through its
  normal cache, in one `dart pub publish --to-archive`. A sibling whose
  version is not on pub.dev yet comes from the same commit, through a path
  override Pub leaves out of the archive; everything else, including a
  published sibling, comes from pub.dev. rk no longer downloads dependencies
  itself or freezes their choices in a stage. A tracked dependency override
  no longer refuses a package (`RK-PUB-008`, `RK-PUB-016`, `RK-PUB-018`), and
  a Dart package in a workspace with Flutter packages stages with a
  standalone Dart.
- A stage holds only what rk publishes, and its receipt; it no longer keeps a
  copy of the source, which was 148 MB for each of Fleury's packages. Each
  producer builds in a directory of its own, with the source its build
  reads: for a package's Pub archive, every package in the repository, the
  files above it, what links lead to and the analysis options they include.
  A binary, whose Dart source can import any file by its path, and a
  project's own build get everything. rk's own memory during a fresh stage
  of Fleury peaks at about 140 MB, down from 225 MB.
- A repository that tracks a symbolic link, such as `CLAUDE.md -> AGENTS.md`,
  or a submodule stages. A link is exported as a link, with what it leads to.
  A submodule, whose files the commit does not hold, or a link that leads out
  of the commit, such as to an absolute path, refuses with `RK-STAGE-003`,
  naming it, when a Dart package holds or links to it, or anywhere in a
  repository whose project builds binaries or runs its own build; one no
  build reads is left out, as `git archive` leaves out a submodule.
- Staging offline reports that Pub could not reach the registry
  (`RK-PUB-019`), not validation errors to fix.
- A stage that no longer validates (`RK-STAGE-002`) names each file that is
  wrong, by its path in the stage: missing from the completed stage, or
  differing from the receipt in size or digest.
- A `.rk` that is a symbolic link, such as one on another disk, is used
  where it leads; `rk clean` still removes a stage that is a link without
  following it. `RK-STAGE-001` no longer reports "the release stage path is
  unsafe".
- A dependency written with no constraint (`foo:`, `foo: ~` or `foo: null`)
  allows any version, as Pub reads it (`RK-DEP-002` is gone). A comma inside
  a quoted list item in `release.toml` no longer breaks the list. Pubspecs
  are read with package:yaml, as Pub reads them.
- macOS signing uses the certificate the preflight chose and trusts
  codesign's exit status (`RK-SIGN-012`, `RK-SIGN-015`, `RK-SIGN-016`,
  `RK-SIGN-018` and `RK-SIGN-019` are gone). An accepted notarization no
  longer fails when Apple's log cannot be fetched afterwards
  (`RK-NOTARY-003`), and only the artifact's files are submitted. A
  container runtime is asked for only when a smoke test needs one.

### Status, plan and output

- `rk status` and `rk release` read a unit through one shared snapshot, so
  they agree on it. `rk status` lists units in release order, shows another
  unit's package that releases first as "Releases after", lists the warnings
  a stage recorded, and suggests the command that works: a unit stages
  alone, and releases with the sibling it releases after. With one edited
  file it reads the working tree once, in under half a second and 33 MB on
  Fleury.
- `rk stage` and `rk release` of several units say what they stage once: one
  heading, one Warnings section, one summary and one next step, with
  warnings in release order whichever unit finishes first. Piped output
  carries no times or counts. A long unit name is shortened rather
  than stopping the run, and a release says it acted only once something
  public changed.
- `rk help [command]` prints a command's help. A flag a command does not take
  is refused in two lines, and `rk target` without a name lists the targets.
  `rk --version --json` prints `{"version": ...}`. A closed stdout or
  stderr, as in `rk --help | head -1`, ends rk quietly.
- `rk init` with a release.toml already there points to `rk status` instead
  of reporting a problem (`RK-INIT-002` is gone).
- `--json` drops keys that never carried anything: `took_ms`, the plan's
  constant `source_only` and `destinations_inspected`, and each status
  target's `source_binding` and `source_comparison`. `rk plan --json` drops
  `dependency_candidates`; `requires_units` and the node graph carry the
  order.
- `rk clean` removes what it showed, and leaves alone an entry that changed
  while you answered.
- A control character in a tool's or a destination's message shows as a
  space in a progress row, rather than stopping rk.

### Configuration and diagnostics

- A clean commit's release inputs are read in two `git cat-file --batch`
  calls: release.toml with the root tree, then each project's directory,
  pubspec.yaml, Cargo.toml and CHANGELOG.md. `rk plan` on Fleury's four
  packages reads them in about 0.03s instead of 0.1s.
- `rk status` and `rk release` check the changelog of the commit they
  release, not the working tree's. A changelog committed as a link to
  another file in the commit is read through it, as a stage reads it; one
  that cannot be read is refused up front (`RK-SRC-003`), as an unreadable
  pubspec is. `rk use` does not read changelogs.
- A table header inside an array of tables, such as
  `[release.core.project.x]`, is a TOML error (`RK-TOML-001`).
- A diagnostic code names the kind of mistake; the message names the
  setting, and the location its line. Codes that repeat another are merged,
  and doc/codes.md lists 95 codes, down from 150:

  | was | now |
  |---|---|
  | `RK-CONF-001` | `RK-CONF-002` |
  | `RK-CONF-008`, `RK-CONF-016`, `RK-CONF-038` | `RK-CONF-003` |
  | `RK-CONF-004`, `006`, `007`, `010`, `013`, `014`, `015`, `017`, `018`, `020`, `022`, `023`, `027`, `028`, `029`, `032`, `033`, `037`, `040`, `042`, `043`; `RK-CONF-041` for a malformed list | `RK-CONF-005` |
  | `RK-CONF-012`, `019`, `024`, `025`, `036`, `039`, `044`, `045`; `RK-CONF-041` without binary_platforms | `RK-CONF-009` |
  | `RK-CONF-011` | removed: it only followed another refusal |
  | `RK-CONF-034` | `RK-SRC-003` |
  | `RK-RES-012` | `RK-CONF-009`, refused before any manifest is read |
  | `RK-RES-014` | `RK-RES-003` |
  | `RK-RES-005`, `RK-RES-015` | `RK-RES-004` |
  | `RK-RES-007` | `RK-RES-006` |
  | `RK-RES-017` | `RK-RES-009`, once for a unit whose release several projects build |
  | `RK-YAML-001` | `RK-PKG-001` |
  | `RK-PKG-003` | `RK-RES-002` |
  | `RK-CHG-002` | `RK-CHG-001` |
  | `RK-CLI-001` | `RK-CLI-005` |
  | `RK-CLI-008`, `RK-CLI-009` | `RK-CLI-003` |
  | `RK-CLEAN-001`, `RK-CLEAN-002` | `RK-STAGE-006` |
  | `RK-CLEAN-004` | `RK-AUTH-001` |
  | `RK-GIT-002` | `RK-GIT-003` |
  | `RK-SRC-004` | `RK-GIT-001` |
  | `RK-INIT-005` | `RK-INIT-004` |

### rk use

- `rk use` opens and lists in about 0.1s, down from about 1s with a Homebrew
  installation, and switching a source takes about 0.2s.
- A Homebrew selection keeps running after `brew upgrade`: launchers go
  through Homebrew's `opt` link instead of a versioned keg.
- Switching rk's own source no longer copies, or compiles, the running rk
  first. If rk's own checkout stops compiling while Local is selected, run a
  published rk by its path to switch back; `doc/installations.md` shows how.
- A GitHub update replaces the previous download, uninstall removes every
  download, and an install or update interrupted after unpacking finishes
  when it runs again, without downloading again.
- rk reads the selection back from the launchers, each of which names its
  project and source, and keeps GitHub downloads under
  `~/.local/share/rk/downloads/<package>`, so adding or renaming a project's
  GitHub remote no longer makes rk refuse its own commands or lose its
  download. rk still refuses a command it selected for another project, and
  `rk uninstall` refuses a source any of the project's commands runs,
  including through a launcher 0.1.14 wrote. A selection made by 0.1.14 keeps
  running; run `rk use` once to move it to the new launchers. Then what
  0.1.14 kept under `~/.local/share/rk`, `managers` and `projects`, can be
  deleted.
- Local is the checkout itself: `rk install local` prepares it, and Local
  shows as installed only while it is selected.
- Cancelling a switch before its package manager starts installs nothing;
  it used to install, then refuse to switch.
- Installation files or metadata rk cannot read are reported as
  `RK-USE-001`, like every other refused installation; `RK-USE-002` is
  gone. Bad metadata reads "The installation metadata is invalid.", and a
  command that cannot start is named instead of "the package manager".
- A GitHub download keeps the archive's file modes (0755 for executables,
  0644 otherwise) rather than 0700 and 0600. It follows the redirects GitHub
  gives it, and is checked against the release manifest's size and SHA-256
  as before; rk no longer limits which hosts it may be redirected to, caps
  archive sizes, or verifies macOS code signatures again at install.
- A `bin/` script that links outside its package can be selected.
- rk's bin directory on PATH written with a trailing slash, or through a
  link, counts as first: `rk use` no longer says to put it there.
- Bare `rk install` and `rk uninstall` open the `rk use` table.
- `rk use local` runs Dart commands whose dependencies have build hooks
  (native assets) from any directory, through a small bootstrap. Select
  Local again to prepare it.
- `rk use` finds local commands in projects that depend on path or Git
  packages.

## 0.1.14

- Say how long each step took. On a terminal, a finished step keeps its
  time once it reaches a second (`✓ package archive  staged · 1m 41s`), and
  a successful `stage` or `release` of ten seconds or more ends with one
  line of phases: `Done in 2m 53s · preparing 2s · checking stages 31s ·
  staging 1m 58s · publishing 22s`. Time at rk's confirmation prompt is not
  counted. Pipes and `--json` are unchanged.
  - `--timings` prints the whole breakdown after the run, to stderr: every
    phase and step, however fast, for a run that stopped too. It also writes
    the run to `.rk/timings.json` as a trace that Perfetto opens.
- Show what rk is doing while it checks saved stages, and check them
  faster. Between the last `Releasing` (or `Staging`) heading and the
  preparation order, rk verifies every unit's saved stage. It printed nothing
  there, often for tens of seconds. A `Checking stages` board now shows each
  unit's saved stage being verified, the units' public targets being read,
  and, for a unit with no stage, its dependencies being resolved. A row is
  active only while its own work runs, so a refusal marks the work that
  failed and nothing else, and the board is printed before the refusal.
  - Reusing four saved stages took about half as long in a measured
    four-package release. rk no longer runs the same work again within one
    run: probing a Dart SDK behind a launcher such as Flutter's `dart`,
    reading a file from a commit with its own `git show`, and re-hashing
    every staged file each time a stage is opened. Authorization still asks
    a Dart launcher which SDK it runs, before and after the yes, so a version
    manager that switches SDKs mid-run is noticed before anything is
    published.
  - Fresh staging preloads a unit's dependency archives in one
    `dart pub cache preload` per registry, instead of one per archive, with
    the same two minutes per archive. If Pub refuses the batch, each archive
    is retried alone, so an error still names the archive; when each one
    preloads alone, staging goes on.

- rk depends on Fleury 0.1 from pub.dev. The repository's override to a
  Fleury revision with the native output, inline shutdown and navigation
  fixes (Fleury #278) is gone: Fleury 0.1.0 includes them.
- Keep a released unit released while its own files are unchanged. A bare
  `rk release` used to stop at any unit whose tag was not on the current
  commit. It called the unit released from different source and asked for a
  version bump, even when later commits touched only other units or files
  outside every unit.
  - rk now compares the unit's directories between its tag and the current
    commit. Unchanged, the unit counts as released; changed, rk still asks
    for a bump (`RK-MONO-004`). Files outside the unit's directories, such
    as a root toolchain file or a sibling package, do not count: to release
    a change there, bump the version.
  - When the tagged commit is not in the clone, rk asks you to fetch the
    tag rather than calling it different source.
  - This only decides whether a unit is already released. Once a commit is
    staged, its bytes still need a tag on that commit.
  - A release interrupted after its tag is finished from the tagged commit,
    whose stage the tag binds: rk refuses to finish it from a later one
    (`RK-GIT-009`) and says how.
- Ask once for a repository release. A bare `rk release` of several units
  shows what each will publish, marked permanent or first claim, and asks
  one question before any of them acts.
  - Each unit still reads everything again before it acts. It asks for
    itself, and says why, if those reads show something the question did
    not, or if rk warns about it while it stages.
  - If a unit already cannot go ahead, as far as rk can tell before staging,
    each unit asks for itself, as before. `--yes` reads nothing ahead of the
    units.
- Publish release assets that a project's own build makes. A project declares
  `build`, the command, and `assets`, the files that command writes to
  `{out}`, and rk publishes those files as the unit's GitHub release.
  - The command runs from a clean copy of the committed source, once per
    stage, with the release's facts in `RK_OUT`, `RK_SOURCE_COMMIT`,
    `RK_REPOSITORY`, `RK_VERSION` and `RK_TAG`.
  - Only the declared files reach the release, each under its file name. The
    manifest types them `asset`, whatever their names end in.
  - A Rust crate (a directory with a `Cargo.toml` and no `pubspec.yaml`) is
    released this way, named and versioned by its `[package]` table.
  - The plan and JSON report show the work as a `buildAssets` step.
  - rk refuses a build that fails or cannot start (`RK-BUILD-003`) or misses
    a declared asset (`RK-BUILD-004`), and a unit whose settings do not add
    up (`RK-CONF-042` to `045`, `RK-RES-016`, `RK-RES-017`, `RK-PKG-003`).
  - On a terminal, the stage shows the build's latest line beside its
    elapsed time. A failed build's remedy ends with its last lines, and a
    missing asset's names what the build wrote instead.
  - `RK_CACHE` gives the build a directory that outlives the stage, under
    `.rk/cache`, for what the next build can reuse.
- Replace `rk release --stage` with `rk stage [unit]` to prepare and validate
  artifacts without publishing. `rk release` still prepares as needed and
  publishes. JSON schema 12 identifies the operation through `command` and
  removes the obsolete `mode.stage` field.
- Read the pubspec YAML that real packages write and that rk used to refuse.
  - Flow collections (`[a, b]`, `{name: value}`), after their key or on the
    lines below it, and continued over several lines.
  - Plain and quoted scalars wrapped over several lines or starting below
    their key, folded as YAML folds them.
  - Double-quoted escapes and doubled single quotes, decoded as YAML decodes
    them.
  - Lone carriage returns as line breaks, and a leading document marker.
  - Only spaces and tabs are white space, as in YAML.
  - Every `pubspec.yaml` and `pubspec_overrides.yaml` in a 1,594-file local pub
    cache reads exactly as package:yaml reads it. So does every document that
    both parsers accept in 240,000 generated by two differential fuzzers.
  - What rk does not read is refused rather than read as something else:
    - anchors, aliases, tags, complex keys and duplicate keys;
    - key: value pairs in flow sequences;
    - sequences nested on one line;
    - block scalar headers below their key;
    - undefined escapes;
    - unclosed collections and quotes;
    - flow lines not indented past their key;
    - documents that are not maps.
- Refuse a tracked dependency override (`RK-PUB-008`) only when it reaches the
  staged package, as Pub reports it.
  - The stage resolves its mirror of the source with `dart pub get` and
    `dart pub deps`, so Pub decides what is overridden:
    - Pub's compact report lists what it read from every package's
      declarations.
    - `pub get`, asked for its full report, prints each override it applied.
    - Its lockfile marks overrides.
  - rk adds its own reading of the declarations to these.
  - Pub records a snapshot carries from an earlier resolution are cleared
    first. Examples are not resolved, as `pub publish` does not resolve them.
  - rk refuses when the package reaches an overridden package, or is one.
  - It also refuses any reached package that Pub took from a path or Git
    source, because consumers receive only hosted and SDK packages.
  - Overrides that reach only other workspace members are listed in the run's
    report as `pub-overrides-<package>.txt`.
- Refuse to stage a package when rk cannot read Pub's resolution of it
  (`RK-PUB-016`): a failed resolution, a graph rk does not read, or no record
  of where Pub resolved or what its lockfile says.
- Refuse to stage a package that resolves with Flutter packages when rk's Dart
  is not a Flutter SDK's (`RK-PUB-014`). The check runs before Pub when rk can
  read the workspace, and from Pub's resolved graph otherwise. The stage
  records the Dart it uses, and a standalone one would depend on an
  unrecorded `FLUTTER_ROOT`.
- Validate a package against the versions its consumers resolve.
  - Pub resolves a second mirror of the snapshot with the package as a root
    of its own, then validates and archives it there. Other workspace members,
    the workspace root and tracked lockfiles no longer hold its dependencies
    to versions consumers do not get.
  - Workspace packages released in the same unit, and those needed only to
    develop it, come from the snapshot. Everything else comes from pub.dev.
  - The archive is unchanged: Pub never archives the `pubspec_overrides.yaml`
    rk writes there, or a lockfile.
  - rk refuses a package Pub cannot resolve that way (`RK-PUB-017`).
- Clear tracked lockfiles before Pub resolves the snapshot.
- Read the graph `pub get` recorded when `dart pub deps --json` fails. It
  fails when a workspace member's overrides file leaves out a package its
  pubspec overrides, and rk used to refuse such a workspace (`RK-PUB-016`).
- Report the warnings Pub finds while writing an archive (`RK-PUB-012`). With
  warnings alone, Pub exits 0, and rk used to drop them, including analysis
  errors in `lib`.
- Add an inline version table to `rk use`. Installed versions remain visible
  while remote checks run independently. Install and Update are separate from
  Use; Update appears only for a confirmed newer version. Navigation and checks
  remain responsive during installation, with additional operations queued.
- Open the release status matrix by default for `rk status` and bare `rk` in a
  terminal. Explore stage and destination evidence with the same inspection
  results used by the finite text and JSON reports.
- Add project-scoped `use`, `install`, and `uninstall` commands for executable
  packages, with Local, Homebrew, Pub, and public GitHub release sources.
  Bare commands open inline Fleury pickers; explicit sources and JSON support scripts.
  Local commands follow checkout edits, grouped commands switch together, and
  installation listings distinguish RK selection from effective PATH resolution.
- Replace init's terminal selector with the Fleury output matrix and a validated
  configuration review. Selected outputs read “Added”. Require Dart 3.10.4 or newer.
- Inline matrices keep the terminal background, use distinct active and focus
  colors, fit their content, and omit duplicate command labels. Keyboard
  navigation highlights one action; mouse capture stays disabled. Single-project actions close on success;
  multi-project matrices keep focus and stay open until Done. Init retains its
  configuration review, and unavailable choices explain why they cannot be used.
- Inline commands leave shell history intact and restore the prompt before
  reporting results. Ctrl+C and termination signals
  preserve their exit status while cancellation waits for in-progress work.
- Preserve the originating choice when returning from confirmation or details.
  Long reviews and errors support paging from their actions; init exposes
  discovery notes. Inspecting an unavailable source does not fail the command.
- Show archive locations after local-only builds.
- Add focused command help and one actionable next command for an unblocked
  unfinished release. Cancelling a release describes the current unit accurately,
  and cleanup lists recorded stage identities before confirmation.

## 0.1.13

- Homebrew installs keep macOS bundles intact. Homebrew rewrote the AOT
  module's install name and re-signed it ad hoc, so the installed command
  failed to start. The module now has an `@rpath/app.aot` install name and the
  formula declares `preserve_rpath`, so Homebrew leaves the signed files
  alone. Formulas need Homebrew 4.6.17 or later. A macOS CI test installs a
  real bundle through Homebrew and requires its signed files to be unchanged.
- macOS Dart bundles pin their AOT module. rk signs the module first, then
  signs the runtime with a library load constraint that admits only that
  module's code hash, reads the constraint back, and records both in the stage
  receipt. A runtime signed this way refuses other modules signed by the same
  team. Ad-hoc tests verify the refusal; Developer ID releases still need their
  own check. Runtimes published earlier, including rk 0.1.12's, are unpinned.
  RK-SIGN-017 to RK-SIGN-019 carry codesign's output. The stage schema is now
  12, so older stages are rebuilt.
- Release commands identify the project version and source checkout before work
  begins. Staging explains source, tooling, and configuration changes when a
  recent receipt can account for a rebuild, and names interrupted work it resumes.
- Release conflicts explain how to recover, with source and artifact evidence
  retained in JSON. Released-version conflicts point to the version and changelog.
- Staging ends with a success summary and the publish command. Verified reruns
  say the release is already staged; storage paths remain in JSON evidence.

## 0.1.12

- macOS Dart CLIs now ship as a signed launcher, matching runtime and AOT
  module, without executable-memory exceptions. Linux retains single-file
  executables; both use the same artifact, verification and Homebrew pipeline.
- Binary projects can project public pubspec fields through
  `dart_defines_from_pubspec` without duplicating their values in release config.
- Bundled RK keeps a stable stage identity when run from its module directory,
  and installed RK uses the Dart SDK for pub.dev availability checks.
- `rk init` now selects every binary platform the release host can produce;
  macOS proposes its native archive plus both pure-Dart Linux cross-builds.
- Cross-built Linux artifacts always receive explicit Dart target flags, even
  when Docker or Podman is unavailable. Containers provide the optional smoke
  test; they are not a cross-compilation requirement.
- Multi-unit status checks now nest release targets beneath their unit instead
  of repeating the unit on every row.

## 0.1.11

- Releases no longer wait for Apple's online Gatekeeper ticket propagation
  after exact publication. Notarization acceptance remains a mandatory stage
  gate, and public release read-back remains exact.

## 0.1.10

- `rk plan [unit]` now renders the configured source-only release graph from
  the same stage and public dependency contracts that `rk release` executes;
  `--json` retains every direct edge without inventing runtime state.
- Terminal output now uses one semantic role-and-state vocabulary across
  commands, with plain-text parity, `NO_COLOR` support, and inert rendering of
  captured control bytes. Machine and redirected releases no longer inherit
  native login prompts.
- macOS release staging now verifies the `rk-notary` credential before any
  build starts, and interrupted producers discard only their declared,
  unreceipted outputs so retries can reuse validated independent lanes.
- Incomplete stages are described as incomplete rather than reviewed, and
  successful stage paths keep their content-addressed id on a readable line
  in narrow terminals.
- After exact publication read-back, rk gives pub.dev resolver visibility and
  Apple notarization-ticket visibility a bounded consumer check. Provider lag
  is reported as a nonblocking availability warning and never triggers a
  second publication attempt.
- `rk init` now omits workspace grouping roots and hides `publish_to: none`
  packages by default; press `a` to reveal intentional non-registry release
  candidates, while JSON still reports every discovered candidate.

## 0.1.9

- Status no longer reports local binary archives as unstaged after an exact
  public target has already bound every archive in the completed release.
- Standalone macOS notarization verification examples now ask codesign to
  perform its required online ticket check.
- Single-architecture Homebrew releases now declare explicit OS and CPU
  requirements, so unsupported hosts receive the real compatibility refusal
  instead of a misleading missing-URL error.
- Successful staging prints its exact repository-relative directory instead
  of wrapping a long absolute checkout path, and RK's repository-local release
  helper advances both version declarations together.
- Published Homebrew formulas are verified against the immutable Formula
  digest recorded by their tag-bound release manifest, so later renderer
  improvements do not rewrite release history.
- Generated multi-platform Formulae now use Homebrew's supported nested OS and
  architecture DSL and include the standard Ruby and Sorbet headers.

## 0.1.8

- Homebrew is now Formula-only throughout inspection, staging, manifests, and
  tap updates. RK no longer reads, converts, or removes legacy Cask state.
- Binary and Homebrew initialization now defaults to the current host's native
  platform, so a Linux host does not silently propose a macOS artifact it
  cannot produce. Cross-builds remain explicit configuration choices.
- Docker and Podman capability probes are bounded and run only for releases
  that ship binaries. Missing or unresponsive runtimes remain optional and
  degrade cross-build smoke evidence instead of blocking publication.

## 0.1.7

- Homebrew releases now use a Formula, the native installation surface for a
  command-line tool, so freshly downloaded signed binaries run under macOS
  Gatekeeper instead of being rejected as an unstapled Cask artifact.
- The first Formula publication compare-and-swaps both tap coordinates in one
  commit: it creates `Formula/<name>.rb` and removes only the exact legacy
  `Casks/<name>.rb` that rk inspected.
- Release manifests now describe a generic Homebrew binding while retaining
  read compatibility with the public schema-6 Cask manifests.
- Native and containerized binary smoke tests now have a finite deadline, so
  a wedged runtime or credential helper cannot hold staging indefinitely.

## 0.1.6

- Pub publication confirmation now reads the immutable version coordinate
  rather than waiting for the package-history listing to catch up.
- Successful Pub uploads are given the service's documented ten-minute
  propagation window before rk reports that it lost sight of the result.

## 0.1.5

- Status now distinguishes a valid historical release tag from current source
  that still declares the released version, keeps the public target healthy,
  and directs the next release to bump rather than move an immutable tag.
- Target conflicts now carry structured, target-owned diagnostics and evidence
  while core retains the small shared lifecycle and reporting contract.
- Pub package warnings survive reusable stage receipts, raw provider failures
  are separated from recovery instructions, and cross-built binaries that were
  not executed are disclosed before release authorization.
- Published package evidence states why archive bytes were not compared, and
  already-released source no longer produces a misleading unstaged-artifact
  section.

## 0.1.4

- macOS signatures are verified again after the signed executable smoke test
  and against the executable decoded from the final release archive. A release
  now stops before publication if either final-artifact boundary fails.
- Stage schema 10 records and validates archive-extracted signature evidence,
  so a reusable stage cannot claim the stronger macOS gate without having run
  it.

## 0.1.3

- Staging and publication now run from validated dependency graphs. Independent
  work starts in parallel, and dependent targets unlock as soon as their own
  prerequisites finish instead of waiting for unrelated targets.
- Stage artifact inputs are checked against their producers, platform build
  lanes keep isolated scratch space, and failures stop new work while draining
  operations that have already started to a known result.
- Release progress remains on one coordinated target board, including concise
  waiting-on-prerequisite status, while captured provider output no longer
  disrupts the display.
- The target documentation now explains the shared graph, lifecycle-specific
  execution policies, and the minimal extension boundary for adding target
  N+1 without target-specific scheduler hooks.

## 0.1.2

- Release targets now live in small vertical slices behind a compact module
  contract. GitHub Release is the worked example for adding an N+1 target,
  while provider transactions remain private to their target.
- Release orchestration is split into preparation, staging, and publication
  coordinators. Targets describe their plans and observations; core retains
  ordering, authorization, reconciliation, and reporting.
- Concurrent platform builds use isolated producer lanes, and subprocess
  deadlines now cover process exit plus inherited output streams.
- Core CI runs formatting, static analysis, and the complete test suite on
  Ubuntu and macOS.

- Signed macOS binaries now start. The hardened runtime refuses the executable
  pages a Dart AOT snapshot maps at launch, so 0.1.0's binary was killed by the
  kernel before it printed anything — while its signature verified, its
  notarization succeeded, and Gatekeeper reported it as accepted. Signing now
  grants `com.apple.security.cs.allow-unsigned-executable-memory`, the one
  entitlement that fixes it.
- The signed binary is executed before a release can proceed. The smoke test ran
  at build time, so it proved the built binary worked and signing then broke it
  unobserved; a binary that will not start now fails the release (`RK-SIGN-014`).
- A bare designated-requirement identifier is read, not only a quoted one. rk's
  own identity prints unquoted, so rk could recognise every other project's
  published identity and not its own — which surfaces on a second release and
  never a first.
- Failure and publish evidence is retained where it was previously dropped, and
  a run nobody is waiting on no longer stops to ask.

## 0.1.0

Initial release of rk, a release tool.

- Three operational verbs: `status`, `init`, and `release`, plus the static
  `target` reference; public reality is the release record and re-running is
  the resume.
- Releases to pub.dev, GitHub Releases and a Homebrew tap, with signed and
  notarized macOS binaries, cross-compiled Linux binaries, notarization
  evidence published beside the archives, and a manifest binding every asset
  and Homebrew Cask.
- `release --stage` runs every private step for real — package preflight,
  build, sign, notarize, archive, notes, manifest, and Cask —
  and records exact reusable artifacts without publishing them.
- `status` and `release` share exact target inspection for Git tags, pub.dev,
  GitHub Releases, and Homebrew; every public act is inspected before and
  after, and a retry skips targets already published.
- Target rows show `✗` for any concrete issue linked to that target. Status has
  no synthetic authentication verdict: unsupported safe checks stay silent
  until release preflight.
- A normal interactive release runs one native `dart pub login` after private
  staging and before authorization when an unfinished pub.dev target exists;
  `release --stage` never logs in. Login proves a session, while publish plus
  public read-back remains the proof of package authority and completion.
- Compiled binaries report their embedded package version with `rk --version`
  so staging and downstream package managers can reject stale artifacts.
- Human status keeps diagnostic codes in JSON, distinguishes nonblocking
  warnings, and reports a local version succinctly as `behind` public reality.
- pub.dev package history is checked against the repository declared by the
  local pubspec, so a name owned by another project is reported directly.
- Dirty Git working trees may release registry-only or local outputs through
  an exact unbound snapshot; Git-identified targets still require clean source.
- Versioned publications are append-only: Pub stages and uploads one native
  archive, retained native digests catch known divergence, and occupied
  historical coordinates are never rebuilt or overwritten. Homebrew remains
  a forward-only channel updated by compare-and-swap and can recover from the
  authenticated public GitHub asset set when its local stage is gone.
