import 'dart:convert';
import 'dart:io';

import 'package:release_kit/src/engine/workspace.dart';
import 'package:test/test.dart';

/// One contract, two implementations — every test runs against both.
///
/// The reuse gate consults `exists` before anything ingests, so the two
/// workspaces must agree about a file a native tool wrote at `pathOf`: when
/// the memory workspace said "not here" for what the directory workspace
/// could see, the reuse branch was unreachable under the memory workspace —
/// and therefore under every test that used it.
void main() {
  late Directory scratch;

  setUp(() => scratch = Directory.systemTemp.createTempSync('rk-ws-contract-'));
  tearDown(() => scratch.deleteSync(recursive: true));

  final makers = <String, Workspace Function()>{
    'DirectoryWorkspace': () => DirectoryWorkspace('${scratch.path}/work'),
    'MemoryWorkspace': MemoryWorkspace.new,
  };

  makers.forEach((label, make) {
    group(label, () {
      test('write is visible to exists and readBytes', () {
        final workspace = make();
        workspace.write('a/b.txt', utf8.encode('hello'));
        expect(workspace.exists('a/b.txt'), isTrue);
        expect(utf8.decode(workspace.readBytes('a/b.txt')!), 'hello');
      });

      test('what a native tool wrote at pathOf is visible before any ingest',
          () {
        // This is the reuse gate's exact read pattern: a prior run's tool
        // wrote to pathOf, this run's chain asks exists() first.
        final workspace = make();
        File(workspace.pathOf('macos-arm64/tool'))
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(utf8.encode('BINARY'));

        expect(workspace.exists('macos-arm64/tool'), isTrue);
        expect(
          utf8.decode(workspace.readBytes('macos-arm64/tool')!),
          'BINARY',
        );

        workspace.ingest('macos-arm64/tool');
        expect(workspace.exists('macos-arm64/tool'), isTrue);
      });

      test('a name that escapes the workspace is refused everywhere', () {
        final workspace = make();
        for (final name in [
          '../escape',
          'a/../../escape',
          '/absolute',
          r'a\b',
          'a//b',
          './a',
        ]) {
          for (final operation in <void Function()>[
            () => workspace.pathOf(name),
            () => workspace.write(name, utf8.encode('x')),
            () => workspace.readBytes(name),
            () => workspace.exists(name),
            () => workspace.ingest(name),
          ]) {
            expect(operation, throwsArgumentError, reason: name);
          }
        }
      });

      test('rewriting a file leaves no partial writer artifact', () {
        final workspace = make();
        workspace.write('a.txt', utf8.encode('first'));
        workspace.write('a.txt', utf8.encode('second'));
        expect(utf8.decode(workspace.readBytes('a.txt')!), 'second');
        if (workspace case DirectoryWorkspace(:final root)) {
          expect(
            Directory(root)
                .listSync(recursive: true)
                .where((entry) => entry.path.contains('.tmp.')),
            isEmpty,
          );
        }
      });

      test('absence is null and false, not an exception', () {
        final workspace = make();
        expect(workspace.exists('never-written'), isFalse);
        expect(workspace.readBytes('never-written'), isNull);
      });
    });
  });
}
