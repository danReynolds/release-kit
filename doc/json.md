# The machine surface: `--json`

One complete JSON document on stdout, nothing else. It survives every
non-zero exit, is never truncated, and is written by the same calls that
print the human output, so the two surfaces cannot drift. Schema version
rides in `"rk"` and is bumped only when a key changes meaning.

This is the surface an agent drives a release through. The loop it
supports, end to end:

```
rk status <unit> --json                 where things stand; read-only
rk release [unit] --stage --json        exact stage; name it with several units
rk status <unit> --json                 confirm: staged, good to release
rk release [unit] --yes --json          publish and read back without prompting
rk release [unit] --yes --json          idempotent: already-exact, no second act
rk target list --json                    installed rk's static release choices
```

`--yes` answers only the ordinary release question. The unit versions and
remaining targets are still reported, and every inspection and refusal still
runs. A bare release may cover several independently versioned units; name a
unit when an automation caller needs the narrowest scope.

## Top level

| key | meaning |
|---|---|
| `rk` | schema version (currently `7`) |
| `command` | the verb that ran |
| `mode` | present only where the run has one: `{stage}` on `release` |
| `observed_at` | UTC ISO 8601 — when rk read the world |
| `exit` | mirrors the process exit code |
| `rerun_helps` | whether re-running would move things forward — false on conflicts, where a human has to decide. Re-running is always *safe*: the same inspection precedes every act |
| `repository` | `{name, branch?, head?, remote, uncommitted?, source_binding?, source_comparison?}`. `head` is the full 40-char SHA and is absent for unbound source. `remote` is always present and null when no origin exists. Status and release report `source_binding` as `gitCommit` or `unbound`, independently from `source_comparison` (`exact` or `unavailable`) |
| `init` | present on `init`: `{source: {binding, git_remote, github_repository}, notices[], candidates[]}`. `github_repository` is always present and null when unavailable. Each candidate reports its unit, native project/path/version/executables and every option's `available`, redacted `reason`, `selected`, and deterministic `effects[]`. A candidate is included when at least one release output is selected |
| `release_choices` | present on `target`: the static choices understood by this installed rk. This command reads no repository and these entries never contain `selected` or `available` |
| `units[]` | per-unit: `{name, version, tag, steps[], targets[]?}`. `tag` is null when Git tagging is not selected |
| `problems[]` | `{code, message, remedy?, source?, unit?, target?}` — every refusal and blockage, with its `RK-*` code. `target`, when present, is the affected target id and makes that target's human row `✗` |
| `warnings[]` | nonblocking findings with the same shape as `problems[]`. Human output marks these with `!`; stable `RK-*` codes appear only in JSON |
| `next[]` | the commands that would advance things, as data. The human report does not print them; this is where they live |
| `halt` | `{kind, sentence}` when the run halted |
| `attachments` | documents that travel with the run (a proposed release.toml, pub's validation text) |
| `diagnosis` | where evidence was written, on failed runs that acted |

`halt.kind` is one of `beforeActing`, `stoppedPartway`, `lostTrack`,
`unfixableByRerun`, or `actedAndUnfixable`. `beforeActing` means no public
target changed; late native session acquisition may still have refreshed local
credential state. The accompanying sentence states what changed and whether
re-running can advance the work.

An empty `problems[]` remains the release gate. `warnings[]` never changes the
exit code or authorizes work by itself; it discloses facts such as a
registry-only release capturing dirty working-tree state.

## Target reference

`rk target list --json` returns all entries in `release_choices[]`;
`rk target <name> --json` returns the same array shape filtered to one entry. Each entry
contains `id`, `label`, `category`, `summary`, `description`, `requires[]`, a
`select[]` guide, `configure[]`, `native_configuration[]`, an optional
`supported_binary_platforms[]`, and a minimal `example`. `category` is
`localOutput` for Binary and `releaseTarget` for the
public target catalog. The reference describes the installed binary only: use
`status` for configured repository state.

## One fact, one place

`targets[]` is the canonical record of public-target state on `status`;
`steps[]` carries the local pipeline, prerequisites, and — during
`release` — what this invocation did with each step. status no longer
repeats the four public targets under `steps[]`: an agent that wants a
target's verdict reads it where the settled observation lives.

## Steps

Keyed by frozen `id` (treat ids as opaque tokens). Fields: `id`, `kind`,
optional concrete `target`, `summary`, `verdict`,
`permanent?`, `public?`, `needs[]`, `detail?`, `evidence?`, `took_ms?`, and
optional `action` during `release`.

`kind` describes lifecycle mechanics; `target` is the stable destination id
for public steps (for example `pubDev` or `githubRelease`). More than one
registry can therefore share `publishRegistry` without becoming ambiguous.
`action` records what this release invocation did with a public target:
`not_attempted`, `attempted`, `already_exact`, `completed`, or `failed`.
It is an execution result, not another target-state vocabulary; `verdict`
remains the shared status/release observation. Native login is not a target
action. A pub.dev action is `completed` only after publish and exact public
read-back; an idempotent retry records `already_exact`.

`verdict` is one of, frozen:

- `absent` — not there, from an authenticated negative. Work to do.
- `exact` — there, and it is what this configuration produces.
- `conflict` — there, and it differs. Re-running will not fix it.
- `unknown` — rk could not tell. **Never** collapsed into `absent`; read
  the entry's `detail` for why.

## Status targets

Each `units[].targets[]` entry is the settled observation the human report
renders as one target row: `id`, `kind`, `label`, `coordinate`, `current_known`,
`current_version`, `target_version`, `verdict`, `source_binding`,
`source_comparison`, optional `detail`, optional `uses`, and `artifacts[]`.
The source fields stay independent of the target verdict: a non-Git target may
be remotely exact while source comparison remains unavailable. `uses` refers
to an artifact inventoried under
another target without duplicating it. An artifact is
`{name, status, problem?}`, where `status` is
`notStaged`, `staged`, or `invalid`. These are stage facts, not release
lifecycle states; public state remains the four-value `verdict` above.
Authentication does not add a fifth verdict or another green/unknown field.
Supported safe read-only checks may contribute a concrete target-linked
problem. When no safe check exists, status emits no authentication fact and
normal release preflight owns the check.

## The gate rule

For CI or agent gating on `rk status --json`, the blessed rule is all three
of:

1. `problems` is empty. Public conflicts and unread targets are recorded
   here as actionable diagnostics as well as on their target observations,
   so this catches the human report's `Issues` section without parsing
   prose.
2. No `targets[]` entry has `verdict == "conflict"` — belt to problems'
   braces.
3. `unknown` never auto-proceeds: a destination rk could not read answers
   `unknown`, never `absent`. A tag git does not hold is `absent`, which is
   work remaining, not work done — so an unreadable world blocks a gate
   rather than passing it.

Exit codes (also in `-h`): `0` a successful report or completed command;
`1` refused or failed; `2` usage; `3` rk itself crashed. A requested JSON run
still writes one final report on exit `3`, including the diagnosis pointer when
rk may have acted; the diagnosis directory holds the detailed evidence.
