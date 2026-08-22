import 'dart:io';

import 'package:test/test.dart';

import '../tool/prepare_release.dart';

void main() {
  late Directory repository;

  setUp(() {
    repository = Directory.systemTemp.createTempSync('rk-prepare-release-');
    _write(repository, 'pubspec.yaml', '''
name: rk
version: 1.2.3
repository: https://example.com/rk
''');
    _write(repository, 'lib/src/version.dart', '''
/// Embedded in the compiled executable.
const rkVersion = '1.2.3';
''');
  });

  tearDown(() => repository.deleteSync(recursive: true));

  test('updates both declarations from one validated version', () {
    final update = prepareReleaseVersion(repository, '1.3.0');

    expect(update.previous.canonical, '1.2.3');
    expect(update.next.canonical, '1.3.0');
    expect(
      File('${repository.path}/pubspec.yaml').readAsStringSync(),
      contains('version: 1.3.0'),
    );
    expect(
      File('${repository.path}/lib/src/version.dart').readAsStringSync(),
      contains("const rkVersion = '1.3.0';"),
    );
  });

  test('refuses disagreement before changing either file', () {
    _write(repository, 'lib/src/version.dart', "const rkVersion = '1.2.2';\n");
    final beforePubspec =
        File('${repository.path}/pubspec.yaml').readAsStringSync();
    final beforeEmbedded =
        File('${repository.path}/lib/src/version.dart').readAsStringSync();

    expect(
      () => prepareReleaseVersion(repository, '1.3.0'),
      throwsA(isA<StateError>()),
    );
    expect(
      File('${repository.path}/pubspec.yaml').readAsStringSync(),
      beforePubspec,
    );
    expect(
      File('${repository.path}/lib/src/version.dart').readAsStringSync(),
      beforeEmbedded,
    );
  });

  test('refuses malformed or non-increasing release coordinates', () {
    expect(
      () => prepareReleaseVersion(repository, 'v1.3.0'),
      throwsArgumentError,
    );
    expect(
      () => prepareReleaseVersion(repository, '1.2.3'),
      throwsArgumentError,
    );
    expect(
      () => prepareReleaseVersion(repository, '1.2.2'),
      throwsArgumentError,
    );
  });
}

void _write(Directory root, String relativePath, String contents) {
  final file = File('${root.path}/$relativePath');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}
