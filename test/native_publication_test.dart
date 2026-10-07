@Tags(['publication'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:rk/src/engine/stage_receipt.dart';
import 'package:rk/src/transforms/digest.dart';
import 'package:test/test.dart';

import 'rk_process.dart';
import 'support/native_publication_fixture.dart';
import 'support/pub_registry_fixture.dart';

const _core = 'rk_qualification_core';
const _format = 'rk_qualification_format';
const _testing = 'rk_qualification_testing';
const _app = 'rk_qualification_app';
const _versions = {
  _core: '0.2.0',
  _format: '0.3.0',
  _testing: '0.4.0',
  _app: '0.1.0',
};

void main() {
  late NativePublicationFixture fixture;

  setUp(() async {
    fixture = await NativePublicationFixture.create();
    addTearDown(() async {
      final events = fixture.registry.events;
      printOnFailure(
        events.skip(events.length > 100 ? events.length - 100 : 0).join('\n'),
      );
      await fixture.close();
    });
  });

  test(
    'stage, declined release and named blocked release never upload',
    () async {
      final staged = await _stage(fixture);
      expect(fixture.registry.committed, isEmpty);
      _ok(await fixture.rk(['stage', '--json']));

      final declined = await fixture.rk(['release', '--json']);
      expect(declined.code, 1, reason: declined.all);
      expect(declined.problems.map((p) => p['code']), contains('RK-AUTH-001'));

      // app needs core and format, which no unit in a named app release
      // publishes: it waits for them before acting.
      final blocked = await fixture.rk(['release', 'app', '--yes', '--json']);
      expect(blocked.code, 1, reason: blocked.all);
      expect(
        blocked.problems.map((p) => p['code']),
        contains('RK-REL-001'),
        reason: blocked.all,
      );
      expect(blocked.all, contains('rk_qualification_core 0.2.0 must be live'));
      expect(
        fixture.registry.events.where((e) => e.kind == 'initiated'),
        isEmpty,
      );
      _unchanged(staged);
    },
  );

  test(
    'real native uploads preserve independent versions and feed a fresh consumer',
    () async {
      final staged = await _stage(fixture);
      _ok(await fixture.rk(['release', '--yes', '--json']));
      _published(fixture.registry, staged);
      final accepted = fixture.registry.events
          .where((e) => e.kind == 'committed')
          .map((e) => e.name)
          .toList();
      for (final dependency in [
        (_core, _format),
        (_core, _testing),
        (_core, _app),
        (_format, _app),
      ]) {
        expect(
          accepted.indexOf(dependency.$1),
          lessThan(accepted.indexOf(dependency.$2)),
        );
      }
      await _consume(fixture);
      _unchanged(staged);

      // A fresh RK process sees exact public truth and performs no second upload.
      final uploads = fixture.registry.events
          .where((e) => e.kind == 'initiated')
          .length;
      _ok(await fixture.rk(['release', '--yes', '--json']));
      expect(
        fixture.registry.events.where((e) => e.kind == 'initiated'),
        hasLength(uploads),
      );
    },
  );

  test(
    'an unpublished development helper does not block named app publication',
    () async {
      final staged = await _stage(fixture);
      for (final unit in ['core', 'format', 'app']) {
        _ok(await fixture.rk(['release', unit, '--yes', '--json']));
      }
      expect(
        fixture.registry.committed.keys,
        unorderedEquals(['$_core@0.2.0', '$_format@0.3.0', '$_app@0.1.0']),
      );
      _published(fixture.registry, staged, names: [_core, _format, _app]);
      await _consume(fixture);
      _unchanged(staged);
    },
  );

  test(
    'rejected upload and interrupted confirmation resume with original archives',
    () async {
      final staged = await _stage(fixture);
      fixture.registry.rejectUploads.add(_app);
      final confirmingRejection = Completer<void>();
      var rejected = false;
      fixture.registry.onEvent = (event) {
        if (event.kind == 'rejected' && event.name == _app) rejected = true;
        if (rejected &&
            event.kind == 'coordinate_missing' &&
            event.path == '/api/packages/$_app/versions/0.1.0' &&
            !confirmingRejection.isCompleted) {
          confirmingRejection.complete();
        }
      };
      final failed = await fixture.rk([
        'release',
        '--yes',
        '--json',
      ], interruptWhen: confirmingRejection.future);
      expect(failed.code, 130, reason: failed.all);
      expect(confirmingRejection.isCompleted, isTrue);
      fixture.registry.onEvent = null;
      expect(fixture.registry.committed, contains('$_core@0.2.0'));
      expect(fixture.registry.committed, isNot(contains('$_app@0.1.0')));
      expect(
        fixture.registry.events.where(
          (e) => e.kind == 'rejected' && e.name == _app,
        ),
        isNotEmpty,
      );
      final acceptedBeforeRetry = fixture.registry.committed.values
          .map((package) => package.name)
          .toSet();
      final alreadyUploaded = fixture.registry.events
          .where(
            (e) =>
                e.kind == 'upload_attempted' &&
                acceptedBeforeRetry.contains(e.name),
          )
          .length;
      _unchanged(staged);

      fixture.registry.rejectUploads.clear();
      _ok(await fixture.rk(['release', '--yes', '--json']));
      expect(
        fixture.registry.events.where(
          (e) =>
              e.kind == 'upload_attempted' &&
              acceptedBeforeRetry.contains(e.name),
        ),
        hasLength(alreadyUploaded),
      );
      _published(fixture.registry, staged);
      _unchanged(staged);
      await _consume(fixture);
    },
  );

  test(
    'accepted upload with lost response reconciles without duplicate publication',
    () async {
      final staged = await _stage(fixture);
      fixture.registry.loseFinalizeResponses.add(_core);
      final reconciled = await fixture.rk(['release', '--yes', '--json']);
      _ok(reconciled);
      final publication = reconciled
          .stepsOf('core')
          .singleWhere((step) => step['kind'] == 'publishRegistry');
      expect(publication['verdict'], 'exact');
      expect(publication['action'], 'completed');
      // The fixture's separate native-client control proves this response-loss
      // fault returns a failed Pub command after committing the archive. RK's
      // machine surface records its reconciled public result, not progress notes.
      expect(
        fixture.registry.events.where(
          (e) => e.kind == 'response_lost' && e.name == _core,
        ),
        isNotEmpty,
      );
      expect(
        fixture.registry.events.where(
          (e) => e.kind == 'committed' && e.name == _core,
        ),
        hasLength(1),
      );
      expect(
        fixture.registry.events.where(
          (e) => e.kind == 'upload_attempted' && e.name == _core,
        ),
        hasLength(1),
      );
      _published(fixture.registry, staged);
      _unchanged(staged);
      await _consume(fixture);
    },
  );

  test('an archive propagation wait recovers without reupload', () async {
    final staged = await _stage(fixture);
    fixture.registry.unavailableArchives.add(_core);
    final unavailable = Completer<void>();
    fixture.registry.onEvent = (event) {
      if (event.kind == 'archive_unavailable' &&
          event.name == _core &&
          !unavailable.isCompleted) {
        unavailable.complete();
      }
    };
    final interrupted = await fixture.rk([
      'release',
      '--yes',
      '--json',
    ], interruptWhen: unavailable.future);
    expect(interrupted.code, 130, reason: interrupted.all);
    expect(unavailable.isCompleted, isTrue);
    fixture.registry.onEvent = null;
    expect(fixture.registry.committed.keys, ['$_core@0.2.0']);

    // Whole-stack release waits for propagation after committing core. A
    // named consumer needs only core's version to be listed, as Pub's
    // resolution does; neither run waits out the ten-minute poll.
    _ok(await fixture.rk(['release', 'format', '--yes', '--json']));
    expect(
      fixture.registry.committed.keys,
      unorderedEquals(['$_core@0.2.0', '$_format@0.3.0']),
    );
    expect(
      fixture.registry.events.where((e) => e.kind == 'archive_unavailable'),
      isNotEmpty,
    );

    fixture.registry.unavailableArchives.clear();
    _ok(await fixture.rk(['release', '--yes', '--json']));
    for (final name in [_core, _format]) {
      expect(
        fixture.registry.events.where(
          (e) => e.kind == 'upload_attempted' && e.name == name,
        ),
        hasLength(1),
        reason: '$name is uploaded once',
      );
    }
    _published(fixture.registry, staged);
    _unchanged(staged);
    await _consume(fixture);
  });

  test(
    'an occupied version counts as published and is never overwritten',
    () async {
      final staged = await _stage(fixture);
      final occupied = _controlArchive(
        fixture.root,
        _core,
        '0.2.0',
        library: 'int get coreValue => -1;\n',
      );
      fixture.registry.seedArchive(occupied);
      final original = Sha256.hex(occupied.readAsBytesSync());

      // A version on the registry is published: rk compares no archive with
      // it, uploads nothing for it, and publishes the rest of the stack.
      _ok(await fixture.rk(['release', '--yes', '--json']));
      expect(
        fixture.registry.events.where(
          (e) => e.kind == 'upload_attempted' && e.name == _core,
        ),
        isEmpty,
      );
      expect(
        Sha256.hex(fixture.registry.archive(_core, '0.2.0').readAsBytesSync()),
        original,
      );
      _published(fixture.registry, staged, names: [_format, _testing, _app]);
      _unchanged(staged);
    },
  );

  test(
    'consumer control resolves a valid package but detects incompatible API',
    () async {
      const broken = 'rk_qualification_incompatible';
      fixture.registry.seedArchive(
        _controlArchive(
          fixture.root,
          broken,
          '0.1.0',
          library: 'const otherSymbol = 42;\n',
        ),
      );
      final consumer = _consumer(
        fixture.root,
        'incompatible',
        package: broken,
        source:
            '''
import 'package:$broken/$broken.dart';
void main() => print(requiredSymbol);
''',
      );
      final environment = {'PUB_CACHE': '${consumer.path}/empty-cache'};
      _processOk(
        await fixture.runDart(
          ['pub', 'get'],
          workingDirectory: consumer.path,
          environment: environment,
        ),
      );
      final compiled = await fixture.runDart(
        ['compile', 'exe', 'bin/main.dart', '-o', '${consumer.path}/app'],
        workingDirectory: consumer.path,
        environment: environment,
      );
      expect(compiled.exitCode, isNot(0));
      expect(
        '${compiled.stdout}${compiled.stderr}',
        contains('requiredSymbol'),
      );
      expect(
        fixture.registry.events.where(
          (e) => e.kind == 'downloaded' && e.name == broken,
        ),
        isNotEmpty,
      );
    },
  );
}

void _ok(Run run) => expect(run.code, 0, reason: run.all);

void _processOk(ProcessResult result) =>
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');

typedef _Saved = ({File file, String digest, DateTime modified});

Future<Map<String, _Saved>> _stage(NativePublicationFixture fixture) async {
  final run = await fixture.rk(['stage', '--json']);
  _ok(run);
  final saved = <String, _Saved>{};
  for (final unit in run.units) {
    final evidence =
        run
                .stepsOf(unit['name'] as String)
                .singleWhere(
                  (step) => step['kind'] == 'completeStage',
                )['evidence']
            as Map;
    final directory = '${fixture.repository.path}/${evidence['stage path']}';
    final receipt = StageReceipt.parse(
      File('$directory/stage.json').readAsStringSync(),
    );
    final archive = receipt.artifacts.singleWhere(
      (artifact) => artifact.type == 'pub-archive',
    );
    final name = 'rk_qualification_${unit['name']}';
    final file = File('$directory/${archive.path}');
    expect(Sha256.hex(file.readAsBytesSync()), archive.sha256);
    saved[name] = (
      file: file,
      digest: archive.sha256,
      modified: file.lastModifiedSync(),
    );
  }
  expect(saved.keys, unorderedEquals(_versions.keys));
  expect(fixture.registry.events.where((e) => e.kind == 'uploaded'), isEmpty);
  return saved;
}

void _unchanged(Map<String, _Saved> saved) {
  for (final entry in saved.entries) {
    expect(
      Sha256.hex(entry.value.file.readAsBytesSync()),
      entry.value.digest,
      reason: entry.key,
    );
    expect(
      entry.value.file.lastModifiedSync(),
      entry.value.modified,
      reason: 'must reuse ${entry.key}, not repackage it',
    );
  }
}

void _published(
  PubRegistryFixture registry,
  Map<String, _Saved> saved, {
  Iterable<String>? names,
}) {
  for (final name in names ?? _versions.keys) {
    final version = _versions[name]!;
    final actual = registry.committed['$name@$version']!;
    expect(actual.digest, saved[name]!.digest, reason: name);
    expect(
      Sha256.hex(registry.archive(name, version).readAsBytesSync()),
      saved[name]!.digest,
    );
    expect(actual.manifest['version'], version);
    expect(actual.manifest, isNot(contains('dependency_overrides')));
    final contents = TarDecoder().decodeBytes(
      GZipDecoder().decodeBytes(
        registry.archive(name, version).readAsBytesSync(),
      ),
    );
    final manifests = contents.files.where(
      (entry) =>
          entry.name.replaceFirst(RegExp(r'^(\./)+'), '') == 'pubspec.yaml',
    );
    final unit = name.substring('rk_qualification_'.length);
    expect(
      manifests.single.content,
      File(
        'examples/local-publication/packages/$unit/pubspec.yaml',
      ).readAsBytesSync(),
    );
    expect(
      contents.files.where(
        (entry) => entry.name.split('/').last == 'pubspec_overrides.yaml',
      ),
      isEmpty,
    );
    expect(
      registry.events.where(
        (e) =>
            e.kind == 'uploaded' &&
            e.name == name &&
            e.digest == saved[name]!.digest,
      ),
      isNotEmpty,
    );
    expect(
      registry.events.where((e) => e.kind == 'committed' && e.name == name),
      hasLength(1),
    );
  }
}

Future<void> _consume(NativePublicationFixture fixture) async {
  final consumer = _consumer(
    fixture.root,
    'consumer',
    package: _app,
    source:
        '''
import 'package:$_app/$_app.dart';
void main() {
  final result = message();
  if (result != 'value=42; core=42') throw StateError(result);
  print(result);
}
''',
  );
  final cache = Directory('${consumer.path}/empty-cache');
  expect(cache.existsSync(), isFalse);
  final environment = {'PUB_CACHE': cache.path};
  final before = fixture.registry.events.length;
  _processOk(
    await fixture.runDart(
      ['pub', 'get'],
      workingDirectory: consumer.path,
      environment: environment,
    ),
  );
  final config =
      jsonDecode(
            File(
              '${consumer.path}/.dart_tool/package_config.json',
            ).readAsStringSync(),
          )
          as Map;
  final packages = (config['packages'] as List).cast<Map>();
  final names = packages.map((p) => p['name']);
  expect(names, containsAll([_app, _core, _format]));
  expect(names, isNot(contains(_testing)));
  for (final package in packages.where(
    (p) => _versions.containsKey(p['name']),
  )) {
    final rootUri = File(
      '${consumer.path}/.dart_tool/package_config.json',
    ).uri.resolve(package['rootUri'] as String);
    expect(
      Directory.fromUri(rootUri).resolveSymbolicLinksSync(),
      startsWith('${cache.resolveSymbolicLinksSync()}/'),
    );
  }
  final downloads = fixture.registry.events
      .skip(before)
      .where((e) => e.kind == 'downloaded')
      .map((e) => e.name);
  expect(downloads, containsAll([_app, _core, _format]));
  _processOk(
    await fixture.runDart(
      ['compile', 'exe', 'bin/main.dart', '-o', '${consumer.path}/app'],
      workingDirectory: consumer.path,
      environment: environment,
    ),
  );
  final ran = await fixture.runProcess(
    '${consumer.path}/app',
    const [],
    workingDirectory: consumer.path,
  );
  _processOk(ran);
  expect('${ran.stdout}'.trim(), 'value=42; core=42');
}

Directory _consumer(
  Directory root,
  String label, {
  required String package,
  required String source,
}) {
  final directory = Directory('${root.path}/$label')..createSync();
  File('${directory.path}/pubspec.yaml').writeAsStringSync(
    'name: qualification_consumer\nenvironment:\n  sdk: ^3.10.4\ndependencies:\n  $package: ^0.1.0\n',
  );
  File('${directory.path}/bin/main.dart')
    ..parent.createSync()
    ..writeAsStringSync(source);
  return directory;
}

/// Only negative/control packages are seeded; positive releases use native HTTP.
File _controlArchive(
  Directory root,
  String name,
  String version, {
  required String library,
}) {
  final archive = Archive()
    ..addFile(
      ArchiveFile.string(
        'pubspec.yaml',
        'name: $name\nversion: $version\nenvironment:\n  sdk: ^3.10.4\n',
      ),
    )
    ..addFile(ArchiveFile.string('lib/$name.dart', library));
  return File('${root.path}/control-$name.tar.gz')
    ..writeAsBytesSync(GZipEncoder().encode(TarEncoder().encode(archive)));
}
