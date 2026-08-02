import 'dart:convert';

import 'package:rk/src/commands/verify.dart';
import 'package:rk/src/engine/compare.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/output.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/transforms/archive.dart';
import 'package:test/test.dart';

import 'status_test.dart' show FakeRegistry;

const _config = '''
schema = 1

[release.core]
path = "packages/keybay"
publish = ["pub.dev"]
''';

Map<String, String> _sources([String version = '0.2.0']) => {
      'packages/keybay/pubspec.yaml': 'name: keybay\nversion: $version\n',
      'packages/keybay/lib/keybay.dart': 'void main() {}\n',
      'packages/keybay/CHANGELOG.md': '## $version\n',
    };

List<int> _archiveOf(Map<String, String> files, {String under = ''}) =>
    ArchiveBuilder.gzip(ArchiveBuilder.tar([
      for (final entry in files.entries)
        if (under.isEmpty || entry.key.startsWith(under))
          ArchiveEntry(
            name: under.isEmpty ? entry.key : entry.key.substring(under.length),
            bytes: entry.value.codeUnits,
          ),
    ]));

Future<({int code, String text, Map<String, Object?> report})> verify({
  required FakeRegistry registry,
  Map<String, SourceTree> refs = const {},
  String? at,
  Map<String, String>? working,
}) async {
  final buffer = StringBuffer();
  final diagnostics = Diagnostics();
  final parsed = ReleaseConfig.parse(_config, 'release.toml', diagnostics)!;
  final resolution = Resolution.resolve(
    parsed,
    MemorySourceTree(working ?? _sources()),
    diagnostics,
  )!;

  final output = Output(sink: buffer.write, isTerminal: false, useColor: false);
  final code = await VerifyCommand(
    resolution: resolution,
    registry: registry,
    comparator: Comparator(tools: const SystemTools()),
    treeAt: (ref) => refs[ref],
    output: output,
    at: at,
  ).run();

  return (
    code: code,
    text: buffer.toString(),
    report:
        jsonDecode(output.report.encode(exit: code)) as Map<String, Object?>,
  );
}

void main() {
  test('a published archive matching the tree at the tag verifies', () async {
    final registry = FakeRegistry({
      'keybay': ['0.2.0']
    })
      ..archives['keybay@0.2.0'] =
          _archiveOf(_sources(), under: 'packages/keybay/');

    final run = await verify(
      registry: registry,
      refs: {'v0.2.0': MemorySourceTree(_sources())},
    );

    expect(run.code, ExitCodes.ok, reason: run.text);
    expect(run.text, contains('✓'));
    expect(run.text, contains('keybay 0.2.0'));
    expect(run.text, contains('byte-identical'));

    final unit = (run.report['units'] as List).single as Map;
    final verification = (unit['verifications'] as List).single as Map;
    expect(verification['verdict'], 'exact');
  });

  test('a difference is a conflict, named file by file', () async {
    final tampered = _sources();
    tampered['packages/keybay/lib/keybay.dart'] = 'tampered\n';
    final registry = FakeRegistry({
      'keybay': ['0.2.0']
    })
      ..archives['keybay@0.2.0'] =
          _archiveOf(tampered, under: 'packages/keybay/');

    final run = await verify(
      registry: registry,
      refs: {'v0.2.0': MemorySourceTree(_sources())},
    );

    expect(run.code, ExitCodes.refused);
    expect(run.text, contains('lib/keybay.dart  differs'));
    expect(
      run.text,
      contains('treat it as an incident'),
      reason: 'a difference that is not yours is not a formatting problem',
    );

    final unit = (run.report['units'] as List).single as Map;
    final verification = (unit['verifications'] as List).single as Map;
    expect(verification['verdict'], 'conflict');
    expect(
      (verification['evidence'] as Map)['lib/keybay.dart'],
      'differs',
      reason: 'the difference itself reaches the caller, not the fact of one',
    );
  });

  test('no tag means no provenance, said plainly, with the way out', () async {
    final run = await verify(
      registry: FakeRegistry({
        'keybay': ['0.2.0']
      }),
      refs: const {}, // v0.2.0 does not resolve
    );

    expect(run.code, ExitCodes.refused);
    expect(run.text, contains('nothing binds the published version'));
    expect(run.text, contains('--at='));
  });

  test('--at proves a release made under an older tag scheme', () async {
    final registry = FakeRegistry({
      'keybay': ['0.2.0']
    })
      ..archives['keybay@0.2.0'] =
          _archiveOf(_sources(), under: 'packages/keybay/');

    final run = await verify(
      registry: registry,
      refs: {'old-v0.2.0': MemorySourceTree(_sources())},
      at: 'old-v0.2.0',
    );

    expect(run.code, ExitCodes.ok, reason: run.text);
  });

  test('the version proved is the ref\'s claim, not the worktree\'s', () async {
    // The worktree moved on to 0.3.0; the tag still says 0.2.0, and 0.2.0 is
    // what is published, so 0.2.0 is what gets proved.
    final registry = FakeRegistry({
      'keybay': ['0.2.0']
    })
      ..archives['keybay@0.2.0'] =
          _archiveOf(_sources(), under: 'packages/keybay/');

    final run = await verify(
      registry: registry,
      working: _sources('0.3.0'),
      refs: {'v0.3.0': MemorySourceTree(_sources())},
    );

    expect(run.code, ExitCodes.ok, reason: run.text);
    expect(run.text, contains('keybay 0.2.0'));
  });

  test('a version that is not published has nothing to verify', () async {
    final run = await verify(
      registry: FakeRegistry({
        'keybay': ['0.1.0']
      }),
      refs: {'v0.2.0': MemorySourceTree(_sources())},
    );

    expect(run.code, ExitCodes.refused);
    expect(run.text, contains('0.2.0 is not on pub.dev'));
    expect(run.text, contains('published: 0.1.0'));
  });

  test('an unreachable registry proves nothing, and says so', () async {
    final run = await verify(
      registry: FakeRegistry({}, unreachable: true),
      refs: {'v0.2.0': MemorySourceTree(_sources())},
    );

    expect(run.code, ExitCodes.refused);
    expect(run.text, contains('could not be reached'));
    expect(
      run.text,
      isNot(contains('not on pub.dev')),
      reason: 'unreachable is not unpublished',
    );
  });
}
