import 'package:release_kit/src/engine/artifact_contribution.dart';
import 'package:release_kit/src/engine/stage_receipt.dart';
import 'package:test/test.dart';

ProducedBlobRef ref(
  String path, {
  String producer = 'cli',
  String type = 'standalone_archive',
}) =>
    ProducedBlobRef(
      producerId: producer,
      stagedPath: path,
      type: type,
      mediaType: 'application/gzip',
      platform: 'linux-x64',
      project: 'example_cli',
    );

ProducedBlob blob(String path, {String producer = 'cli'}) {
  final planned = ref(path, producer: producer);
  return ProducedBlob(
    ref: planned,
    artifact: StageArtifact(
      path: path,
      type: planned.type,
      mode: '0644',
      size: 12,
      sha256: 'a' * 64,
    ),
  );
}

ReleaseAssetContribution contribution(String path, String publicName) {
  final produced = blob(path);
  return ReleaseAssetContribution(
    spec: ReleaseAssetSpec(blob: produced.ref, publicName: publicName),
    blob: produced,
  );
}

void main() {
  test('a produced blob binds its plan to exact captured bytes', () {
    final produced = blob('private/cli/linux-x64/tool.tar.gz');

    expect(produced.producerId, 'cli');
    expect(produced.stagedPath, 'private/cli/linux-x64/tool.tar.gz');
    expect(produced.type, 'standalone_archive');
    expect(produced.size, 12);
    expect(produced.sha256, 'a' * 64);
    expect(produced.mediaType, 'application/gzip');
    expect(produced.platform, 'linux-x64');
    expect(produced.project, 'example_cli');
  });

  test('planned identity, paths, and media types are validated', () {
    for (final create in [
      () => ref('tool.tar.gz', producer: 'CLI'),
      () => ref('tool.tar.gz', producer: 'cli/one'),
      () => ProducedBlobRef(
            producerId: 'cli',
            stagedPath: 'tool.tar.gz',
            type: 'standalone_archive',
            mediaType: 'Application/Gzip',
          ),
      () => ProducedBlobRef(
            producerId: 'cli',
            stagedPath: 'tool.tar.gz',
            type: 'standalone_archive',
            mediaType: 'application/gzip',
            platform: '../linux',
          ),
      for (final path in [
        '',
        '/tool.tar.gz',
        '../tool.tar.gz',
        'private/../tool.tar.gz',
        'private/./tool.tar.gz',
        'private//tool.tar.gz',
        r'private\tool.tar.gz',
        'C:/tool.tar.gz',
        'private/\u0000tool.tar.gz',
      ])
        () => ref(path),
    ]) {
      expect(
          create, throwsA(anyOf(isA<ArgumentError>(), isA<FormatException>())));
    }
  });

  test('captured bytes must be the planned output', () {
    final planned = ref('private/tool.tar.gz');
    expect(
      () => ProducedBlob(
        ref: planned,
        artifact: StageArtifact(
          path: 'private/other.tar.gz',
          type: planned.type,
          mode: '0644',
          size: 1,
          sha256: 'a' * 64,
        ),
      ),
      throwsArgumentError,
    );
  });

  test('ordinary contributions cannot claim unsafe or reserved names', () {
    final planned = ref('private/tool.tar.gz');
    for (final name in [
      '',
      '.',
      '..',
      '../tool.tar.gz',
      'nested/tool.tar.gz',
      r'nested\tool.tar.gz',
      'tool\u007f.tar.gz',
      'SHA256SUMS',
      'release-manifest.json',
    ]) {
      expect(
        () => ReleaseAssetSpec(blob: planned, publicName: name),
        throwsArgumentError,
        reason: name,
      );
    }
  });

  test('only the checksum assembler may claim its reserved name', () {
    final generated = ReleaseAssetSpec.generated(
      blob: ref('bundle/SHA256SUMS', producer: 'bundle', type: 'checksums'),
      publicName: 'SHA256SUMS',
    );
    expect(generated.publicName, 'SHA256SUMS');
    expect(
      () => ReleaseAssetSpec.generated(
        blob: generated.blob,
        publicName: 'release-manifest.json',
      ),
      throwsArgumentError,
    );
  });

  test('aggregation is stable regardless of contribution order', () {
    final a = contribution('private/a', 'a.tar.gz');
    final b = contribution('private/b', 'b.tar.gz');
    final c = contribution('private/c', 'c.tar.gz');

    expect(
      aggregateReleaseAssets([c, a, b]).map((asset) => asset.publicName),
      ['a.tar.gz', 'b.tar.gz', 'c.tar.gz'],
    );
    expect(
      aggregateReleaseAssets([b, c, a]).map((asset) => asset.publicName),
      ['a.tar.gz', 'b.tar.gz', 'c.tar.gz'],
    );
  });

  test('same and destination-equivalent public names always collide', () {
    expect(
      () => aggregateReleaseAssets([
        contribution('private/one', 'tool.tar.gz'),
        contribution('private/two', 'tool.tar.gz'),
      ]),
      throwsArgumentError,
    );
    expect(
      () => validateReleaseAssetSpecs([
        ReleaseAssetSpec(blob: ref('private/upper'), publicName: 'Tool.tar.gz'),
        ReleaseAssetSpec(blob: ref('private/lower'), publicName: 'tool.tar.gz'),
      ]),
      throwsArgumentError,
    );
  });

  test('zero contributions produce an immutable empty inventory', () {
    final inventory = aggregateReleaseAssets(const []);
    expect(inventory, isEmpty);
    expect(
      () => inventory.add(contribution('private/tool', 'tool')),
      throwsUnsupportedError,
    );
  });
}
