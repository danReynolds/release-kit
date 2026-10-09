# Choose the commands you use

From a project with `release.toml`:

```sh
rk use                          # compare sources and available updates
rk use --list                   # inspect without opening the TUI
rk use local                    # prepare this checkout, then select it
rk install homebrew             # install without changing the selection
rk install homebrew --latest    # install the latest compatible version
rk use homebrew                 # select it; install first if missing
rk uninstall pub                # confirm removal of an inactive installation
```

Bare `rk install` and `rk uninstall` open the same table as `rk use`, which
installs, updates and removes from its rows.

The picker opens inline beneath your prompt and grows to fit its content, up to
24 rows. The source table is left-aligned and capped at 104 columns, shrinking
with narrower terminals. Other command matrices cap at 128 columns to fit their
additional outputs. Your terminal keeps its background; green marks the effective
default and blue marks action focus. The table accepts mouse clicks; hovering
does not highlight buttons or move keyboard focus. It opens without focus, so
the default stays green until you navigate or click. Checkmarks and reverse
video preserve those distinctions with `NO_COLOR`. Use Tab or arrow keys to
navigate and Enter to choose. Other command matrices use keyboard controls.

A successful source switch for one project closes the picker and leaves its result in
shell history. With several projects, the picker stays open so you can change
another row; choose Done or press Escape when finished. `-p` limits it to one
project and restores single-action completion. Errors stay open for inspection
and retry. The source table shows unavailable reasons and repair commands
beneath the affected row and disables unavailable actions. Uninstall appears in
the footer for a focused inactive installation. Removal asks for confirmation
and restores your place when cancelled; it never removes the active or saved
selected source.


Long configuration reviews and explanations show a scrollbar and accept
PageUp/PageDown or Home/End from their footer actions. Discovery notes in
`rk init` explain omitted packages and build-platform choices before you write
the configuration.

The table groups sources by executable package. Up/Down moves between sources;
Left/Right chooses an action; Tab moves between buttons. Enter activates exactly
the blue action. **Default** is a static badge: the commands resolve to that
source on the process's PATH. **Selected** means RK has saved the selection,
but something earlier on PATH can still take precedence. `--list --json` also
reports each resolved command path. Shell aliases and functions are outside
this process-level PATH check.

Bare commands print an inventory when redirected. Explicit source arguments
work without a TUI; `--json` produces one structured report. Noninteractive
removal needs `--yes`. SDK packages are consumed as dependencies and do not
appear as installations.

## Install and update

`rk use` opens with **Installed** from local inspection and **Available** checking
in the background. Each source finishes independently. You can use an installed
version while checks run, and a failed check leaves that version usable. Focus
an affected row to see its error; **Retry** checks just that source and **Refresh**
checks all sources. Closing the picker cancels its background network requests.
`--list` and redirected commands remain local, without remote checks.

**Update** appears only when a successful check confirms a newer compatible
version. Checking and current sources have no Update button; an absent
installation offers **Install** after its version check.

While an install or update runs, other rows and Refresh remain usable. Additional
actions show **Queued** and run in order, keeping package-manager and routing
changes serialized. Esc cancels queued actions and lets the running operation
settle safely. A failed operation clears the queue for review.

**Use** selects an installed source and closes a single-project picker.
**Install** or **Update** installs the displayed available version and keeps the picker open.
It does not select another source. If you update the source already selected,
its new version runs on the next command. Local has no remote version: **Use**
prepares and binds the checkout you are in. Explicit `rk use pub`, for example,
still installs first when missing; the table keeps those two actions separate.

| Source | What Available means | Install / Update |
| --- | --- | --- |
| Homebrew | Stable RK-generated formula in the configured public tap for this host | Refresh Homebrew metadata, verify the formula still matches, then install or upgrade that formula |
| Pub | Highest stable, non-retracted release with the same commands and a compatible installed Dart SDK | Activate that exact version with Pub; its dependency solver remains the final compatibility check |
| GitHub | Stable release matching this release unit, with an archive for this host | Download the checked archive and verify its size, checksum, layout, and executable |

Checks do not install packages or refresh Homebrew's local repositories.
A Homebrew update runs `brew update` before installing; it can refresh other
tap metadata, but RK only asks to install or upgrade the chosen formula.
Existing Homebrew links follow the package manager's normal upgrade behavior.
The manager protects RK's source selection, not external shell aliases or links.

Installations show progress in place. Escape or Ctrl+C during a package-manager
operation waits for it to finish safely. An update already committed is retained,
and RK finishes recording it before restoring the terminal. Cancellation is not
an undo operation. Completed installations never automatically move focus to **Use**.

## Workspaces and multiple commands

One executable package is inferred. With several, an explicit source requires
its package name; the bare table lets you work through all of them:

```sh
rk use
rk use local -p orbit_cli
rk install pub --project orbit_admin
rk uninstall homebrew -p orbit_cli --yes
```

`-p` names the native package, not a release unit or an individual command. If
`orbit_cli` exports `orbit` and `orbit-admin`, they switch together. A shared SDK
follows that installation's dependency graph; it cannot be selected separately.

Commands look for a containing `release.toml`, stopping at a repository boundary.
They do not maintain a global application picker. Outside an RK project, they
report that no RK setup was found. The selected executables themselves work
from any directory.

## Sources

| Source | When offered | Preparation and execution |
| --- | --- | --- |
| Local | Package declares executables | `dart pub get` in this exact checkout; launch the mapped `bin` entrypoint with Dart |
| Homebrew | Project publishes to Homebrew | Install the configured tap/formula with `--skip-link`; launch it through Homebrew's `opt` link, which follows upgrades |
| Pub | Project publishes to pub.dev | Activate the package with `--no-executables`; run its native global activation |
| GitHub | Project publishes native binaries through GitHub Releases | Download the latest stable release matching the unit's tag pattern and the current platform |

