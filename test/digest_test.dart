import 'dart:io';
import 'dart:typed_data';

import 'package:rk/src/transforms/digest.dart';
import 'package:test/test.dart';

void main() {
  test('file digests preserve every byte across chunk boundaries', () {
    final root = Directory.systemTemp.createTempSync('rk-file-digest-');
    addTearDown(() => root.deleteSync(recursive: true));
    final file = File('${root.path}/artifact');
    for (final size in [0, 1, 65535, 65536, 65537, 2 * 1024 * 1024 + 13]) {
      final bytes = Uint8List.fromList([
        for (var i = 0; i < size; i++) (i * 31 + i ~/ 256) % 256,
      ]);
      file.writeAsBytesSync(bytes);
      expect(Sha256.file(file), (
        sha256: Sha256.hex(bytes),
        size: size,
      ), reason: '$size bytes');
    }
  });
}
