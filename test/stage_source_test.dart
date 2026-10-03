import 'dart:convert';
import 'dart:io';

import 'package:rk/src/engine/canonical_json.dart';
import 'package:rk/src/engine/file_mode.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/stage.dart';
import 'package:rk/src/engine/stage_receipt.dart';
import 'package:rk/src/engine/stage_source.dart';
import 'package:test/test.dart';

void main() {
  test(
    'committed source inventory preserves Git modes and ignores worktree edits',
    () async {
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
      File('${root.path}/data').writeAsBytesSync([0, 1, 255]);
      await git(['add', '--', 'run', 'data']);
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
      final tree = await git(['rev-parse', 'HEAD^{tree}']);
      final snapshot = await StageSourceSnapshot.capture(
        GitCommitSourceTree(root.path, commit),
        commit: commit,
      );
      File('${root.path}/run').writeAsStringSync('dirty replacement');
      setFileModes({'${root.path}/run': '0644', '${root.path}/data': '0755'});
      final fromRepository = await StageSourceSnapshot.capture(
        GitSourceTree(root.path),
        commit: commit,
      );
      expect(
        CanonicalJson.encode(
          fromRepository.artifacts.map((a) => a.toJson()).toList(),
        ),
        CanonicalJson.encode(
          snapshot.artifacts.map((a) => a.toJson()).toList(),
        ),
      );
      expect(snapshot.artifacts.map((a) => a.mode), ['0644', '0755']);
      expect(snapshot.readBytes('data'), [0, 1, 255]);
      final plan = <String, Object?>{'unit': 'source-fixture'};
      final identity = StageIdentity.forPlan(
        headCommit: commit,
        headTree: tree,
        resolvedPlan: plan,
      );
      final stage = StageDirectory(
        repositoryRoot: root.path,
        identity: identity,
      );
      final recaptured = await StageSourceSnapshot.capture(
        snapshot,
        commit: commit,
      );
      final outputs = recaptured.materialize(stage);
      expect(outputs.map((a) => a.mode), ['0644', '0755']);
      final receipt = StageReceipt(
        identity: identity,
        plan: plan,
        steps: [StageStep(name: 'source-snapshot', outputs: outputs)],
      );
      snapshot.requireReceipt(receipt);
      expect(
        () => snapshot.requireReceipt(
          StageReceipt(
            identity: StageIdentity.forPlan(
              headCommit: 'f' * 40,
              headTree: tree,
              resolvedPlan: plan,
            ),
            plan: plan,
            steps: const [],
          ),
        ),
        throwsStateError,
      );
      // A portable source proof must continue to work without its old directory.
      Directory(stage.path).deleteSync(recursive: true);
      snapshot.requireReceipt(receipt);
      for (final change in [
        'mode',
        'missing',
        'extra',
        'hash',
        'type',
        'size',
      ]) {
        final encoded =
            jsonDecode(
                  CanonicalJson.encode(outputs.map((a) => a.toJson()).toList()),
                )
                as List;
        switch (change) {
          case 'mode':
            encoded.last['mode'] = '0644';
          case 'missing':
            encoded.removeLast();
          case 'extra':
            encoded.add({...encoded.first as Map, 'path': 'source/planted'});
          case 'hash':
            encoded.first['sha256'] = 'f' * 64;
          case 'type':
            encoded.first['type'] = 'asset';
          case 'size':
            encoded.first['size'] = 4;
        }
        expect(
          () => snapshot.requireReceipt(
            StageReceipt(
              identity: identity,
              plan: plan,
              steps: [
                StageStep(
                  name: 'source-snapshot',
                  outputs: encoded.map(StageArtifact.fromJson),
                ),
              ],
            ),
          ),
          throwsStateError,
          reason: change,
        );
      }
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
    },
  );

  test(
    'owned source snapshot stays immutable and pending headers claim no source',
    () async {
      final source = MemorySourceTree({'file': 'original'});
      final pending = StageSourceSnapshot.capture(source);
      source.files['file'] = 'later';
      source.files['added'] = 'later';
      final snapshot = await pending;
      expect(snapshot.read('file'), 'original');
      expect(snapshot.trackedFiles(), ['file']);
      expect(() => snapshot.readBytes('file')![0] = 0, throwsUnsupportedError);
      final plan = <String, Object?>{'unit': 'fixture'};
      snapshot.requireReceipt(
        StageReceipt(
          identity: StageIdentity.forUnboundPlan(
            runId: 'source-capture',
            resolvedPlan: plan,
          ),
          plan: plan,
          steps: const [],
        ),
      );
    },
  );
}
