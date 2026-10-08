# Release status

```sh
rk status                    # check all release units, print the report, exit
rk status tools              # check one release unit
rk                           # same as rk status
rk status --json             # structured report for scripts
```

Status reads the destinations and exact local stage for the configured release.
It shows progress while checks run, prints the completed report, and returns to
the prompt. The report stays in terminal scrollback. Run it again for a fresh check.

It does not build, sign, install, or publish. `rk use` is the interactive picker
for which executable runs locally; `rk status` reports what this repository is
releasing.

## Read the report

Each release unit shows its candidate version, configured public destinations,
and local preparation still needed. Publication and staging are separate:

- **Published** means the candidate version is verified at the destination.
- **Not published** means the candidate is absent. The report shows an earlier
  published version when one is known.
- **Does not match** means published content conflicts with the candidate.
- **Could not be read** means a check failed; it is not evidence of absence.
- **Staged** means the exact local stage's receipt records the producers this
  rk runs, and every file it publishes still has its recorded size and digest.
  A missing stage does not undo an existing publication.

If the checkout has changed since its version was released, the report keeps
that publication visible and explains that the source now differs. The release
issue asks for a new version rather than replacing the existing tag.

Issues include the affected target, evidence and a remedy. When the checks can
identify a next step, the report prints the command; with several units
unfinished and no issues, that is the repository-wide `rk stage` or
`rk release`. Status itself changes nothing. A prerequisite is a version of a
package from this repository that a unit needs and another unit publishes.
While it is not on pub.dev, status shows it under the unit as **Releases after**
`core 0.3.0`, not as an issue: `rk release` publishes it first when both are
released together, and a release of the dependent unit alone refuses until it
is public.

A version on pub.dev counts as published; status does not compare archives
with it. The original stage is required only while a unit's built release
assets are partly public: the assets on a GitHub release, a Homebrew formula
that names their hashes, or the release manifest a pushed tag records for them.
Status reports `RK-STAGE-005` when that stage is missing. Otherwise it
recommends fresh preparation for what remains when all public destinations are
readable, even for a unit whose tag is already pushed. An unread destination
remains a blocking issue.

## Scripts and redirected output

Redirecting output suppresses transient progress and terminal styling.
`--json` emits one structured report, including release issues and an exit code.
A completed status report returns zero even when it finds work remaining;
invalid configuration or command arguments return an error.

See [the JSON contract](json.md) for fields and exit codes, or use `rk plan` to
inspect configured release steps without reading destinations.
