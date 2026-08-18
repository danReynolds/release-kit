import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:rk/src/engine/checklist.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/git.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/stage.dart';
import 'package:rk/src/engine/stage_inspection.dart';
import 'package:rk/src/transforms/archive.dart';
import 'package:rk/src/transforms/digest.dart';

/// Times the local work a release does, so a slow path is visible.
///
/// This exists because one was not: staging read the source snapshot with a
/// `git show` per tracked file, which cost seconds and looked like a hang.
/// Nothing failed, no test was wrong, and no output said so — the only
/// symptom was a person waiting. A number printed beside each step is what
/// makes that kind of mistake visible before somebody feels it.
///
///   dart run tool/bench.dart [path]
///
/// It measures only local work: git plumbing, hashing, resolution, and
/// archiving. Nothing here touches the network, because a benchmark whose
/// numbers move with someone's connection teaches nothing.
///
/// Like `tool/validate.dart`, this asserts almost nothing. Machines differ,
/// and a threshold tuned on one is a false alarm on another. It prints what
/// each step cost and what that works out to per unit of work; a person
/// reads it and decides. What matters is the shape: an operation that is
/// hundreds of times slower than its neighbours is doing something wrong.
Future<void> main(List<String> args) async {
  final root = args.isEmpty ? Directory.current.path : args.first;
  final gitRoot = GitSourceTree.findRoot(root);
  if (gitRoot == null) {
    stderr.writeln('bench needs a Git repository: $root is not one');
    exitCode = 2;
    return;
  }

  final report = _Report();
  stdout.writeln('rk bench · ${gitRoot.split('/').last}\n');

  // ---- the repository ----

  final git = await report.timeAsync(
    'read repository state',
    () => GitState.read(gitRoot),
    detail: '11 git questions, concurrent',
  );
  final head = git.head;
  final tree = GitSourceTree(gitRoot);

  final entries = report.time(
    'list tracked files',
    () => tree.trackedEntriesAt(head),
  );
  final paths = [for (final entry in entries) entry.path]..sort();
  report.note('tracked files', '${paths.length}');

  // ---- the source snapshot ----
  //
  // The batched read against the same work done one file at a time. The
  // ratio is the point: this is the shape of the bug that prompted the tool.

  final blobs = await report.timeAsync(
    'read every blob (batched)',
    () => tree.readBytesBatchAt(head, paths),
    detail: 'one git cat-file --batch',
  );
  final bytes = blobs.values.fold<int>(0, (sum, blob) => sum + blob.length);
  report.note('snapshot size', _size(bytes));

  final sample = paths.take(20).toList();
  final perFile = report.measure(
    'read 20 blobs (one call each)',
    () {
      for (final path in sample) {
        tree.readBytesAt(head, path);
      }
    },
    detail: 'the same work, unbatched',
  );
  report.note(
    'unbatched, extrapolated',
    '${(perFile.inMilliseconds * paths.length / sample.length).round()}ms '
        'for ${paths.length} files',
  );

  // ---- hashing ----
  //
  // Every staged byte is hashed at least once, and the archives are hashed
  // again whenever the stage is re-inspected, so throughput here multiplies.

  final assembling = BytesBuilder(copy: false);
  for (final blob in blobs.values) {
    assembling.add(blob);
  }
  final snapshot = assembling.takeBytes();
  report.rate('hash the snapshot', () => Sha256.hex(snapshot), snapshot.length);

  final archiveSized = Uint8List(3300000);
  for (var i = 0; i < archiveSized.length; i++) {
    archiveSized[i] = i & 0xff;
  }
  report.rate(
    'hash an archive-sized buffer',
    () => Sha256.hex(archiveSized),
    archiveSized.length,
  );

  // ---- the plan ----

  final source = tree.read('release.toml');
  if (source != null) {
    final diagnostics = Diagnostics();
    final config = report.time(
      'parse release.toml',
      () => ReleaseConfig.parse(source, 'release.toml', diagnostics),
    );
    if (config != null) {
      final resolution = report.time(
        'resolve the repository',
        () => Resolution.resolve(config, tree, diagnostics),
        detail: 'reads every project manifest',
      );
      if (resolution != null) {
        report.time(
          'derive every checklist',
          () {
            for (final unit in resolution.units) {
              Checklist.derive(unit, resolution, Diagnostics());
            }
          },
          detail: '${resolution.units.length} unit(s)',
        );
      }
    }
  }

  // ---- the stage ----
  //
  // Verifying a built stage re-reads and re-hashes every artifact in it.
  // A release does that many times over, so this row is the one that
  // multiplies hardest; it needs a stage on disk to measure.

  final stages = Directory('$gitRoot/.rk/work/stages');
  final built = stages.existsSync()
      ? stages
          .listSync()
          .whereType<Directory>()
          .where((each) => File('${each.path}/stage.json').existsSync())
          .toList()
      : <Directory>[];
  if (built.isEmpty) {
    report.note('verify a built stage', 'none on disk — rk release --stage');
  } else {
    final newest = built.reduce((left, right) =>
        left.statSync().modified.isAfter(right.statSync().modified)
            ? left
            : right);
    final recorded =
        jsonDecode(File('${newest.path}/stage.json').readAsStringSync());
    final identity = StageIdentity.fromJson(
      (recorded as Map<String, Object?>)['stage'],
    );
    final size = newest
        .listSync(recursive: true)
        .whereType<File>()
        .fold<int>(0, (sum, file) => sum + file.lengthSync());
    final directory =
        StageDirectory(repositoryRoot: gitRoot, identity: identity);
    report.time(
      'verify a built stage',
      () => const StageInspector().inspect(directory),
      detail: '${_size(size)} re-read and re-hashed',
    );
    report.time(
      'fingerprint that stage',
      directory.fingerprint,
      detail: 'the cheap check that skips the re-read',
    );
  }

  // ---- artifacts ----

  final tar = report.time(
    'tar an archive-sized file',
    () => ArchiveBuilder.tar([
      ArchiveEntry(name: 'rk', bytes: archiveSized, executable: true),
    ]),
  );
  report.rate(
    'gzip the same archive',
    () => ArchiveBuilder.gzip(tar),
    archiveSized.length,
  );

  stdout.writeln();
  report.conclude();
}

