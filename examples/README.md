# Example repositories

Each directory is a repository *shape* rk must handle, written as real files
rather than as string literals inside a Dart test. Tests copy one into a
temporary directory, run `git init`, and run rk against it.

Real files, because rk reads files. The archiver picks up `LICENSE` and
`README.md` from disk; the changelog check reads `CHANGELOG.md`; the pubspec
reader has to cope with a folded description and a block sequence. A fixture
built from a `Map<String, String>` can be made to contain those, but nobody
reads it and nobody notices when it drifts from what a pubspec really looks
like.

| Directory | The shape it is |
|---|---|
| `single-package/` | One package at the root. pub.dev's convention gives it the bare `v{version}` tag. |
| `workspace-with-dependent/` | A workspace root and two packages, one pinned exactly to the other. Two units, so tags name their packages. |
| `multi-project-unit/` | Several packages released together under one declared tag. Declaration order is the reverse of publication order, so the order has to come from the manifests. |
| `escapes-repository/` | Built from sources the repository does not contain. **Must be refused** (`RK-DART-201`). |
| `binary-cli/` | Ships binaries for three platforms, with a real `LICENSE` and `README.md` for the archiver to carry. |

## Named for the shape, never for a real project

This is the rule that matters, and it is here because breaking it caused a
concrete failure.

These fixtures used to be called `keybay`, `fleury` and `dune`, after the
repositories rk is built for. That naming let the work be described as "tested
against the three repository shapes" and, eventually, as though rk had been run
against keybay — when what had been run was a hand-written caricature of it,
carrying a version number that turned out to be wrong. The first real run
against the actual repository found two bugs in the first minute.

So: no example is named after a real project, and none ever should be. A test
failure that says `escapes-repository` tells you what is being asserted. One
that says `dune` requires you to already know, and invites the belief that dune
itself was covered.

## What these cannot do

They prove rk handles a shape. They cannot prove rk handles a repository —
they contain only the cases someone thought to write down, which is the same
blind spot as the person who wrote them.

That is what `tool/validate.dart` is for: it runs rk against the real
repositories on this machine and records what came back. It asserts nothing,
because real repositories change. Its job is finding what the examples do not
contain.
