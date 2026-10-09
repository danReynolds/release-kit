import 'package:rk/src/targets/pub_dev/client.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/registry.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/verdict.dart';
import 'package:rk/src/engine/version.dart';
import 'package:test/test.dart';

void main() {
  const source = {
    'pubspec.yaml': 'name: tool\nversion: 1.0.0\n',
    'CHANGELOG.md': '## 1.0.0\n\nFirst.\n',
  };

  ResolvedProject project() {
    final diagnostics = Diagnostics();
    final config = ReleaseConfig.parse(
      '''
schema = 2

[release.tool]
publish = ["git-tag", "pub.dev"]
''',
      'release.toml',
      diagnostics,
    )!;
    final resolution = Resolution.resolve(
      config,
      MemorySourceTree(source),
      diagnostics,
    );
    expect(diagnostics.found, isEmpty);
    return resolution!.units.single.projects.single;
  }

  Future<Inspection> inspect({
    String? registrySha256 = _a,
    String? stagedSha256,
  }) => PubDevTarget(
    registry: _Registry(archiveSha256: registrySha256),
  ).inspectProject(project(), expectedArchiveSha256: stagedSha256);

  test(
    'the staged native archive is verified by the registry digest',
    () async {
      final result = await inspect(stagedSha256: _a);

      expect(result.verdict, Verdict.exact);
      expect(result.evidence['comparison'], 'exact');
      expect(result.evidence['archive'], 'sha256:$_a');
    },
  );

  test(
    'the right version with a different known digest is a conflict',
    () async {
      final result = await inspect(stagedSha256: _b);

      expect(result.verdict, Verdict.conflict);
      expect(result.evidence['archive'], contains(_a));
      expect(result.evidence['archive'], contains(_b));
    },
  );

  test('a listed version is published, whatever a stage holds', () async {
    // Before rk acts, the version is the registry's truth: no archive is
    // compared, so a re-packed stage cannot make a published version a
    // conflict.
    final result = await inspect(registrySha256: _b);

    expect(result.verdict, Verdict.exact);
    expect(result.detail, startsWith('published'));
    expect(result.evidence, isNot(contains('comparison')));
  });

  test('a missing provider digest also skips without provenance', () async {
    final result = await inspect(stagedSha256: _a, registrySha256: null);

    expect(result.verdict, Verdict.exact);
    expect(result.evidence['comparison'], 'unavailable');
  });
}

/// pub.dev with version 1.0.0 published, and [archiveSha256] its digest.
class _Registry implements RegistryReader {
  _Registry({required this.archiveSha256});

  final String? archiveSha256;

  @override
  Future<RegistryPackage?> lookup(String name) async => RegistryPackage(
    name: name,
    versions: [
      PublishedVersion(
        version: Version.tryParse('1.0.0')!,
        published: DateTime.now().toUtc(),
        archiveSha256: archiveSha256,
      ),
    ],
  );

  @override
  Future<PublishedVersion?> lookupVersion(String name, Version version) async =>
      (await lookup(name))?.at(version);

  @override
  void forget(String name) {}
}

const _a = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _b = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