Existing Pub and Homebrew installations are discovered through their native
metadata: Pub's activation, and Homebrew's `opt/<name>` link with the receipt
that names the tap it came from (what `brew list --full-name` reads), so
inspecting Homebrew asks `brew` only for its prefix. Pub path/Git activations are identified as a different source and are
not overwritten. Custom Pub registries and private GitHub downloads are not
supported by these installation adapters yet. A missing Dart or Homebrew tool
is reported with a reason; RK does not install the package manager itself.

`install` leaves routing unchanged. `use` prepares a missing installation and
then switches. Local is the checkout itself: `rk install local` prepares it,
and Local shows as installed only while it is selected. Existing published installations are reused, never silently
upgraded. Local preparation refreshes dependencies and binds the checkout from
which you invoke it. Source edits are picked up on the next invocation, with no
reinstallation or Git pull. The launched program keeps your working directory
and arguments.

GitHub archives must use RK's current release manifest and supported single-file
or Dart bundle layout. The installer checks the manifest's unit, version and
tag, archive size and SHA-256, and the complete file inventory. It rejects
links, traversal, duplicate entries and unknown files. macOS code signatures
are checked, and the command must successfully report the released version
before the installation is accepted. Checksums prove consistency with that
GitHub release; they are not independent publisher authentication.

## Routing and recovery

Command launchers live in `$XDG_DATA_HOME/rk/bin`, or `~/.local/share/rk/bin`.
Each one names its project and source in a header, so rk reads the selection
back from the launchers rather than storing it; the only other state is
GitHub downloads, in `downloads/<package>/<version>` beside `bin`. `use`
replaces each command's launcher atomically. A failed prepare or a
cancellation before the launchers are written leaves the old selection
usable. Cancelling waits for the current package-manager operation to settle;
an installation that already finished can remain installed without being
selected.

On fish, `use` prepends this directory through `fish_add_path` using universal
state. Existing fish sessions normally pick that up at their next prompt.
Other shells receive the exact PATH command to run and persist in their own
configuration. RK never rewrites shell startup files. The next `rk use --list`
checks the environment actually inherited from the shell.

A launcher names its project by package name and its source by name, as in
`# rk-managed:orbit_cli:homebrew`, and each command's launcher is read on its
own. RK refuses to overwrite a command in its bin directory that it did not
write, or that it selected for another project; `rk use --list` reports a
command another project's launcher holds. Changing a project's origin or
moving its checkout does not lock rk out of its own commands. A launcher rk
0.1.14 wrote names its project by a hash and forwards to that project's
`projects/<hash>/current`, which records the source: rk reads the selection
from there, and the next `rk use` of a project exporting the command replaces
it.

Removing a source any of the project's commands runs is refused: select
another first. Local is the checkout itself, so there is nothing to uninstall.
Uninstalling Pub or Homebrew removes that package manager's installation,
including one installed outside RK. GitHub uninstall removes RK's downloads
for that project. An update replaces the previous download once the new one is
installed and routed. A download is recorded by its directory, so an install
or update interrupted after unpacking finishes when it runs again, without
downloading again.

If a checkout or native installation moves or disappears, launchers stop with
repair instructions. They do not fall back to another source. Homebrew and Pub
launchers follow their package manager's own upgrades: `brew upgrade` moves the
`opt` link, and `dart pub global run` runs whatever Pub has activated.

## Implementation and qualification

`use` shares the bounded table, focus treatment, detail view and terminal
lifecycle with [`status`](status.md). Green identifies the
effective local default; blue identifies the one action Enter will activate.
Status uses green for verified stage/publication facts. Its cells inspect
release evidence, while Use changes local installations and command routing.

`installations/manager.dart` owns the shared operation lifecycle;
`installations/store.dart` owns the launchers. Provider adapters
live beside their publication counterparts under `targets/*/installation.dart`.
The Local adapter owns Dart source preparation. The Fleury views in `tui/`
provide input and presentation and call the same coordinator as explicit CLI
commands. Publication modules do not import the installation adapters.

The TUI dependency raises RK's minimum SDK to Dart 3.10.4. Fleury is confined to
`lib/src/tui`. Elsewhere rk imports only the Dart team's `crypto`, `pub_semver`
and `yaml`: SHA-256 digests, Pub's version semantics (the Pub installation
adapter evaluates SDK constraints with them), and pubspecs read as Pub reads
them. A test in `test/end_to_end_test.dart` keeps it that way. One HTTPS fetch
serves the pub.dev and GitHub checks and downloads. The GitHub adapter limits
download and decompression sizes, then reuses the release engine's exact
archive inventory validator. `RK_TIMINGS=1` traces where an installation
command's time goes.

The [qualification record](archive/installation-qualification.md) lists the
checks run when installations were built.

### Local packages with native build hooks

For a local package whose resolved dependencies contain `hook/build.dart`, RK
starts Dart in the owning package so a cold launch prepares its native assets.
A generated bootstrap then starts the original entrypoint in an isolate with
the caller's working directory. Arguments, stdin, exit status and Platform.script
continue to describe the actual application. Native source edits rerun the hook
through Dart's normal cache checks.

This covers Dart's current directory-dependent hook discovery. Plain Dart local
packages retain the direct launcher. Reselect Local after adding/removing a hook
dependency, changing package resolution, or upgrading RK from an older launcher.
An existing local selection does not rewrite its own generation automatically.

Installation discovery allows unpublished path and Git dependencies in
development checkouts. Release planning and publication retain their existing
dependency-source checks.
