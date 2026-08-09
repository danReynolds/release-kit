# The machine surface: `--json`

One complete JSON document on stdout, nothing else. It survives every
non-zero exit, is never truncated, and is written by the same calls that
print the human output, so the two surfaces cannot drift. Schema version
rides in `"rk"` and is bumped only when a key changes meaning.

## Top level

| key | meaning |
|---|---|
| `rk` | schema version (currently `2`) |
| `command` | the verb that ran |
| `mode` | how the run was asked to operate: `{stage, offline}`. An offline document's `unknown` verdicts are only interpretable with this beside them |
| `observed_at` | UTC ISO 8601 — when rk read the world |
| `exit` | mirrors the process exit code |
| `safe_to_rerun` | whether running the same command again can do harm (rk's model makes this true in every case it has) |
| `rerun_helps` | whether re-running would move things forward — false on conflicts, where a human has to decide |
| `repository` | `{name, branch?, head?, remote, uncommitted?}`. `head` is the full 40-char SHA. `remote` is always present and null when no origin exists — a forge slug (`owner/name`), not a URL |
| `units[]` | per-unit: `{name, version, tag, steps[], targets[]?}`. `targets` is present on status and carries the ordered target observations below |
| `problems[]` | `{code, message, remedy?, source?, unit?, target?}` — every refusal and blockage, with its `RK-*` code. `target`, when present, is the affected step id and makes that target's human row `✗` |
| `next[]` | the commands that would advance things, as data |
| `halt` | `{kind, sentence}` when the run halted |
| `attachments` | documents that travel with the run (a proposed release.toml, pub's validation text) |
| `diagnosis` | where evidence was written, on failed runs that acted |

`halt.kind` is one of `beforeActing`, `stoppedPartway`, `lostTrack`,
`unfixableByRerun`, or `actedAndUnfixable`. `beforeActing` means no public
target changed; a native preflight such as `dart pub login` may still have
refreshed local session state. The accompanying sentence states what changed
and whether re-running can advance the work.

## Steps

Keyed by frozen `id` (treat ids as opaque tokens; `kind` is the stable
dimension for dashboards). Fields: `id`, `kind`, `summary`, `verdict`,
`permanent?`, `public?`, `needs[]`, `detail?`, `evidence?`, `took_ms?`, and
optional `action` during `release`.

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
  `mode` and the step's `detail` for why.

## The gate rule

For CI gating on `rk status --json`, the blessed rule is all three of:

1. `problems` is empty. Public conflicts and unread targets are recorded here
   as actionable diagnostics as well as on their target observations, so this
   catches the human report's `Issues` section without parsing prose. Any
   concrete problem carrying `target` also makes that target's human row `✗`.
2. No step has `verdict == "conflict"` — belt to problems' braces.
3. `unknown` never auto-proceeds. Under `mode.offline` no destination is
   ever `exact`: every one rk did not read answers `unknown`, and the
   local half of the tag — created but not known to be pushed — answers
   `unknown` too. A tag git does not hold is `absent`, which is work
   remaining, not work done. So an offline document gates nothing: every
   registry step is unknown, and unknown blocks.

## Status targets

Each `units[].targets[]` entry is the settled observation used to print the
human `Targets` section: `id`, `kind`, `label`, `coordinate`, `current_known`,
`current_version`, `target_version`, `verdict`, optional `detail`, optional
`uses`, and `artifacts[]`. `uses` refers to an artifact inventoried under
another target without duplicating it. An artifact is
`{name, status, problem?}`, where `status` is
`notStaged`, `staged`, or `invalid`. These are stage facts, not release
lifecycle states; public state remains the four-value `verdict` above.
Authentication does not add a fifth verdict or another green/unknown field.
Supported safe read-only checks may contribute a concrete target-linked
problem. When no safe check exists, status emits no authentication fact and
normal release preflight owns the check.

Exit codes (also in `-h`): `0` a successful report or completed command;
`1` refused or failed; `2` usage; `3` rk itself crashed. A requested JSON run
still writes one final report on exit `3`, including the diagnosis pointer when
rk may have acted; the diagnosis directory holds the detailed evidence.
