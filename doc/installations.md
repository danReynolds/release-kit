# Choose the commands you use

From a project with `release.toml`:

```sh
rk use                          # open the source matrix
rk use --list                   # inspect without opening the TUI
rk use local                    # prepare this checkout, then select it
rk install homebrew             # install without changing the selection
rk use homebrew                 # select it; install first if missing
rk uninstall pub                # confirm removal of an inactive installation
```

The matrix opens inline beneath your prompt and grows to fit its content, up to
24 rows. Your terminal keeps its background; green marks the current choice and
a blue fill marks mouse or keyboard focus. It opens without focus, so the saved
selection stays green until you navigate. Checkmarks and reverse video preserve
those distinctions with `NO_COLOR`. Use Tab or arrow keys to navigate and Enter
to choose. Hover moves focus without changing your selection.

A successful action for one project closes the matrix and leaves its result in
shell history. With several projects, the matrix stays open so you can change
another row; choose Done or press Escape when finished. `-p` limits it to one
project and restores single-action completion. Errors stay open for inspection
and retry. Unavailable choices open their full reason and repair command;
reading one does not fail the command. Back restores the originating choice
and scroll position. Uninstall asks for confirmation before removing an
installation and restores your place when cancelled.

Long configuration reviews and explanations show a scrollbar and accept
PageUp/PageDown or Home/End from their footer actions. Discovery notes in
`rk init` explain omitted packages and build-platform choices before you write
the configuration.

The matrix shows each executable package and its configured sources. Click a
cell or use the arrow keys and Enter. **Using** means the commands resolve to
that source on the process's PATH. **Selected** means RK has saved the selection,
but something earlier on PATH can still take precedence. `--list --json` also
reports each resolved command path. Shell aliases and functions are outside
this process-level PATH check.

Bare commands print an inventory when redirected. Explicit source arguments
work without a TUI; `--json` produces one structured report. Noninteractive
removal needs `--yes`. SDK packages are consumed as dependencies and do not
appear as installations.

## Workspaces and multiple commands

One executable package is inferred. With several, an explicit source requires
its package name; the bare matrix lets you work through all of them:

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
| Homebrew | Project publishes to Homebrew | Install the configured tap/formula with `--skip-link`; launch its complete keg |
| Pub | Project publishes to pub.dev | Activate the package with `--no-executables`; run its native global activation |
| GitHub | Project publishes native binaries through GitHub Releases | Download the latest stable release matching the unit's tag pattern and the current platform |

Existing Pub and Homebrew installations are discovered through their native
metadata. Pub path/Git activations are identified as a different source and are
not overwritten. Custom Pub registries and private GitHub downloads are not
supported by these installation adapters yet. A missing Dart or Homebrew tool
is reported with a reason; RK does not install the package manager itself.

`install` leaves routing unchanged. `use` prepares a missing installation and
then switches. Existing published installations are reused, never silently
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

Managed command shims live in `$XDG_DATA_HOME/rk/bin`, or
`~/.local/share/rk/bin`. RK owns only those shims and its installation state.
All commands in a project share one atomic selection pointer. A failed prepare
or a cancellation before that pointer changes leaves the old selection usable.
Cancelling waits for the current package-manager operation to settle; an
installation that already finished can remain installed without being selected.

On fish, `use` prepends this directory through `fish_add_path` using universal
state. Existing fish sessions normally pick that up at their next prompt.
Other shells receive the exact PATH command to run and persist in their own
configuration. RK never rewrites shell startup files. The next `rk use --list`
checks the environment actually inherited from the shell.

RK refuses to overwrite an unrelated command in its managed bin directory or
to follow symbolic links through its owned state directories. The project
identity combines GitHub origin and native package name; without a GitHub
origin it uses the configuration root and package name. Adding or changing an
origin can therefore require resolving an existing command ownership conflict.

Removing the active source is refused: select another first. Uninstalling Local
removes RK's registration, never the checkout. Uninstalling Pub or Homebrew
removes that package manager's installation, including one installed outside RK.
GitHub uninstall removes only RK's verified managed download directory.

If a checkout or native installation moves or disappears, launchers stop with
repair instructions. They do not fall back to another source. Native package
managers can also change installations independently; inspect the source matrix
and run `use` again to rebind the desired source.

## Implementation and qualification

`installations/manager.dart` owns the shared operation lifecycle;
`installations/store.dart` owns receipts and atomic routing. Provider adapters
live beside their publication counterparts under `targets/*/installation.dart`.
The Local adapter owns Dart source preparation. The Fleury views in `tui/`
provide input and presentation and call the same coordinator as explicit CLI
commands. Publication modules do not import the installation adapters.

The TUI dependency raises RK's minimum SDK to Dart 3.10.4. During development,
`pubspec_overrides.yaml` pins Fleury’s inline-mode API plus the native output and shutdown fixes from Fleury #278.
Replace this development pin with a qualified hosted Fleury dependency before
publishing RK to pub.dev. Fleury is confined to UI imports. The GitHub adapter
limits download and decompression sizes, then reuses the release engine’s exact
archive inventory validator. Signing, digests, and archive validation have no
third-party runtime imports.

See [the implementation receipt](installation-qualification.md) for the checks
actually run and the outstanding live-provider/platform qualification.
