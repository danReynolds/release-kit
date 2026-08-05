/// rk — an austere release tool.
///
/// This library exports nothing: rk is a command-line program, not a package
/// you import. It exists because the published package renders this file as
/// its API page, and a reader who lands here should be told where to go.
///
/// The program is `bin/rk.dart`, which is also the composition root — a run
/// begins in its `_prepare`, where the repository is found, `release.toml` is
/// read and resolved, and the collaborators are built.
///
/// The machine surface — the `--json` document, its schema, and the CI gate
/// rule — is documented in `doc/json.md`. The design is `doc/rfcs/0002-rk-core.md`.
library;
