# Initialization, targets, and release artifacts

Status: implemented and validated, 2026-08-12.

This record captures the decisions behind schema 2, `rk init`, optional Git,
aggregate GitHub Releases, and Homebrew formula bindings. RFC 0002 owns
the complete release protocol; this document records the narrower product
choices and review outcomes that produced the implementation.

## Product goal

rk is an austere release manager:

- native project manifests own package identity, contents, and registry
  policy;
- `release.toml` contains only release intent native tools cannot answer;
- init discovers facts and offers release choices, but is not a field editor;
- omitted intent is not guessed; and
- safety machinery stays internal rather than becoming configuration.

The three relevant concepts remain distinct:

1. A producer creates a private staged output.
2. A release-asset specification deliberately gives one output a public
   filename.
3. A target publishes exact inputs and reads them back.

GitHub Release therefore aggregates explicit release assets. It does not own
binary production or upload arbitrary build directories. Homebrew owns its
formula; the formula is not duplicated into GitHub.

## Configuration

Schema 2 replaces schema 1 without a compatibility layer. This is a pre-alpha
contract change.

The public vocabulary is intentionally small:

- `publish` selects built-in targets;
- `path` locates a native project;
- `tag` overrides an otherwise unambiguous tag pattern;
- `binary_platforms` enables the current standalone Dart CLI producer for a
  project; and
- `homebrew_tap` overrides the conventional tap coordinate for a unit.

There is no generic `produce`, `code_id`, credential, provider option, or
artifact-list configuration.

### Single project

```toml
schema = 2

[release.rk]
publish = ["git-tag", "pub.dev", "github-release"]
binary_platforms = ["macos-arm64", "linux-x64", "linux-arm64"]
```

The table is both the release unit and its single project. Unit-scoped targets
(`git-tag`, `github-release`) and project-scoped targets (`pub.dev`,
`homebrew`) share one `publish` list because their attachment is unambiguous.

### Several projects in one release

```toml
schema = 2

[release.tools]
publish = ["git-tag", "github-release"]

[[release.tools.project]]
path = "packages/server_cli"
publish = ["pub.dev", "homebrew"]
binary_platforms = ["macos-arm64", "linux-x64"]

[[release.tools.project]]
path = "packages/admin_cli"
publish = ["pub.dev"]
binary_platforms = ["macos-arm64", "linux-x64"]
```

Both projects contribute archives to one GitHub Release. Only `server_cli`
publishes a Homebrew formula. Producer steps, paths, receipts, signing state,
and signing state are qualified by project before public-name collision
checks.

### Sparse Homebrew override

The conventional tap is `owner/homebrew-tap`. A deliberate alternative uses
one unit setting:

```toml
[release.tool]
homebrew_tap = "owner/homebrew-internal"
```

Homebrew has no project-owned config file that can declare this repository
coordinate. The override therefore belongs to release intent, not the Dart
manifest. It is rejected unless the unit publishes a Homebrew project.

## Target rules

Target descriptors own scope, prerequisites, Git requirements, and lifecycle
kind. These are built-in implementation facts, not TOML extension points.

| Target | Scope | Requires Git | Notes |
|---|---|---:|---|
| `git-tag` | unit | yes | explicit and optional |
| `pub.dev` | project | no | native Dart package publication |
| `github-release` | unit | yes | aggregates release assets; may be metadata-only |
| `homebrew` | project | yes | consumes one standalone archive contract |

Within a unit, public work remains ordered by dependencies:

1. Git tag, when selected;
2. registry publications in native dependency order;
3. GitHub Release; and
4. Homebrew.

Omitted targets disappear from the graph. There is no configurable target
ordering surface.

## Initialization

`rk init` builds a pure plan from static repository and native-manifest facts.
It never runs repository code, contacts a network, refreshes credentials, or
edits an existing config.

### Conservative defaults

- A releasable public Dart package may start with pub.dev selected.
- A sole unambiguous releasable unit may start with Git tag selected.
- Several releasable packages receive no default per-package tags.
- Executables expose standalone capability but do not select Binary, GitHub,
  or Homebrew.
- Examples, fixtures, workspace grouping roots, private packages, and custom
  registry packages remain visible with a reason and start unselected.
- Non-Git discovery follows only the root native manifest and declared native
  workspace membership.

### Selector

With a capable terminal, init shows one row per discovered project and these
on/off choices:

```text
Binary  Git tag  pub.dev  GitHub  Homebrew
```

Arrow keys move, Space toggles, Enter reviews, and Ctrl-C or EOF cancels.
The selector bounds itself to terminal height, truncates long display names,
and restores cursor and terminal modes on every exit.

Dependencies are deterministic:

- Binary enables GitHub and Git tag.
- GitHub enables Git tag.
- Homebrew enables Binary, GitHub, and Git tag.
- Removing a prerequisite removes its dependants.
- A project is included exactly when at least one publication target is
  selected.

