import 'package:rk/src/builds/macos_identity.dart';
import 'package:rk/src/engine/receipt.dart';
import 'package:rk/src/engine/stage.dart';
import 'package:test/test.dart';

/// A reused stage is published under the identity its signed build
/// recorded, which says whether this release claims it first.
void main() {
  Receipt receipt(Map<String, Map<String, Object?>> producers) => Receipt(
    stage: StageId.of(commit: '1' * 40, tree: '2' * 40, plan: const {}),
    plan: const {},
    producers: producers,
  );
  Map<String, Map<String, Object?>> signed(String? published) => {
    'archive:tool:macos-arm64': const {},
    'build:tool:macos-arm64': {
      'signature': {
        'code_id': 'io.example.tool',
        'certificate': 'Developer ID Application: A (TEAM123456)',
        'first_identity': published == null,
        'published_requirement': published,
      },
    },
    'notarize:tool:macos-arm64': const {'notary': 'Accepted'},
  };

  test('a later release reproduces the identity users installed', () {
    final identity = MacIdentity.recorded(
      receipt(signed('designated => identifier "io.example.tool"')),
    )!;
    expect(identity.codeId, 'io.example.tool');
    expect(identity.certificate, 'Developer ID Application: A (TEAM123456)');
    expect(identity.first, isFalse);
  });

  test('a first release claims it', () {
    expect(MacIdentity.recorded(receipt(signed(null)))!.first, isTrue);
  });

  test('a stage that signed nothing has no identity', () {
    expect(
      MacIdentity.recorded(
        receipt({
          'build:tool:linux-x64': const {
            'smoke': {'status': 'passed'},
          },
        }),
      ),
      isNull,
    );
  });
}
