import 'dart:convert';
import 'dart:io';

import 'package:release_kit/src/engine/workspace.dart';
import 'package:test/test.dart';

void main() {
  late Directory scratch;
  late Workspace workspace;

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('rk-ws-contract-');
    workspace = Workspace('${scratch.path}/work');
  });
  tearDown(() => scratch.deleteSync(recursive: true));

  test('write is visible to exists and readBytes', () {
    workspace.write('a/b.txt', utf8.encode('hello'));
    expect(workspace.exists('a/b.txt'), isTrue);
    expect(utf8.decode(workspace.readBytes('a/b.txt')!), 'hello');
  });

  test('what a native tool wrote at pathOf is visible', () {
    File(workspace.pathOf('macos-arm64/tool'))
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(utf8.encode('BINARY'));

    expect(workspace.exists('macos-arm64/tool'), isTrue);
    expect(
      utf8.decode(workspace.readBytes('macos-arm64/tool')!),
      'BINARY',
    );
  });

  test('a name that escapes the workspace is refused everywhere', () {
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
      ]) {
        expect(operation, throwsArgumentError, reason: name);
      }
    }
  });

  test('rewriting a file leaves no partial writer artifact', () {
    workspace.write('a.txt', utf8.encode('first'));
    workspace.write('a.txt', utf8.encode('second'));
    expect(utf8.decode(workspace.readBytes('a.txt')!), 'second');
    expect(
      Directory(workspace.root)
          .listSync(recursive: true)
          .where((entry) => entry.path.contains('.tmp.')),
      isEmpty,
    );
  });

  test('absence is null and false, not an exception', () {
    expect(workspace.exists('never-written'), isFalse);
    expect(workspace.readBytes('never-written'), isNull);
  });
}
