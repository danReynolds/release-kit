import 'dart:io';

const _usage = '''
rk — an austere release tool

Usage: rk [command] [unit-or-tag]

  init      Write release.toml for this repository.
  status    Where things stand: live versions, local versions, what is ready.
  release   Execute a release.
  verify    Prove a published release against what it claims.

Bare `rk` runs status. See doc/rfcs/0002-rk-core.md for the design.
''';

void main(List<String> args) {
  stderr.write(_usage);
  exitCode = 2;
}
