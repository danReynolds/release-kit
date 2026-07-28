# rk

An austere, fail-closed release tool. rk is a checklist compiler: it reads
what native manifests already say plus one small `release.toml` of intent,
derives the complete ordered checklist for a release, and executes it —
validating everything before acting, inspecting reality before every step so
re-running is always safe, and refusing to guess.

rk manages the release steps and defers authentication to the native tools
that own it (`dart pub`, `codesign`, `notarytool`, `gh`, `git`). Provider-side
scopes — trusted publishing, scoped credentials, protected environments, tag
rules — are the policy engine; rk sets them up correctly and verifies them
relentlessly.

Four verbs: `check`, `run`, `verify`, `setup`. No hooks, no templates, no
`--force`.

Status: pre-implementation. The design is
[RFC 0002](doc/rfcs/0002-rk-core.md); the threat catalog and assurance
ladder it prices against is [RFC 0001](doc/rfcs/0001-rk-secure-release-compiler.md).

Initial scope: Dart packages and Dart CLIs (macOS/Linux) publishing to
pub.dev, GitHub Releases, and Homebrew. Dogfood fleet: keybay, then fleury.
