import 'dart:convert';
import 'dart:io';

import 'package:rk/src/engine/stage_store.dart';
import 'package:test/test.dart';

void main() {
  late Directory scratch;
  late Directory repository;
  late StageStore store;

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('rk-stage-store-');
    repository = Directory('${scratch.path}/repository')..createSync();
    store = StageStore(repository.path);
  });

  tearDown(() {
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  });

  test('a missing store is empty and inspection creates nothing', () {
    final inventory = store.inventory();

    expect(inventory, isEmpty);
    expect(Directory('${repository.path}/.rk').existsSync(), isFalse);
  });

  test('inventory is immediate, no-follow, and deterministically sorted', () {
    final stages = Directory(store.path)..createSync(recursive: true);
    Directory('${stages.path}/b').createSync();
    File('${stages.path}/a').writeAsStringSync('orphan');
    final outside = Directory('${scratch.path}/outside')..createSync();
    Link('${stages.path}/c').createSync(outside.path);

    final inventory = store.inventory();

    expect(inventory.map((entry) => entry.name), ['a', 'b', 'c']);
    expect(inventory.map((entry) => entry.type), [
      FileSystemEntityType.file,
      FileSystemEntityType.directory,
      FileSystemEntityType.link,
    ]);
  });

  test('deletion removes the frozen set and preserves a later sibling', () {
    final stages = Directory(store.path)..createSync(recursive: true);
    Directory('${stages.path}/first')
      ..createSync()
      ..createTempSync('nested-');
    final inventory = store.inventory();
    Directory('${stages.path}/later').createSync();

    expect(inventory.where(store.deleteEntry).length, 1);
    expect(Directory('${stages.path}/first').existsSync(), isFalse);
    expect(Directory('${stages.path}/later').existsSync(), isTrue);
  });

  test('a child link is unlinked without touching its target', () {
    final stages = Directory(store.path)..createSync(recursive: true);
    final outside = Directory('${scratch.path}/outside')..createSync();
    final sentinel = File('${outside.path}/sentinel')
      ..writeAsStringSync('safe');
    final link = Link('${stages.path}/orphan')..createSync(outside.path);
    final inventory = store.inventory();

    expect(inventory.where(store.deleteEntry).length, 1);
    expect(link.existsSync(), isFalse);
    expect(sentinel.readAsStringSync(), 'safe');
  });

  test('a fixed path link is refused rather than followed', () {
    final outside = Directory('${scratch.path}/outside')..createSync();
    Link('${repository.path}/.rk').createSync(outside.path);

    expect(store.inventory, throwsA(isA<StageStoreUnsafe>()));
    expect(outside.existsSync(), isTrue);
  });

  test('a changed entry type shrinks rather than expands deletion', () {
    final stages = Directory(store.path)..createSync(recursive: true);
    final entry = File('${stages.path}/candidate')..writeAsStringSync('old');
    final inventory = store.inventory();
    entry.deleteSync();
    Directory(entry.path).createSync();

    expect(inventory.where(store.deleteEntry), isEmpty);
    expect(Directory(entry.path).existsSync(), isTrue);
  });

  test('another process holding the store lock excludes cleanup', () async {
    final process = await Process.start(
      Platform.resolvedExecutable,
      ['run', 'test/stage_store_lock_process.dart', repository.path],
      workingDirectory: Directory.current.path,
    );
    final ready = await process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first;
    expect(ready, 'locked');
    addTearDown(() {
      process.kill();
    });

    expect(
      store.acquireForMutation,
      throwsA(isA<StageStoreBusy>()),
    );

    process.stdin.writeln('done');
    await process.stdin.close();
    expect(await process.exitCode, 0);
  });
}
