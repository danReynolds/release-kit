import 'dart:io';

import 'package:rk/src/engine/file_mode.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/stage_source.dart';
import 'package:test/test.dart';

void main() {
  test('committed source keeps Git modes and ignores worktree edits', () async {
    final root = Directory.systemTemp.createTempSync('rk-source-authority-');
    addTearDown(() => root.deleteSync(recursive: true));
    Future<String> git(List<String> args) async {
      final result = await Process.run(
        'git',
        args,
        workingDirectory: root.path,
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      return '${result.stdout}'.trim();
    }

    await git(['init', '--quiet']);
    File('${root.path}/run').writeAsStringSync('#!/bin/sh\nexit 0\n');
    File('${root.path}/nested/data')
      ..parent.createSync()
      ..writeAsBytesSync([0, 1, 255]);
    await git(['add', '--', 'run', 'nested/data']);
    await git(['update-index', '--chmod=+x', 'run']);
    await git([
      '-c',
      'user.name=RK fixture',
      '-c',
      'user.email=fixture@example.test',
      '-c',
      'commit.gpgsign=false',
      'commit',
      '--quiet',
      '-m',
      'source',
    ]);
    final commit = await git(['rev-parse', 'HEAD']);
    File('${root.path}/run').writeAsStringSync('dirty replacement');
    setFileModes({
      '${root.path}/run': '0644',
      '${root.path}/nested/data': '0755',
    });
    final snapshot = await StageSourceSnapshot.capture(
      GitSourceTree(root.path),
      commit: commit,
    );
    expect(snapshot.trackedFiles(), ['nested/data', 'run']);
    expect(snapshot.read('run'), '#!/bin/sh\nexit 0\n');
    expect(snapshot.readBytes('nested/data'), [0, 1, 255]);

    final export = Directory.systemTemp.createTempSync('rk-source-export-');
    addTearDown(() => export.deleteSync(recursive: true));
    snapshot.export(export.path);
    final run = File('${export.path}/run');
    final data = File('${export.path}/nested/data');
    expect(run.readAsStringSync(), '#!/bin/sh\nexit 0\n');
    expect(data.readAsBytesSync(), [0, 1, 255]);
    expect(posixMode(run.statSync().mode), '0755');
    expect(posixMode(data.statSync().mode), '0644');

    await expectLater(
      StageSourceSnapshot.capture(
        GitCommitSourceTree(root.path, commit),
        commit: 'f' * 40,
      ),
      throwsStateError,
    );
    await expectLater(
      StageSourceSnapshot.capture(snapshot, commit: 'f' * 40),
      throwsStateError,
    );
  });

  test('an owned source snapshot stays immutable', () async {
    final source = MemorySourceTree({'file': 'original'});
    final pending = StageSourceSnapshot.capture(source);
    source.files['file'] = 'later';
    source.files['added'] = 'later';
    final snapshot = await pending;
    expect(snapshot.read('file'), 'original');
    expect(snapshot.trackedFiles(), ['file']);
    expect(() => snapshot.readBytes('file')![0] = 0, throwsUnsupportedError);
  });
}