Review previews the exact schema-2 TOML and `.gitignore` addition. Back returns
to selection. Writing uses exclusive creation and refuses a concurrent config
or `.gitignore` change.

Without a usable TTY, init prints the conservative proposal and writes
nothing. `rk init --write` accepts that proposal. `rk init --json` reports the
same candidates, availability, reasons, selection, and dependency effects.

Generated TOML is parsed and resolved through the production path before it
is shown.

## Release assets

The current Dart standalone producer declares private staged outputs and
their deliberate public projections. A release asset records:

- producer and project identity;
- private stage path;
- semantic type and media type;
- optional platform; and
- exact public filename.

Bundle assembly validates the complete specification before publication:

- private paths must remain inside the stage;
- public names must be one safe filename;
- reserved names belong only to rk;
- case-equivalent public names collide;
- several projects cannot claim the same public name; and
- Homebrew formulas cannot also be release assets.

`release-manifest.json` is always present on a selected GitHub Release and
records the size and SHA-256 digest of every public asset. A metadata-only
release therefore carries release notes and the manifest only.

The manifest records public release assets separately from Homebrew formulas.
It never exposes private stage paths, commands, logs, credentials, or
free-form receipt evidence.

## Homebrew

Each Homebrew project produces one formula from its standalone archive
contract. The formula is a private stage output published only to
`Formula/<executable>.rb` in the selected tap.

The release manifest binds each formula's:

- project;
- tap;
- formula path;
- size and SHA-256 digest.

This lets status authenticate current or historical tap bytes through:

```text
annotated Git tag -> GitHub release manifest -> formula digest -> tap bytes
```

The private stage path stays only in the terminal receipt. A public tap path
may be owned by exactly one project.

## GitHub Release

GitHub publication freezes title, notes, manifest digest, and exact managed
asset inventory before authorization.

Retry behavior is fail-closed:

- an exact published release is skipped;
- an exact draft prefix is adopted and resumed;
- any different or ambiguous same-tag draft is refused;
- local paths and digests are validated before remote mutation; and
- rk never deletes an ambiguous draft to make progress.

Read-back compares tag, title, body, state, manifest, inventory, and exact
asset bytes. A provider success response is not proof of completion.

## Optional Git and source evidence

Git is required only by targets that name Git coordinates. A pub.dev-only
project can release from a non-Git source root.

Git-bound stages record commit and tree identity and may be reused when their
complete receipt remains exact. Unbound stages:

- record no commit or invented directory hash;
- bind the exact captured source and produced bytes;
- may complete a one-shot release in the creating invocation; and
- cannot be handed to another invocation with `--stage`.

Destination state and source comparison remain independent. A registry can be
exact while source comparison is unavailable; status reports both facts.

## Credentials and destinations

Native tools own credentials. rk never reads or serializes secrets.

Release sequencing is:

1. run safe ambient readiness checks;
2. build and validate the complete private stage without publication
   credentials;
3. refresh public target observations;
4. acquire or refresh native publication sessions;
5. verify the effective destination still matches the pre-stage baseline;
6. obtain version-specific authorization; and
7. publish and read back each target.

`status` and `release --stage` never acquire publication sessions. Custom or
ambient Dart registry redirection is not mislabeled as pub.dev, and diagnostic
output does not echo credential-bearing coordinates.

## Review outcomes

Three review perspectives challenged the design: current Dart DX, future
producer/ecosystem extension, and release-operator safety. The material
changes were:

- remove generic `produce` and `code_id` configuration;
- make Git tagging explicit and conditional;
- require explicit tag namespaces when several tagged units exist;
- preserve concrete target identity alongside lifecycle kind;
- qualify producer state by project;
- separate public assets from Homebrew formula bytes;
- support metadata-only GitHub Releases;
- reject destructive GitHub draft recovery;
- make source binding independent from destination exactness; and
- move credentials after complete private staging.

The implementation remains concrete to the current Dart producer. A second
real producer should introduce an internal adapter seam based on its actual
requirements; schema 2 does not expose a speculative producer/plugin model.

## Dogfood and proof

Read-only initialization was exercised against real repository snapshots:

- release-kit selected its root pub.dev package and sole unambiguous tag while
  leaving standalone binaries opt-in;
- Keybay selected its library and CLI pub.dev packages without guessing
  separate tags; and
- Fleury selected its public packages without treating executable declarations
  as standalone distribution intent.

A real Keybay PTY run selected Homebrew, observed the Binary/GitHub/Git-tag
cascade, reviewed the proposal, and cancelled without writing. That run found
and led to fixes for long names and large-workspace viewport behavior.

The automated contract covers:

- generated TOML parsing and resolution;
- selector dependencies and terminal cleanup;
- target scope and tag collisions;
- multi-project producer qualification and public-name collisions;
- metadata-only releases;
- GitHub interruption and recovery points;
- Homebrew manifest/tap binding;
- Git-bound and unbound source behavior;
- stage tampering and lost-stage refusal;
- destination drift and credential timing; and
- idempotent public read-back.

Live publication remains a separately authorized production gate.
