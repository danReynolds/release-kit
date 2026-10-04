@Tags(['publication'])
@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:rk/src/transforms/digest.dart';
import 'package:test/test.dart';

import 'support/native_publication_fixture.dart';

void main() {
  late NativePublicationFixture fixture;
  setUp(() async {
    fixture = await NativePublicationFixture.create();
    addTearDown(fixture.close);
  });

  test(
    'native frontend preserves arguments and isolates credentials and routing',
    () async {
      final script = File('${fixture.root.path}/arguments.dart')
        ..writeAsStringSync('''
import 'dart:convert';
import 'dart:io';
void main(List<String> arguments) => print(jsonEncode({
  'arguments': arguments,
  'keys': Platform.environment.keys.toList(),
  'home': Platform.environment['HOME'],
  'cache': Platform.environment['PUB_CACHE'],
  'proxy': Platform.environment['https_proxy'],
  'hosted': Platform.environment['PUB_HOSTED_URL'],
}));
''');
      const arguments = [
        'with spaces',
        'single\'quote',
        '\$literal',
        '; false',
        '',
      ];
      final result = await fixture.runDart([script.path, ...arguments]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final output = jsonDecode(result.stdout as String) as Map;
      expect(output['arguments'], arguments);
      expect(output['home'], '${fixture.root.path}/home');
      expect(output['cache'], '${fixture.root.path}/cache');
      expect(output['proxy'], startsWith('http://127.0.0.1:'));
      expect(output['hosted'], fixture.registry.origin);
      expect(
        output['keys'],
        isNot(
          contains(
            anyOf('GH_TOKEN', 'GITHUB_TOKEN', 'HTTPS_PROXY', 'NO_PROXY'),
          ),
        ),
      );
      final token = await fixture.runDart(['pub', 'token', 'list']);
      expect(token.exitCode, 0, reason: '${token.stderr}');
      expect(token.stdout, contains(fixture.registry.origin));
      expect(
        () => fixture.environment['https_proxy'] = 'DIRECT',
        throwsUnsupportedError,
      );
      await expectLater(
        fixture.runDart(['--version'], environment: {'https_proxy': ''}),
        throwsArgumentError,
      );
      expect(fixture.registry.committed, isEmpty);
    },
  );

  test(
    'the transport rejects unapproved hosts with no registry request',
    () async {
      final script = File('${fixture.root.path}/unapproved.dart')
        ..writeAsStringSync('''
import 'dart:io';
Future<void> main() async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse('https://outside.invalid/package'));
    await request.close();
    exitCode = 1;
  } on HttpException {
    print('refused');
  } finally {
    client.close(force: true);
  }
}
''');
      final result = await fixture.runDart([script.path]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect('${result.stdout}'.trim(), 'refused');
      expect(fixture.connections, contains('CONNECT outside.invalid:443'));
      expect(fixture.registry.events, isEmpty);
    },
  );

  test(
    'timeout terminates native descendants and bounds inherited pipes',
    () async {
      final watch = Stopwatch()..start();
      final result = await fixture.runProcess('/bin/sh', [
        '-c',
        r'sleep 60 & child=$!; echo $child; wait',
      ], timeout: const Duration(milliseconds: 400));
      expect(
        result.exitCode,
        124,
        reason: '${result.stdout}\n${result.stderr}',
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 8)));
      final descendant = int.parse('${result.stdout}'.trim());
      final state = await Process.run('/bin/ps', [
        '-p',
        '$descendant',
        '-o',
        'stat=',
      ]);
      expect('${state.stdout}'.trim(), anyOf(isEmpty, startsWith('Z')));
    },
  );
  test(
    'timeout also terminates an orphan that retained output pipes',
    () async {
      final result = await fixture.runProcess('/bin/sh', [
        '-c',
        r'sleep 60 & echo $!',
      ], timeout: const Duration(milliseconds: 400));
      expect(
        result.exitCode,
        124,
        reason: '${result.stdout}\n${result.stderr}',
      );
      final descendant = int.parse('${result.stdout}'.trim());
      final state = await Process.run('/bin/ps', [
        '-p',
        '$descendant',
        '-o',
        'stat=',
      ]);
      expect('${state.stdout}'.trim(), anyOf(isEmpty, startsWith('Z')));
    },
  );
  test('an observed barrier interrupts the owned process group', () async {
    final marker = '${fixture.root.path}/ready';
    final ready = fixture.root
        .watch(events: FileSystemEvent.create)
        .firstWhere((event) => event.path == marker)
        .then<void>((_) {})
        .timeout(const Duration(seconds: 10));
    final result = await fixture.runProcess('/bin/sh', [
      '-c',
      r'sleep 60 & child=$!; echo $child; touch "$1"; wait',
      'fixture',
      marker,
    ], interruptWhen: ready);
    expect(result.exitCode, 130, reason: '${result.stdout}\n${result.stderr}');
    expect(File(marker).existsSync(), isTrue);
    final descendant = int.parse('${result.stdout}'.trim());
    final state = await Process.run('/bin/ps', [
      '-p',
      '$descendant',
      '-o',
      'stat=',
    ]);
    expect('${state.stdout}'.trim(), anyOf(isEmpty, startsWith('Z')));
  });

  test(
    'late interruption signals are ignored after normal completion',
    () async {
      for (final failBarrier in [false, true]) {
        final barrier = Completer<void>();
        final result = await fixture.runProcess('/bin/echo', [
          'completed',
        ], interruptWhen: barrier.future);
        expect(result.exitCode, 0);
        expect('${result.stdout}'.trim(), 'completed');
        if (failBarrier) {
          barrier.completeError(StateError('late barrier'));
        } else {
          barrier.complete();
        }
        await Future<void>.delayed(Duration.zero);
        final next = await fixture.runProcess('/bin/echo', ['still running']);
        expect(next.exitCode, 0);
        expect('${next.stdout}'.trim(), 'still running');
      }
    },
  );
  test(
    'lost finalization response fails native Pub after committing exact bytes',
    () async {
      const core = 'rk_qualification_core';
      final directory = '${fixture.repository.path}/packages/core';
      final archive = File('${fixture.root.path}/native-core.tar.gz');
      final packaged = await fixture.runDart([
        'pub',
        'publish',
        '--to-archive',
        archive.path,
      ], workingDirectory: directory);
      expect(
        packaged.exitCode,
        0,
        reason: '${packaged.stdout}\n${packaged.stderr}',
      );
      expect(
        '${packaged.stdout}${packaged.stderr}',
        isNot(contains('`dart analyze` found')),
      );
      final analyzed = await fixture.runDart([
        'analyze',
      ], workingDirectory: directory);
      expect(
        analyzed.exitCode,
        0,
        reason: '${analyzed.stdout}\n${analyzed.stderr}',
      );
      final digest = Sha256.hex(archive.readAsBytesSync());
      expect(fixture.registry.committed, isEmpty);

      fixture.registry.loseFinalizeResponses.add(core);
      final published = await fixture.runDart([
        'pub',
        'publish',
        '--from-archive',
        archive.path,
        '--force',
      ], workingDirectory: directory);
      // This must be the real native client's failure, not our timeout/interruption.
      expect(
        published.exitCode,
        isNot(anyOf(0, 124, 130)),
        reason: '${published.stdout}\n${published.stderr}',
      );
      expect(fixture.registry.committed.keys, ['$core@0.2.0']);
      expect(fixture.registry.committed['$core@0.2.0']!.digest, digest);
      expect(
        Sha256.hex(fixture.registry.archive(core, '0.2.0').readAsBytesSync()),
        digest,
      );
      expect(
        fixture.registry.events.where(
          (event) => event.kind == 'uploaded' && event.name == core,
        ),
        hasLength(1),
      );
      expect(
        fixture.registry.events.where(
          (event) => event.kind == 'committed' && event.name == core,
        ),
        hasLength(1),
      );
      expect(
        fixture.registry.events.where(
          (event) => event.kind == 'response_lost' && event.name == core,
        ),
        isNotEmpty,
      );
      expect(
        fixture.registry.events.where((event) => event.kind == 'finalized'),
        isEmpty,
      );
    },
  );
  test(
    'a failed native dependency solve exits nonzero without publication',
    () async {
      final directory = Directory('${fixture.root.path}/unsatisfied')
        ..createSync();
      File('${directory.path}/pubspec.yaml').writeAsStringSync(
        'name: unsatisfied_fixture\nenvironment:\n  sdk: ^3.10.4\ndependencies:\n  rk_package_that_does_not_exist: ^9.0.0\n',
      );
      final result = await fixture.runDart([
        'pub',
        'get',
      ], workingDirectory: directory.path);
      expect(
        result.exitCode,
        isNot(anyOf(0, 124, 130)),
        reason: '${result.stdout}\n${result.stderr}',
      );
      expect(
        '${result.stdout}${result.stderr}',
        contains('version solving failed'),
      );
      expect(fixture.registry.committed, isEmpty);
      expect(
        fixture.registry.events.where((event) => event.kind == 'initiated'),
        isEmpty,
      );
      expect(fixture.connections, isEmpty);
    },
  );

  test(
    'native publication rejects a malformed archive before upload',
    () async {
      final archive = File('${fixture.root.path}/invalid.tar.gz')
        ..writeAsStringSync('This is deliberately not a Pub archive.');
      final result = await fixture.runDart([
        'pub',
        'publish',
        '--from-archive',
        archive.path,
        '--force',
      ], workingDirectory: '${fixture.repository.path}/packages/core');
      expect(
        result.exitCode,
        isNot(anyOf(0, 124, 130)),
        reason: '${result.stdout}\n${result.stderr}',
      );
      expect(fixture.registry.committed, isEmpty);
      expect(
        fixture.registry.events.where((event) => event.kind == 'initiated'),
        isEmpty,
      );
    },
  );
}
