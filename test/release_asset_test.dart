import 'package:release_kit/src/engine/release_asset.dart';
import 'package:test/test.dart';

void main() {
  test('staged paths are validated', () {
    for (final create in [
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
        () => ReleaseAssetSpec(stagedPath: path, publicName: 'tool.tar.gz'),
    ]) {
      expect(
          create, throwsA(anyOf(isA<ArgumentError>(), isA<FormatException>())));
    }
  });

  test('ordinary contributions cannot claim unsafe or reserved names', () {
    for (final name in [
      '',
      '.',
      '..',
      '../tool.tar.gz',
      'nested/tool.tar.gz',
      r'nested\tool.tar.gz',
      'tool\u007f.tar.gz',
      'release-manifest.json',
    ]) {
      expect(
        () => ReleaseAssetSpec(
          stagedPath: 'private/tool.tar.gz',
          publicName: name,
        ),
        throwsArgumentError,
        reason: name,
      );
    }
  });

  test('inventory is stable regardless of specification order', () {
    final a = ReleaseAssetSpec(
      stagedPath: 'private/a',
      publicName: 'a.tar.gz',
    );
    final b = ReleaseAssetSpec(
      stagedPath: 'private/b',
      publicName: 'b.tar.gz',
    );
    final c = ReleaseAssetSpec(
      stagedPath: 'private/c',
      publicName: 'c.tar.gz',
    );

    expect(
      validateReleaseAssetSpecs([c, a, b]).map((asset) => asset.publicName),
      ['a.tar.gz', 'b.tar.gz', 'c.tar.gz'],
    );
    expect(
      validateReleaseAssetSpecs([b, c, a]).map((asset) => asset.publicName),
      ['a.tar.gz', 'b.tar.gz', 'c.tar.gz'],
    );
  });

  test('same and destination-equivalent public names always collide', () {
    expect(
      () => validateReleaseAssetSpecs([
        ReleaseAssetSpec(
          stagedPath: 'private/one',
          publicName: 'tool.tar.gz',
        ),
        ReleaseAssetSpec(
          stagedPath: 'private/two',
          publicName: 'tool.tar.gz',
        ),
      ]),
      throwsArgumentError,
    );
    expect(
      () => validateReleaseAssetSpecs([
        ReleaseAssetSpec(
          stagedPath: 'private/upper',
          publicName: 'Tool.tar.gz',
        ),
        ReleaseAssetSpec(
          stagedPath: 'private/lower',
          publicName: 'tool.tar.gz',
        ),
      ]),
      throwsArgumentError,
    );
  });

  test('zero contributions produce an immutable empty inventory', () {
    final inventory = validateReleaseAssetSpecs(const []);
    expect(inventory, isEmpty);
    expect(
      () => inventory.add(
        ReleaseAssetSpec(
          stagedPath: 'private/tool',
          publicName: 'tool',
        ),
      ),
      throwsUnsupportedError,
    );
  });
}
