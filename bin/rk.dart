import 'dart:io';

const _usage = '''
rk — an austere release tool

Usage: rk <command>

  check    Validate the release and show the derived checklist.
  run      Execute the checklist. Idempotent; safe to re-run.
  verify   Re-download published artifacts and compare.
  setup    Derive and verify provider-side registrations and secrets.

rk is pre-implementation. See doc/rfcs/0002-rk-core.md for the design.
''';

void main(List<String> args) {
  stderr.write(_usage);
  exitCode = 64;
}
