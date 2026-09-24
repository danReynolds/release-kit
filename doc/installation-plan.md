# Executable installation management

Implementation follows the approved matrix study in `codex/rk-use-designs`.

1. Resolve executable projects from this repository's release configuration and
   native manifests. Build the shared install/use/uninstall engine and prove
   local execution, grouped activation, collision refusal, and failure recovery.
2. Connect the Fleury source matrix to those real operations. Keep explicit
   invocations and JSON usable without a terminal.
3. Add native Homebrew and pub providers and verified GitHub archive installs.
4. Replace init's terminal selector with the Fleury output matrix, using the
   existing InitPlan and final write boundary. Selected outputs say “Added”.

## Contracts

- Commands require a containing `release.toml`; no global application picker.
- `-p` / `--project` selects a native package name. SDK-only packages are absent.
  A project with several commands is one installation and one selection.
- `install` prepares without selecting; `use` prepares when missing, then selects;
  `uninstall` removes exactly one inactive provider installation after review.
- Provider installation behavior is separate from release publication. The UI
  invokes the same coordinator as the direct CLI, with no provider logic in widgets.
- A stable managed bin directory contains owned command shims. One atomic
  per-project pointer changes all commands together. A failed preparation leaves
  the previous selection intact. Never overwrite someone else's executable.
- Local launchers refer to the chosen checkout, preserve the caller's working
  directory, and pick up source edits. Missing checkouts fail with recovery text;
  no fallback, automatic Git pull, or silent package upgrade.
- Installed state, selected state, and effective PATH resolution are distinct.
  Report shadowing honestly. Fish setup is tested with isolated home/config paths;
  development never alters the operator's real shell or installations.
- Init writes only after its validated configuration review. The other existing
  commands retain their ordinary text/progress output.

## Verification

Use fixture projects, private installation roots, fake provider processes, and
real Dart/fish child-process tests. Cover multi-command projects, spaces and shell
metacharacters in paths/arguments, failed installs, stale/moved checkouts, command
collisions, repeated operations, and concurrent mutations. Verify published
archive identity and safe extraction before making executable bytes selectable.
Live provider checks and fixture tests are reported separately.
