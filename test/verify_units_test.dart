import 'dart:convert';

import 'package:release_kit/src/commands/verify.dart';
import 'package:release_kit/src/engine/compare.dart';
import 'package:release_kit/src/engine/config.dart';
import 'package:release_kit/src/engine/diagnostic.dart';
import 'package:release_kit/src/engine/output.dart';
import 'package:release_kit/src/engine/resolve.dart';
import 'package:release_kit/src/engine/source_tree.dart';
import 'package:release_kit/src/engine/tools.dart';
import 'package:test/test.dart';

import 'status_test.dart' show FakeRegistry;

/// Multi-unit and mixed-channel verify behavior — three mutations of the unit
/// filter survived the phase 4 pass, and a mixed unit printed one bare check
/// mark having examined one channel of three.
void main() {
  const config = '''
schema = 1

[release.core]
path = "packages/keybay"
publish = ["pub.dev"]

[release.cli]
path = "packages/keybay_cli"
publish = ["pub.dev", "github-release", "homebrew"]
binary_platforms = ["macos-arm64"]
''';

  final sources = {
    'packages/keybay/pubspec.yaml': 'name: keybay\nversion: 0.2.0\n',
    'packages/keybay_cli/pubspec.yaml': '''
name: keybay_cli
version: 0.2.0
dependencies:
  keybay: 0.2.0
executables:
  keybay: keybay
''',
  };

  Future<({int code, String text, Map<String, Object?> report})> run({
    String? only,
    String? at,
    Map<String, SourceTree> refs = const {},
    FakeRegistry? registry,
  }) async {
    final buffer = StringBuffer();
    final diagnostics = Diagnostics();
    final parsed = ReleaseConfig.parse(config, 'release.toml', diagnostics)!;
    final resolution =
        Resolution.resolve(parsed, MemorySourceTree(sources), diagnostics)!;
    final output =
        Output(sink: buffer.write, isTerminal: false, useColor: false);
    final code = await VerifyCommand(
      resolution: resolution,
      registry: registry ?? FakeRegistry({}),
      comparator: Comparator(tools: const SystemTools()),
      treeAt: (ref) => refs[ref],
      output: output,
      at: at,
    ).run(only: only);
    return (
      code: code,
      text: buffer.toString(),
      report:
          jsonDecode(output.report.encode(exit: code)) as Map<String, Object?>,
    );
  }

  test('naming a unit verifies that unit alone', () async {
    final result = await run(only: 'core');
    expect(
      result.text,
      isNot(contains('keybay_cli')),
      reason: 'the filter was mutable to a no-op with nothing objecting',
    );
    expect((result.report['units'] as List), hasLength(1));
  });

  test('an unknown unit is a usage error, not a refusal', () async {
    final result = await run(only: 'nope');
    expect(result.code, ExitCodes.usage);
  });

  test('--at across several units is refused, naming the fix', () async {
    final result = await run(at: 'v0.1.0');
    expect(result.code, ExitCodes.usage);
    expect(
      (result.report['problems'] as List).map((p) => (p as Map)['code']),
      contains('RK-CLI-006'),
      reason: 'one ref cannot honestly name several units\' releases',
    );
    expect(result.text, contains('rk verify <unit> --at=v0.1.0'));
  });

  test('the reported tag is the ref actually used', () async {
    final result = await run(
      only: 'core',
      at: 'old-v0.2.0',
      refs: {
        'old-v0.2.0': MemorySourceTree(const {'README.md': 'not it\n'}),
      },
    );
    final unit = (result.report['units'] as List).single as Map;
    expect(
      unit['tag'],
      'old-v0.2.0',
      reason: 'naming the derived tag while comparing against --at would '
          'mislabel the provenance of the whole proof',
    );
  });

  test('a mixed unit names the channels it did not examine, both surfaces',
      () async {
    final result = await run(only: 'cli');
    expect(result.text, contains('github-release, homebrew'));
    expect(result.text, contains('not examined'));

    final unit = (result.report['units'] as List).single as Map;
    final disclosure = (unit['verifications'] as List)
        .cast<Map>()
        .firstWhere((v) => v['counts'] == false);
    expect(disclosure['verdict'], 'unknown');
    expect(
      disclosure['detail'],
      contains('cannot verify binary channels yet'),
      reason: 'a disclosure, not a judgment — and it must not fail what '
          'was actually proved',
    );
  });
}
