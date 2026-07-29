import 'dart:convert';
import 'dart:io';

import 'package:rk/src/transforms/digest.dart';
import 'package:test/test.dart';

void main() {
  group('SHA-256 against the published vectors', () {
    for (final entry in {
      '': 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      'abc':
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq':
          '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
    }.entries) {
      test('"${entry.key.length > 20 ? '${entry.key.substring(0, 20)}…' : entry.key}"',
          () {
        expect(Sha256.hex(utf8.encode(entry.key)), entry.value);
      });
    }

    test('a million a\'s', () {
      expect(
        Sha256.hex(utf8.encode('a' * 1000000)),
        'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0',
      );
    });
  });

  test('agrees with the system tool on real bytes', () async {
    final directory = await Directory.systemTemp.createTemp('rk_sha');
    addTearDown(() => directory.delete(recursive: true));

    // Bytes with a length that exercises padding across a block boundary.
    final bytes = List<int>.generate(3000, (i) => (i * 31) % 256);
    final file = File('${directory.path}/blob');
    await file.writeAsBytes(bytes);

    final result = await Process.run('shasum', ['-a', '256', file.path]);
    final expected = (result.stdout as String).split(' ').first;

    expect(Sha256.hex(bytes), expected);
  });

  test('SHA256SUMS is the format shasum -c reads', () async {
    final directory = await Directory.systemTemp.createTemp('rk_sums');
    addTearDown(() => directory.delete(recursive: true));

    final assets = {
      'keybay-0.2.0-macos-arm64.tar.gz': utf8.encode('one'),
      'keybay-0.2.0-linux-x64.tar.gz': utf8.encode('two'),
    };
    for (final entry in assets.entries) {
      await File('${directory.path}/${entry.key}').writeAsBytes(entry.value);
    }
    await File('${directory.path}/SHA256SUMS')
        .writeAsString(Checksums.render(assets));

    final checked = await Process.run(
      'shasum',
      ['-c', 'SHA256SUMS'],
      workingDirectory: directory.path,
    );
    expect(checked.exitCode, 0, reason: checked.stderr as String);
    expect((checked.stdout as String), contains('OK'));
  });
}
