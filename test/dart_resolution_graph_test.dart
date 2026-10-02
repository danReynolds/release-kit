import 'dart:convert';

import 'package:rk/src/native/dart/resolution_graph.dart';
import 'package:test/test.dart';

const _digest =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _otherDigest =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

DartResolutionGraph _graph({
  String digest = _digest,
  String registry = 'https://pub.dev',
  String version = '0.2.0',
  List<String> dependencies = const [],
  List<String> extraNodes = const [],
  Map<String, String> aliases = const {},
}) => DartResolutionGraph.parse(
  jsonEncode({
    'configVersion': 1,
    'roots': ['app'],
    'packages': [
      {
        'name': 'app',
        'version': '0.1.0',
        'dependencies': ['core'],
        'devDependencies': [],
      },
      {'name': 'core', 'version': version, 'dependencies': dependencies},
      for (final name in extraNodes)
        {'name': name, 'version': '1.0.0', 'dependencies': []},
    ],
  }),
  '''
packages:
  core:
    source: hosted
    version: $version
    description:
      name: core
      url: $registry
      sha256: $digest
''',
  registryAliases: aliases,
);

void main() {
  test('discovery source aliases map back to original native identity', () {
    final discovery = _graph(
      registry: 'http://127.0.0.1:4000',
      digest: _otherDigest,
      aliases: {'http://127.0.0.1:4000': 'https://pub.dev'},
    );
    final replay = _graph();
    replay.requireSameSelection(discovery);
    replay.requireArchives({'core': _digest});
    expect(() => replay.requireSameArtifacts(discovery), throwsStateError);
  });

  test('same name and version cannot hide a different registry or edge', () {
    final frozen = _graph();
    expect(
      () => _graph(
        registry: 'https://another.example',
      ).requireSameSelection(frozen),
      throwsStateError,
    );
    expect(
      () => _graph(dependencies: ['app']).requireSameSelection(frozen),
      throwsStateError,
    );
  });

  test('post-production verification includes all archive digests', () {
    expect(
      () => _graph(digest: _otherDigest).requireSameArtifacts(_graph()),
      throwsStateError,
    );
    expect(
      () => _graph().requireArchives({'core': _otherDigest}),
      throwsStateError,
    );
    expect(
      () => _graph().requireArchives({'missing': _digest}),
      throwsStateError,
    );
  });

  test('missing edges, unsupported schemas and malformed digests refuse', () {
    expect(() => _graph(dependencies: ['missing']), throwsFormatException);
    expect(() => _graph(digest: 'not-a-hash'), throwsFormatException);
    expect(() => _graph(extraNodes: ['unlocked']), throwsFormatException);
    expect(
      () => DartResolutionGraph.parse('{"configVersion":2}', 'packages: {}'),
      throwsFormatException,
    );
  });

  test(
    'reports expose opaque source identities rather than credential URLs',
    () {
      final graph = _graph(registry: 'https://user:secret@example.test');
      expect(jsonEncode(graph.toJson()), isNot(contains('secret')));
      expect(graph.packages['core']!.source, startsWith('hosted:'));
    },
  );
}
