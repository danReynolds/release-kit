import 'dart:convert';
import 'dart:io';

import 'package:rk/src/commands/clean.dart';
import 'package:rk/src/engine/stage.dart';
import 'package:rk/src/engine/stage_receipt.dart';
import 'package:rk/src/engine/stage_store.dart';
import 'package:rk/src/output/output.dart';
import 'package:rk/src/output/report.dart';
import 'package:test/test.dart';

import 'rk_process.dart';

void main() {
  late Directory scratch;

  setUp(() => scratch = Directory.systemTemp.createTempSync('rk-clean-'));
  tearDown(() {
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  });

  test('authorized cleanup removes only local stages and keeps diagnoses', () {
    final repo = Rk.repository(scratch, 'clean-authorized', {});
    Directory('${repo.root}/.rk/work/stages/first').createSync(recursive: true);
    Directory(
      '${repo.root}/.rk/work/stages/second',
    ).createSync(recursive: true);
    final diagnosis = File('${repo.root}/.rk/diagnosis/run/evidence.txt')
      ..createSync(recursive: true)
      ..writeAsStringSync('keep me');

    final run = repo(['clean', '--yes', '--json']);

    expect(run.code, 0, reason: run.all);
    expect(run.json['command'], 'clean');
    expect(run.json['cleanup'], {
      'root': Directory(repo.root).resolveSymbolicLinksSync(),
      'path': '.rk/work/stages',
      'found': 2,
      'removed': 2,
    });
    expect(run.warnings.map((warning) => warning['code']), ['RK-CLEAN-005']);
    expect(Directory('${repo.root}/.rk/work/stages').listSync(), isEmpty);
    expect(diagnosis.readAsStringSync(), 'keep me');
  });

  test('JSON without yes previews and changes nothing', () {
    final repo = Rk.repository(scratch, 'clean-preview', {});
    final stage = Directory('${repo.root}/.rk/work/stages/only')
      ..createSync(recursive: true);

    final run = repo(['clean', '--json']);

    expect(run.code, 1, reason: run.all);
    expect(run.problems.map((problem) => problem['code']), ['RK-CLEAN-004']);
    expect(run.json['cleanup'], {
      'root': Directory(repo.root).resolveSymbolicLinksSync(),
      'path': '.rk/work/stages',
      'found': 1,
      'removed': 0,
    });
    expect(run.json['next'], ['rk clean --yes']);
    expect(run.warnings.map((warning) => warning['code']), ['RK-CLEAN-005']);
    expect(stage.existsSync(), isTrue);
  });

  test('the prompt discloses recovery risk before accepting yes', () async {
    final repository = Directory('${scratch.path}/clean-prompt')..createSync();
    final store = StageStore(repository.path);
    Directory('${store.path}/only').createSync(recursive: true);
    final text = StringBuffer();
    String? prompt;
    final output = Output(
      sink: text.write,
      isTerminal: false,
      report: Report('clean'),
    );

    final code = await CleanCommand(
      store: store,
      output: output,
      yes: false,
      confirm: (value) async {
        prompt = value;
        return 'yes';
      },
    ).run();

    expect(code, 0);
    expect(text.toString(), contains('partially completed release'));
    expect(prompt, 'Remove staged release work? [y/N] ');
    expect(Directory('${store.path}/only').existsSync(), isFalse);
  });

  test(
    'cleanup identifies recorded stages before asking and keeps a declined inventory',
    () async {
      final repository = Directory('${scratch.path}/clean-inventory')
        ..createSync();
      final store = StageStore(repository.path);
      final completed = _writeReceipt(store, complete: true);
      final incomplete = _writeReceipt(store, complete: false);
      final orphan = Directory('${store.path}/orphan')..createSync();
      final broken = Directory('${store.path}/broken')..createSync();
      File('${broken.path}/stage.json').writeAsStringSync('not json');
      final text = StringBuffer();
      final output = Output(
        sink: text.write,
        isTerminal: false,
        report: Report('clean'),
      );

      final code = await CleanCommand(
        store: store,
        output: output,
        yes: false,
        confirm: (_) async {
          final preview = text.toString();
          expect(preview, contains(completed.name.substring(0, 12)));
          expect(
            preview,
            contains('tool 1.2.3 · commit 1111111 · completion recorded'),
          );
          expect(preview, contains(incomplete.name.substring(0, 12)));
          expect(preview, contains('commit 2222222 · incomplete stage'));
          expect(preview, contains('orphan'));
          expect(preview, contains('no stage receipt'));
          expect(preview, contains('broken'));
          expect(preview, contains('unreadable stage receipt'));
          expect(preview, contains('partially completed release'));
          expect(preview, isNot(contains('safe to delete')));
          return 'no';
        },
      ).run();

      expect(code, ExitCodes.refused);
      expect(store.inventory(), hasLength(4));
      expect(orphan.existsSync(), isTrue);
      expect(broken.existsSync(), isTrue);
      expect(output.report.acted, isFalse);
    },
  );

  test('inventory does not follow stage or receipt symlinks', () async {
    final repository = Directory('${scratch.path}/clean-links')..createSync();
    final store = StageStore(repository.path);
    Directory(store.path).createSync(recursive: true);
    final outside = Directory('${scratch.path}/outside')..createSync();
    final outsideReceipt = File('${outside.path}/stage.json')
      ..writeAsStringSync('do not read or remove');
    Link('${store.path}/linked-stage').createSync(outside.path);
    final regular = Directory('${store.path}/regular-stage')..createSync();
    Link('${regular.path}/stage.json').createSync(outsideReceipt.path);
    final text = StringBuffer();

    final code = await CleanCommand(
      store: store,
      output: Output(sink: text.write, isTerminal: false),
      yes: false,
      confirm: (_) async => 'no',
    ).run();

    expect(code, ExitCodes.refused);
    expect(text.toString(), contains('symbolic link · not followed'));
    expect(
      text.toString(),
      contains('stage receipt is not a regular file · not read'),
    );
    expect(text.toString(), isNot(contains('do not read or remove')));
    expect(outsideReceipt.readAsStringSync(), 'do not read or remove');
    expect(store.inventory(), hasLength(2));
  });

  test(
    'the authorized preview excludes release mutation through the prompt',
    () async {
      final repository = Directory('${scratch.path}/clean-locked-preview')
        ..createSync();
      final store = StageStore(repository.path);
      Directory('${store.path}/only').createSync(recursive: true);
      final output = Output(
        sink: (_) {},
        isTerminal: false,
        report: Report('clean'),
      );

      final code = await CleanCommand(
        store: store,
        output: output,
        yes: false,
        confirm: (_) async {
          final probe = await Process.run(Platform.resolvedExecutable, [
            'run',
            'test/stage_store_lock_process.dart',
            repository.path,
            'try',
          ], workingDirectory: Directory.current.path);
          expect(probe.exitCode, 0, reason: '${probe.stdout}\n${probe.stderr}');
          expect((probe.stdout as String).trim(), 'busy');
          return 'no';
        },
      ).run();

      expect(code, 1);
      expect(Directory('${store.path}/only').existsSync(), isTrue);
    },
  );

  test('review-time drift refuses before deleting the frozen set', () async {
    final repository = Directory('${scratch.path}/clean-partial')..createSync();
    final store = StageStore(repository.path);
    Directory('${store.path}/a-first').createSync(recursive: true);
    final changed = File('${store.path}/b-changed')
      ..createSync()
      ..writeAsStringSync('file');
    final output = Output(
      sink: (_) {},
      isTerminal: false,
      report: Report('clean'),
    );

    final code = await CleanCommand(
      store: store,
      output: output,
      yes: false,
      confirm: (_) async {
        changed.deleteSync();
        Directory(changed.path).createSync();
        return 'yes';
      },
    ).run();
    final json = jsonDecode(output.report.encode(exit: code)) as Map;

    expect(code, 1);
    expect(json['cleanup'], {
      'root': store.repositoryRoot,
      'path': '.rk/work/stages',
      'found': 2,
      'removed': 0,
    });
    expect(Directory('${store.path}/a-first').existsSync(), isTrue);
    expect(Directory(changed.path).existsSync(), isTrue);
  });

  test('an empty repository is a successful no-op and creates nothing', () {
    final repo = Rk.repository(scratch, 'clean-empty', {});

    final run = repo(['clean']);

    expect(run.code, 0, reason: run.all);
    expect(run.all, contains('no staged release work'));
    expect(Directory('${repo.root}/.rk').existsSync(), isFalse);
  });

  test('clean takes no unit', () {
    final repo = Rk.repository(scratch, 'clean-scope', {});

    final run = repo(['clean', 'unit', '--json']);

    expect(run.code, 2, reason: run.all);
    expect(run.problems.map((problem) => problem['code']), ['RK-CLI-007']);
    expect(run.all, contains('rk clean takes no unit'));
  });
}

StageEntry _writeReceipt(StageStore store, {required bool complete}) {
  final plan = <String, Object?>{
    'unit': {'name': 'tool', 'version': '1.2.3'},
  };
  final identity = StageIdentity.forPlan(
    headCommit: complete
        ? '1111111111111111111111111111111111111111'
        : '2222222222222222222222222222222222222222',
    headTree: '3333333333333333333333333333333333333333',
    resolvedPlan: plan,
  );
  final directory = Directory('${store.path}/${identity.id}')
    ..createSync(recursive: true);
  final receipt = StageReceipt(
    identity: identity,
    plan: plan,
    steps: [if (complete) StageStep(name: 'complete-stage', outputs: const [])],
  );
  File('${directory.path}/stage.json').writeAsStringSync(receipt.encode());
  return StageEntry(name: identity.id, type: FileSystemEntityType.directory);
}
