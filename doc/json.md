# The machine surface: `--json`

One complete JSON document on stdout, nothing else. It survives every
non-zero exit, is never truncated, and is written by the same calls that
print the human output, so the two surfaces cannot drift. Schema version
rides in `"rk"` and is bumped only when a key changes meaning.

## Top level

| key | meaning |
|---|---|
| `rk` | schema version (currently `1`) |
| `command` | the verb that ran |
| `mode` | how the run was asked to read: `{dry_run, offline, at?}`. An offline document's `unknown` verdicts are only interpretable with this beside them |
| `observed_at` | UTC ISO 8601 — when rk read the world |
| `exit` | mirrors the process exit code |
| `safe_to_rerun` | whether running the same command again can do harm (rk's model makes this true in every case it has) |
| `rerun_helps` | whether re-running would move things forward — false on conflicts, where a human has to decide |
| `repository` | `{name, branch?, head?, remote, uncommitted?}`. `head` is the full 40-char SHA. `remote` is always present and null when no origin exists — a forge slug (`owner/name`), not a URL |
| `units[]` | per-unit: `{name, version, tag, steps[], verifications[]?}` |
| `problems[]` | `{code, message, remedy?, source?, unit?}` — every refusal and blockage, with its `RK-*` code |
| `next[]` | the commands that would advance things, as data |
| `halt` | `{kind, sentence}` when the run halted |
| `attachments` | documents that travel with the run (a proposed release.toml, pub's validation text) |
| `diagnosis` | where evidence was written, on failed runs that acted |

## Steps

Keyed by frozen `id` (treat ids as opaque tokens; `kind` is the stable
dimension for dashboards). Fields: `id`, `kind`, `summary`, `verdict`,
`permanent?`, `public?`, `needs[]`, `detail?`, `evidence?`, `took_ms?`.

`verdict` is one of, frozen:

- `absent` — not there, from an authenticated negative. Work to do.
- `exact` — there, and it is what this configuration produces.
- `conflict` — there, and it differs. Re-running will not fix it.
- `unknown` — rk could not tell. **Never** collapsed into `absent`; read
  `mode` and the step's `detail` for why.

## The gate rule

For CI gating on `rk status --json`, the blessed rule is all three of:

1. `problems` is empty. Drift on a published release is recorded here as
   `RK-DRIFT-001` as well as on its step, so `problems` alone catches it.
2. No step has `verdict == "conflict"` — belt to problems' braces.
3. `unknown` never auto-proceeds. Under `mode.offline` every destination
   verdict is `unknown` by construction — local facts like the tag are
   still read from git — so an offline document gates nothing.

Exit codes (also in `-h`): `0` clean or complete — for `status`, blocked
counts, because reporting a blockage is a successful report; `1` refused
or failed; `2` usage; `3` rk itself crashed (no document was written;
`$?` is the only signal, and a diagnosis directory holds the evidence).

## Verifications (`rk verify`)

Per unit: `{id?, subject, verdict, counts, detail?, evidence?}`.
`counts: false` marks a disclosure — a subject named as unexamined, not
judged. A caller folding verifications into pass/fail skips those rows;
they never claimed to be proofs.
