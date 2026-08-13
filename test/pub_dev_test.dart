import 'package:rk/src/destinations/pub_dev.dart';
import 'package:rk/src/engine/compare.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/registry.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/engine/verdict.dart';
import 'package:rk/src/engine/version.dart';
import 'package:rk/src/transforms/archive.dart';
import 'package:rk/src/transforms/digest.dart';
import 'package:test/test.dart';

void main() {
  const files = {
    'pubspec.yaml': 'name: tool\nversion: 1.0.0\n',
    'lib/tool.dart': 'String value = "expected";\n',
    'CHANGELOG.md': '## 1.0.0\n\nFirst.\n',
  };

  List<int> archiveOf(Map<String, String> contents) => ArchiveBuilder.gzip(
        ArchiveBuilder.tar([
          for (final entry in contents.entries)
            ArchiveEntry(name: entry.key, bytes: entry.value.codeUnits),
        ]),
      );

  ResolvedProject project(SourceTree tree) {
    final diagnostics = Diagnostics();
    final config = ReleaseConfig.parse('''
schema = 2

[release.tool]
publish = ["git-tag", "pub.dev"]
''', 'release.toml', diagnostics)!;
    final resolution = Resolution.resolve(config, tree, diagnostics);
    expect(diagnostics.found, isEmpty);
    return resolution!.units.single.projects.single;
  }

  Future<Inspection> inspect({
    Map<String, String> source = files,
    Map<String, String>? archive,
    bool published = true,
    bool unavailable = false,
    bool tampered = false,
    bool allowCurrentSourceFallback = true,
    bool useExpectedSource = false,
  }) async {
    final tree = MemorySourceTree(source);
    final bytes = archiveOf(archive ?? files);
    final registry = _Registry(
      bytes: bytes,
      published: published,
      unavailable: unavailable,
      tampered: tampered,
    );
    return PubDevTarget(
      registry: registry,
      comparator: Comparator(tools: const SystemTools()),
      source: tree,
      allowCurrentSourceFallback: allowCurrentSourceFallback,
    ).inspectProject(
      project(tree),
      expectedSource: useExpectedSource ? tree : null,
    );
  }

  test('a listed version is exact only after its archive byte-matches source',
      () async {
    final result = await inspect();
    expect(result.verdict, Verdict.exact, reason: result.detail);
    expect(result.detail, contains('byte-identical'));
    expect(result.evidence, contains('archive sha256'));
  });

  test('the right version serving the wrong source is a conflict', () async {
    final result = await inspect(archive: {
      ...files,
      'lib/tool.dart': 'String value = "other";\n',
    });
    expect(result.verdict, Verdict.conflict);
    expect(result.evidence['lib/tool.dart'], 'differs');
  });

  test('a digest mismatch is a conflict, not registry absence', () async {
    final result = await inspect(tampered: true);
    expect(result.verdict, Verdict.conflict);
    expect(result.detail, contains('stated digest'));
  });

  test('an unread archive is unknown, never absent', () async {
    final result = await inspect(unavailable: true);
    expect(result.verdict, Verdict.unknown);
  });

  test('a version that is not listed remains absent', () async {
    final result = await inspect(published: false);
    expect(result.verdict, Verdict.absent);
  });

  test('unbound comparison requires the current release stage', () async {
    final laterStatus = await inspect(allowCurrentSourceFallback: false);
    expect(laterStatus.verdict, Verdict.unknown);
    expect(laterStatus.detail, contains('unbound release stage'));

    final sameRelease = await inspect(
      allowCurrentSourceFallback: false,
      useExpectedSource: true,
    );
    expect(sameRelease.verdict, Verdict.exact);
  });
}

class _Registry implements RegistryReader {
  _Registry({
    required this.bytes,
    required this.published,
    required this.unavailable,
    required this.tampered,
  });

  final List<int> bytes;
  final bool published;
  final bool unavailable;
  final bool tampered;

  @override
  Future<List<int>> archive(PublishedVersion version) async {
    if (unavailable) throw RegistryUnavailable('archive could not be read');
    if (tampered) {
      throw ArchiveTampered(stated: 'deadbeef', actual: Sha256.hex(bytes));
    }
    return bytes;
  }

  @override
  void forget(String name) {}

  @override
  Future<Inspection> inspect(String name, Version version) async =>
      published ? const Inspection.exact() : const Inspection.absent();

  @override
  Future<RegistryPackage?> lookup(String name) async {
    if (unavailable) throw RegistryUnavailable('pub.dev could not be read');
    return RegistryPackage(
      name: name,
      versions: published
          ? [
              PublishedVersion(
                version: Version.tryParse('1.0.0')!,
                published: DateTime.now().toUtc(),
                archiveUrl: 'https://example.invalid/tool.tar.gz',
                archiveSha256: Sha256.hex(bytes),
              ),
            ]
          : const [],
    );
  }
}
