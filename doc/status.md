# Release status

```sh
rk status                    # print a report and return to the prompt
rk status --interactive      # explore an inline release matrix
rk status tools --interactive
rk status --json             # structured report for scripts
```

Status reads the destinations and exact local stage for the configured release.
It does not build, sign, install, or publish. `rk use` manages which executable
runs locally; `rk status` inspects what this repository is releasing.

## Explore the matrix

Each row is a release unit and its candidate version. Columns come from the
configuration: Stage, Git tag, pub.dev, GitHub and Homebrew appear when relevant.
An unconfigured destination is a dash. A grouped unit's publication cell covers
all packages going to that destination; open it to see each package separately.

Checks begin on opening. Cells update independently as destinations answer.
The completion timestamp identifies the snapshot; `r Refresh` rereads source
configuration, Git state, stages and destinations. A failed read is shown as
unknown or failed, never as proof that nothing was published.

- Use arrows to move between units and destinations, or Tab between controls.
- Click a unit or press Enter on it for its overview and release issues.
- Open a destination to inspect its candidate, latest published version and
  evidence. Open Stage for its receipt, artifacts and any validation problems.
- Escape or Back returns to the same cell; Escape from the matrix closes it.
- Done leaves the completed report in the terminal. Ctrl+C cancels reads,
  restores the terminal and preserves the interrupt exit status.

The matrix starts without keyboard focus. Green marks verified stage or
publication facts; blue marks the specific cell or action Enter activates.
Narrow terminals stack destinations beneath each unit, with scrolling for
short windows. Use shares these bounds, controls and detail views.

## Read the evidence

`Published` means that candidate version is verified at the destination.
A unit marked `changed` has new source under an already released version; its
release issue remains visible even when every destination is published. `Latest` names the
latest published version returned by its reader, which can differ from the
candidate. A grouped cell reports partial publication rather than hiding the
remaining packages. An unread history remains a failed check even when the
candidate itself could be read.

`Staged` means the exact local stage is complete and reusable. It is independent
of publication: a completed local binary can remain staged without a public
destination. A missing local stage does not undo an existing publication.

Release issues are available from the footer and the affected unit's detail.
Green cells alone do not establish release readiness. Any next command comes
from the same checks as the plain report; `rk release` rechecks its prerequisites
before publishing.

If refreshing source configuration fails, previous results are labelled as
previous and the full error remains available through Error details. Missing
configuration returns to the prompt with setup guidance. Without a usable
terminal, or with `--json`, `--interactive` falls back to the finite report.
