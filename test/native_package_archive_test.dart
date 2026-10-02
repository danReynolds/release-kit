import 'dart:convert';
import 'dart:io';

import 'package:rk/src/native/dart/package_archive.dart';
import 'package:rk/src/native/package_archive.dart';
import 'package:tar/tar.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('rk-archive-test-'));
  tearDown(() => temp.deleteSync(recursive: true));

  File archive(List<int> tar) =>
      File('${temp.path}/package.tar.gz')..writeAsBytesSync(gzip.encode(tar));
  Future<NativePackageArchive> read(
    List<SynchronousTarEntry> entries, {
    OutputFormat format = OutputFormat.pax,
  }) => NativePackageArchive.read(archive(_tar(entries, format)));

  for (final format in OutputFormat.values) {
    test(
      'native $format long Unicode names preserve payload and effective executable mode',
      () async {
        final long = 'lib/${'long_segment/' * 12}été_雪.dart';
        final result = await read([
          _file('pubspec.yaml', 'name: fixture\nversion: 0.2.0\n'),
          _file(long, 'const value = 42;'),
          _file('bin/worker', 'executable', mode: 0x1c0),
          _file('lib/ space name .dart', 'spaces'),
        ], format: format);
        expect(utf8.decode(result.files[long]!.bytes), 'const value = 42;');
        expect(result.files['bin/worker']!.mode, '0744');
        expect(DartPackageManifest.fromArchive(result).version, '0.2.0');
        expect(() => result.bytes[0] = 0, throwsUnsupportedError);
        final extracted = result.extract();
        addTearDown(() => extracted.deleteSync(recursive: true));
        expect(
          File('${extracted.path}/$long').readAsStringSync(),
          'const value = 42;',
        );
        expect(
          File('${extracted.path}/bin/worker').statSync().mode & 0x1ff,
          0x1e4,
        );
      },
    );
  }

  test(
    'root directories and normalized aliases cannot duplicate a payload',
    () async {
      final root = TarEntry.data(
        TarHeader(name: './', mode: 0x1ed, typeFlag: TypeFlag.dir),
        [],
      );
      expect(
        (await read([
          root,
          _file('./pubspec.yaml', 'name: x\nversion: 1.0.0'),
        ])).files.keys,
        ['pubspec.yaml'],
      );
      await expectLater(
        read([_file('./a', 'one'), _file('a', 'two')]),
        throwsFormatException,
      );
    },
  );

  for (final name in [
    '../escape',
    '/escape',
    'lib/../escape',
    r'lib\escape',
    'C:/escape',
    'lib/a:stream',
    'lib//x',
  ]) {
    test('refuses unsafe effective path $name', () async {
      await expectLater(read([_file(name, 'bad')]), throwsFormatException);
    });
  }

  test('conflicting ancestor paths fail in either order', () async {
    for (final entries in [
      [_file('lib', 'one'), _file('lib/a.dart', 'two')],
      [_file('lib/a.dart', 'two'), _file('lib', 'one')],
    ]) {
      await expectLater(read(entries), throwsFormatException);
    }
  });

  for (final type in [
    TypeFlag.link,
    TypeFlag.symlink,
    TypeFlag.fifo,
    TypeFlag.char,
    TypeFlag.block,
  ]) {
    test('refuses $type before creating a filesystem entry', () async {
      await expectLater(
        read([
          TarEntry.data(
            TarHeader(
              name: 'bad',
              mode: 0x1a4,
              typeFlag: type,
              linkName: '../elsewhere',
            ),
            [],
          ),
        ]),
        throwsFormatException,
      );
    });
  }

  test('privileged permission bits are never materialized', () async {
    await expectLater(
      read([_file('bad', 'payload', mode: 0x9ed)]),
      throwsFormatException,
    );
  });

  test(
    'directory payloads and stacked metadata cannot conceal native headers',
    () async {
      final hidden = _raw(
        'meta',
        0x78,
        utf8.encode(_pax('SCHILY.acl.access', 'hidden')),
      );
      final manifest = _raw(
        'pubspec.yaml',
        0x30,
        utf8.encode('name: fixture\nversion: 1.0.0\n'),
      );
      for (final bytes in [
        [..._raw('./', 0x35, hidden), ...manifest, ...List.filled(1024, 0)],
        [
          ..._raw('size', 0x78, utf8.encode(_pax('size', '0'))),
          ..._raw('name', 0x4c, [..._raw('marker', 0x30, []), ...hidden]),
          ..._raw('outer', 0x30, []),
          ...manifest,
          ...List.filled(1024, 0),
        ],
      ]) {
        await expectLater(
          NativePackageArchive.read(archive(bytes)),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'manifest aliases and decoded maps have bounded expansion and depth',
    () {
      final bomb = StringBuffer(
        'name: fixture\nversion: 1.0.0\na0: &a0 [payload,payload]\n',
      );
      for (var i = 1; i <= 20; i++) {
        bomb.writeln('a$i: &a$i [*a${i - 1},*a${i - 1}]');
      }
      expect(
        () => DartPackageManifest.parse(bomb.toString()),
        throwsFormatException,
      );
      Object? deep = 'leaf';
      for (var i = 0; i < 150; i++) {
        deep = [deep];
      }
      expect(
        () => DartPackageManifest.fromMap({
          'name': 'fixture',
          'version': '1.0.0',
          'custom': deep,
        }),
        throwsFormatException,
      );
      expect(
        () => DartPackageManifest.parse(
          'name: fixture\nversion: 1.0.0\na: &a [*a]\n',
        ),
        throwsFormatException,
      );
    },
  );

  test('bounds compressed bytes, expanded bytes, entries and depth', () async {
    final file = archive(_tar([_file('huge', 'x' * 50000)], OutputFormat.pax));
    await expectLater(
      NativePackageArchive.read(file, maxCompressedBytes: 10),
      throwsFormatException,
    );
    await expectLater(
      NativePackageArchive.read(file, maxExpandedBytes: 2048),
      throwsFormatException,
    );
    await expectLater(
      NativePackageArchive.read(file, maxEntries: 0),
      throwsFormatException,
    );
    await expectLater(
      read([_file('${'a/' * 129}file', 'x')]),
      throwsFormatException,
    );
  });

  test(
    'rejects bad gzip, checksum, padding, truncation and trailing payload',
    () async {
      final valid = _tar([_file('a', 'x')], OutputFormat.pax);
      final badChecksum = [...valid]..[0] = 98;
      final badPadding = [...valid]..[513] = 1;
      final trailing = [...valid, ...List.filled(512, 0)]..[valid.length] = 1;
      for (final tar in [
        badChecksum,
        badPadding,
        valid.sublist(0, 1024),
        valid.sublist(0, 513),
        trailing,
      ]) {
        await expectLater(
          NativePackageArchive.read(archive(tar)),
          throwsA(isA<Exception>()),
        );
      }
      final file = archive(valid);
      final compressed = file.readAsBytesSync();
      file.writeAsBytesSync(compressed.sublist(0, compressed.length - 6));
      await expectLater(
        NativePackageArchive.read(file),
        throwsA(isA<Exception>()),
      );
    },
  );

  test('rejects a changed archive hash before parsing', () async {
    await expectLater(
      NativePackageArchive.read(
        archive(_tar([_file('a', 'x')], OutputFormat.pax)),
        expectedSha256: 'f' * 64,
      ),
      throwsFormatException,
    );
  });

  test(
    'PAX effective path and size are validated rather than the placeholder header',
    () async {
      final pax = _raw(
        'meta',
        0x78,
        utf8.encode('${_pax('path', 'lib/雪.dart')}${_pax('size', '3')}'),
      );
      final file = _raw(
        'placeholder',
        0x30,
        utf8.encode('abc'),
        declaredSize: 1,
      );
      final result = await NativePackageArchive.read(
        archive([...pax, ...file, ...List.filled(1024, 0)]),
      );
      expect(utf8.decode(result.files['lib/雪.dart']!.bytes), 'abc');
      final unsafe = _raw('meta', 0x78, utf8.encode(_pax('path', '../escape')));
      await expectLater(
        NativePackageArchive.read(
          archive([
            ...unsafe,
            ..._raw('safe', 0x30, [120]),
            ...List.filled(1024, 0),
          ]),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'malformed PAX, hidden sparse metadata and global headers fail closed',
    () async {
      for (final pax in [
        'garbage',
        '50 path=short\n',
        '0 path=x\n',
        _pax('GNU.sparse.realsize', '999999999'),
        '${_pax('path', 'a')}${_pax('path', 'b')}',
      ]) {
        await expectLater(
          NativePackageArchive.read(
            archive([
              ..._raw('meta', 0x78, utf8.encode(pax)),
              ..._raw('file', 0x30, [120]),
              ...List.filled(1024, 0),
            ]),
          ),
          throwsFormatException,
        );
      }
      await expectLater(
        NativePackageArchive.read(
          archive([
            ..._raw('meta', 0x67, utf8.encode(_pax('path', 'a'))),
            ..._raw('file', 0x30, [120]),
            ...List.filled(1024, 0),
          ]),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'full manifest comparison detects hidden dependencies and SDK/source changes',
    () {
      final expected = DartPackageManifest.parse(
        'name: x\nversion: 0.2.0\nenvironment:\n  sdk: ^3.10.4\ndependencies:\n  core: ^0.2.0\n',
      );
      final reordered = DartPackageManifest.parse(
        'version: 0.2.0\nname: x\ndependencies: {core: ^0.2.0}\nenvironment: {sdk: ^3.10.4}\n',
      );
      reordered.requireSameManifest(expected);
      for (final extra in [
        {
          'dev_dependencies': {'hidden': 'any'},
        },
        {
          'dependency_overrides': {'core': 'any'},
        },
        {
          'environment': {'sdk': '^3.13.5'},
        },
        {'custom': 'changed'},
      ]) {
        final actual = DartPackageManifest.parse(
          jsonEncode({...expected.fields, ...extra}),
        );
        expect(
          () => actual.requireSameManifest(expected),
          throwsFormatException,
        );
      }
      final moved = DartPackageManifest.parse(
        jsonEncode({
          ...expected.fields,
          'dependencies': {
            'core': {'hosted': 'https://other.example', 'version': '^0.2.0'},
          },
        }),
      );
      expect(() => moved.requireSameManifest(expected), throwsFormatException);
    },
  );
}

SynchronousTarEntry _file(String name, String body, {int mode = 0x1a4}) =>
    TarEntry.data(TarHeader(name: name, mode: mode), utf8.encode(body));

List<int> _tar(List<SynchronousTarEntry> entries, OutputFormat format) {
  late List<int> result;
  final sink = tarConverterWith(format: format).startChunkedConversion(
    ByteConversionSink.withCallback((bytes) => result = bytes),
  );
  entries.forEach(sink.add);
  sink.close();
  return result;
}

List<int> _raw(String name, int type, List<int> bytes, {int? declaredSize}) {
  final header = List.filled(512, 0);
  void field(int offset, String value) =>
      header.setRange(offset, offset + value.length, ascii.encode(value));
  field(0, name);
  field(100, '0000644');
  field(124, (declaredSize ?? bytes.length).toRadixString(8).padLeft(11, '0'));
  header[156] = type;
  field(257, 'ustar');
  field(263, '00');
  header.fillRange(148, 156, 32);
  final sum = header.fold<int>(0, (a, b) => a + b);
  field(148, sum.toRadixString(8).padLeft(6, '0'));
  header[154] = 0;
  return [
    ...header,
    ...bytes,
    ...List.filled((512 - bytes.length % 512) % 512, 0),
  ];
}

String _pax(String key, String value) {
  final record = '$key=$value\n';
  var length = utf8.encode(record).length + 3;
  while (utf8.encode('$length $record').length != length) {
    length = utf8.encode('$length $record').length;
  }
  return '$length $record';
}
