import 'dart:convert';
import 'dart:io';

import 'package:rk/src/engine/atomic_file.dart';
import 'package:rk/src/engine/receipt.dart';
import 'package:rk/src/engine/stage.dart';
import 'package:test/test.dart';

const _commit = '1111111111111111111111111111111111111111';
const _tree = '2222222222222222222222222222222222222222';

void main() {
  group('stage id', () {
    test('canonical plan order does not change the id', () {
      final left = _id({
        'unit': 'rk',
        'targets': ['pub.dev', 'github'],
        'build': {'platform': 'macos-arm64', 'toolchain': 'dart-3.9'},
      });
      final right = _id({
        'build': {'toolchain': 'dart-3.9', 'platform': 'macos-arm64'},
        'targets': ['pub.dev', 'github'],
        'unit': 'rk',
      });

      expect(left.id, right.id);
      expect(left.planSha256, right.planSha256);
      expect(left.id, hasLength(64));
    });

    test('commit, tree, and any plan input change the id', () {
      final baseline = _id({'toolchain': 'dart-3.9'});
      final commit = StageId.of(
        commit: '3' * 40,
        tree: _tree,
        plan: const {'toolchain': 'dart-3.9'},
      );
      final tree = StageId.of(
        commit: _commit,
        tree: '4' * 40,
        plan: const {'toolchain': 'dart-3.9'},
      );
      final plan = _id({'toolchain': 'dart-3.10'});

      expect({baseline.id, commit.id, tree.id, plan.id}, hasLength(4));
    });

    test('a recorded id is derived again from what it names', () {
      final id = _id({'unit': 'rk'});
      final recorded = Map<String, Object?>.of(id.toJson())..['id'] = 'f' * 64;

      expect(StageId.fromJson(recorded).id, id.id);
    });

    test('only JSON data can enter the plan', () {
      expect(() => _id({'bad': DateTime(2026)}), throwsFormatException);
      expect(() => _id({'bad': double.nan}), throwsFormatException);
    });
  });

  group('atomic file replacement', () {
    late Directory root;

    setUp(() => root = Directory.systemTemp.createTempSync('rk-atomic-'));
    tearDown(() => root.deleteSync(recursive: true));

    test('an interrupted sibling leaves the destination at its old bytes', () {
      final destination = File('${root.path}/artifact');
      AtomicFile.write(destination.path, utf8.encode('old'));

      // This is the only filesystem state between the helper's flush and
      // rename: the destination is still old and the new bytes are a private
      // sibling. It carries no authority if the process stops here.
      final interrupted = File('${destination.path}.tmp.$pid.interrupted')
        ..writeAsBytesSync(utf8.encode('new'), flush: true);

      expect(destination.readAsStringSync(), 'old');
      expect(interrupted.readAsStringSync(), 'new');

      interrupted.deleteSync();
      AtomicFile.write(destination.path, utf8.encode('new'));

      expect(destination.readAsStringSync(), 'new');
      expect(
        root.listSync().where((entity) => entity.path.contains('.tmp.')),
        isEmpty,
      );
    });

    test('a failed rename removes its private sibling', () {
      final destination = Directory('${root.path}/artifact')..createSync();
      final sentinel = File('${destination.path}/keep')..writeAsStringSync('x');

      expect(
        () => AtomicFile.write(destination.path, utf8.encode('new')),
        throwsA(isA<FileSystemException>()),
      );
      expect(destination.existsSync(), isTrue);
      expect(sentinel.readAsStringSync(), 'x');
      expect(
        root.listSync().where((entity) => entity.path.contains('.tmp.')),
        isEmpty,
      );
    });

    test('copying keeps the source and replaces only the destination', () {
      final source = File('${root.path}/source')..writeAsBytesSync([1, 2, 3]);
      final destination = File('${root.path}/artifact')
        ..writeAsStringSync('old');
      AtomicFile.copy(destination.path, source);
      expect(source.readAsBytesSync(), [1, 2, 3]);
      expect(destination.readAsBytesSync(), [1, 2, 3]);
      expect(
        root.listSync().where((file) => file.path.contains('.tmp.')),
        isEmpty,
      );
    });

    test(
      'failed copies preserve existing bytes and remove private siblings',
      () {
        final destination = File('${root.path}/artifact')
          ..writeAsStringSync('old');
        expect(
          () => AtomicFile.copy(destination.path, File('${root.path}/missing')),
          throwsA(isA<FileSystemException>()),
        );
        expect(destination.readAsStringSync(), 'old');

        final source = File('${root.path}/source')..writeAsStringSync('new');
        final occupied = Directory('${root.path}/occupied')..createSync();
        final sentinel = File('${occupied.path}/keep')
          ..writeAsStringSync('keep');
        expect(
          () => AtomicFile.copy(occupied.path, source),
          throwsA(isA<FileSystemException>()),
        );
        expect(source.readAsStringSync(), 'new');
        expect(sentinel.readAsStringSync(), 'keep');
        expect(
          root.listSync().where((file) => file.path.contains('.tmp.')),
          isEmpty,
        );
      },
    );
  });

  group('receipt', () {
    test('round-trips its plan, evidence and files', () {
      final receipt =
          Receipt(
            stage: _id({'unit': 'rk'}),
            plan: const {
              'projects': [
                {'version': '1.0.0'},
              ],
            },
          ).recording(
            'build:rk:macos-arm64',
            {
              'signature': {'certificate': 'Developer ID Application: Test'},
              'notary': {'status': 'Accepted'},
            },
            const {
              'producers/rk/macos-arm64/rk': StagedFile(
                producer: 'build:rk:macos-arm64',
                size: 6,
                sha256:
                    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
              ),
            },
          );

      final parsed = Receipt.parse(receipt.encode());
      expect(parsed.encode(), receipt.encode());
      expect(parsed.stage.id, receipt.stage.id);
      expect(parsed.complete, isFalse);
      expect(parsed.plan, receipt.plan);
      expect(parsed.producers['build:rk:macos-arm64']!['notary'], {
        'status': 'Accepted',
      });
      expect(
        parsed.files['producers/rk/macos-arm64/rk']!.producer,
        'build:rk:macos-arm64',
      );
      expect(
        () => ((receipt.plan['projects'] as List).single as Map)['version'] =
            '2.0.0',
        throwsUnsupportedError,
        reason: 'what was recorded does not change under the reader',
      );
    });

    test('is complete once the barrier is recorded, and only then', () {
      final receipt = Receipt(stage: _id(const {}), plan: const {});
      expect(receipt.complete, isFalse);
      expect(
        receipt.recording(Receipt.barrier, const {}, const {}).complete,
        isTrue,
      );
    });

    test('keys are written sorted, whatever order work was recorded in', () {
      Receipt record(List<String> order) {
        var receipt = Receipt(stage: _id(const {}), plan: const {});
        for (final name in order) {
          receipt = receipt.recording(name, {'name': name}, const {});
        }
        return receipt;
      }

      expect(
        record(['pub-archive:b', 'pub-archive:a']).encode(),
        record(['pub-archive:a', 'pub-archive:b']).encode(),
      );
    });
  });
}

StageId _id(Map<String, Object?> plan) =>
    StageId.of(commit: _commit, tree: _tree, plan: plan);