class _Report {
  final _rows = <_Row>[];

  /// Times work whose result is not needed, returning what it cost.
  Duration measure(String what, void Function() run, {String? detail}) {
    final clock = Stopwatch()..start();
    run();
    clock.stop();
    _rows.add(_Row(what, clock.elapsed, detail));
    _print(_rows.last);
    return clock.elapsed;
  }

  T time<T>(String what, T Function() run, {String? detail}) {
    final clock = Stopwatch()..start();
    final value = run();
    clock.stop();
    _rows.add(_Row(what, clock.elapsed, detail));
    _print(_rows.last);
    return value;
  }

  Future<T> timeAsync<T>(
    String what,
    Future<T> Function() run, {
    String? detail,
  }) async {
    final clock = Stopwatch()..start();
    final value = await run();
    clock.stop();
    _rows.add(_Row(what, clock.elapsed, detail));
    _print(_rows.last);
    return value;
  }

  void rate(String what, void Function() run, int bytes) {
    final clock = Stopwatch()..start();
    run();
    clock.stop();
    final seconds = clock.elapsedMicroseconds / 1000000;
    final perSecond = seconds == 0 ? 0.0 : bytes / seconds;
    _rows.add(_Row(what, clock.elapsed, '${_size(perSecond.round())}/s'));
    _print(_rows.last);
  }

  void note(String what, String value) {
    stdout.writeln('  ${what.padRight(34)}${''.padLeft(9)}  $value');
  }

  void _print(_Row row) {
    final took = '${row.took.inMicroseconds / 1000}'.padLeft(8);
    stdout.writeln('  ${row.what.padRight(34)}${took}ms'
        '${row.detail == null ? '' : '  ${row.detail}'}');
  }

  void conclude() {
    final total = _rows.fold(Duration.zero, (sum, row) => sum + row.took);
    stdout.writeln('  ${'total local work'.padRight(34)}'
        '${'${total.inMilliseconds}'.padLeft(8)}ms');
    stdout.writeln('\n  No network, so these are the parts of a release that '
        'are rk\'s own\n  doing. A step far slower than its neighbours is the '
        'one to look at.');
  }
}

class _Row {
  _Row(this.what, this.took, this.detail);

  final String what;
  final Duration took;
  final String? detail;
}

String _size(int bytes) {
  if (bytes >= 1000000) return '${(bytes / 1000000).toStringAsFixed(1)}MB';
  if (bytes >= 1000) return '${(bytes / 1000).toStringAsFixed(1)}kB';
  return '${bytes}B';
}
