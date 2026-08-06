import 'dart:convert';

import 'package:release_kit/src/commands/verify.dart';
import 'package:release_kit/src/engine/compare.dart';
import 'package:release_kit/src/engine/config.dart';
import 'package:release_kit/src/engine/diagnostic.dart';
import 'package:release_kit/src/output/output.dart';
import 'package:release_kit/src/engine/resolve.dart';
import 'package:release_kit/src/engine/source_tree.dart';
import 'package:release_kit/src/engine/tools.dart';
import 'package:release_kit/src/transforms/archive.dart';
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
  reviewRegressions();

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

/// Closeout regressions from the phase 4 independent reviews: eight mutations
/// of this verb survived, and two false definite negatives were proven live.
void reviewRegressions() {
  test('a quoted version is the version, not a different string', () async {
    final sources = {
      'packages/keybay/pubspec.yaml': 'name: keybay\nversion: "0.2.0"\n',
      'packages/keybay/lib/keybay.dart': 'void main() {}\n',
    };
    final registry = FakeRegistry({
      'keybay': ['0.2.0']
    })
      ..archives['keybay@0.2.0'] = _archiveOf(
        {
          'packages/keybay/pubspec.yaml': 'name: keybay\nversion: "0.2.0"\n',
          'packages/keybay/lib/keybay.dart': 'void main() {}\n',
        },
        under: 'packages/keybay/',
      );

    final run = await verify(
      registry: registry,
      working: sources,
      refs: {'v0.2.0': MemorySourceTree(sources)},
    );

    expect(
      run.code,
      ExitCodes.ok,
      reason: 'a hand-rolled version regex read the quotes as part of the '
          'version and declared a published release "not on pub.dev": '
          '${run.text}',
    );
  });

  test('a version with a trailing comment is still readable', () async {
    final sources = {
      'packages/keybay/pubspec.yaml':
          'name: keybay\nversion: 0.2.0 # released\n',
      'packages/keybay/lib/keybay.dart': 'void main() {}\n',
    };
    final registry = FakeRegistry({
      'keybay': ['0.2.0']
    })
      ..archives['keybay@0.2.0'] =
          _archiveOf(sources, under: 'packages/keybay/');

    final run = await verify(
      registry: registry,
      working: sources,
      refs: {'v0.2.0': MemorySourceTree(sources)},
    );
    expect(run.code, ExitCodes.ok, reason: run.text);
  });

  test('a manifest missing at the ref is RK-VER-002, refused', () async {
    final run = await verify(
      registry: FakeRegistry({
        'keybay': ['0.2.0']
      }),
      refs: {
        'v0.2.0': MemorySourceTree(const {'README.md': 'moved\n'})
      },
    );
    expect(run.code, ExitCodes.refused);
    expect(run.text, contains('no readable version at'));
  });

  test('the honest partial fails loudly: mark, problem, and no retry',
      () async {
    final sources = {
      ..._sources(),
      // A pattern rk refuses to guess at — the honest-partial path. A
      // .pubignore it understands now proves exact, which compare_test pins.
      'packages/keybay/.pubignore': 'doc/**\nweird\\#name\n',
      'packages/keybay/doc/internal.md': 'excluded on purpose\n',
    };
    final registry = FakeRegistry({
      'keybay': ['0.2.0']
    })
      ..archives['keybay@0.2.0'] =
          _archiveOf(_sources(), under: 'packages/keybay/');

    final run = await verify(
      registry: registry,
      working: _sources(),
      refs: {'v0.2.0': MemorySourceTree(sources)},
    );

    expect(run.code, ExitCodes.refused);
    expect(
      run.text,
      contains('✗'),
      reason: 'a failed run whose line carries no mark reads as a note',
    );
    expect(
      (run.report['problems'] as List).map((p) => (p as Map)['code']),
      contains('RK-VER-005'),
    );
    expect(
      run.report['rerun_helps'],
      false,
      reason: 'the .pubignore is part of the package; running again '
          'changes nothing',
    );
  });

  test('a conflict is terminal as data: problem, unit key, no retry', () async {
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

    final problems =
        (run.report['problems'] as List).cast<Map<String, Object?>>();
    expect(problems.map((p) => p['code']), contains('RK-VER-006'));
    expect(
      problems.firstWhere((p) => p['code'] == 'RK-VER-006')['unit'],
      'core',
      reason: 'attributable without parsing prose',
    );
    expect(run.report['rerun_helps'], false);
  });

  test('tampered bytes are terminal as data too', () async {
    final registry = FakeRegistry({
      'keybay': ['0.2.0']
    })
      ..archives['keybay@0.2.0'] = [1, 2, 3]
      ..tampered.add('keybay@0.2.0');

    final run = await verify(
      registry: registry,
      refs: {'v0.2.0': MemorySourceTree(_sources())},
    );

    expect(run.code, ExitCodes.refused);
    expect(
      (run.report['problems'] as List).map((p) => (p as Map)['code']),
      contains('RK-VER-004'),
    );
    expect(run.report['rerun_helps'], false);
  });

  test('the verification is keyed by the frozen step id', () async {
    final registry = FakeRegistry({
      'keybay': ['0.2.0']
    })
      ..archives['keybay@0.2.0'] =
          _archiveOf(_sources(), under: 'packages/keybay/');

    final run = await verify(
      registry: registry,
      refs: {'v0.2.0': MemorySourceTree(_sources())},
    );

    final unit = (run.report['units'] as List).single as Map;
    final verification = (unit['verifications'] as List)
        .cast<Map>()
        .firstWhere((v) => v['counts'] == true);
    expect(
      verification['id'],
      'core/pub.dev/keybay@0.2.0',
      reason: 'free prose was the "machine surface empty where a caller '
          'needs it" finding relocated',
    );
  });
}
