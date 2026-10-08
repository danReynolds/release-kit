import 'dart:io';

import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/file_mode.dart';
import 'package:rk/src/engine/producer_lane.dart';
import 'package:rk/src/engine/resolve.dart';
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

  group('a lane exports what its build reads', () {
    const repository = {
      'README.md': '# A repository\n',
      'analysis_options.yaml': 'linter:\n',
      'docs/guide.md': '# Nothing builds this\n',
      'packages/README.md': '# Packages\n',
      'packages/app/pubspec.yaml':
          'name: app\nversion: 1.0.0\nexecutables:\n  app:\n',
      'packages/app/bin/app.dart': 'void main() {}\n',
      'packages/core/pubspec.yaml': 'name: core\nversion: 1.0.0\n',
      'packages/core/lib/core.dart': 'library;\n',
      'packages/core/tool/data.txt': 'core data\n',
      'tools/script/pubspec.yaml': 'name: script\n',
      'tools/script/bin/script.dart': 'void main() {}\n',
      'native/parser/Cargo.toml':
          '[package]\nname = "parser"\nversion = "1.0.0"\n',
      'native/parser/src/lib.rs': '',
    };

    Future<List<String>> exported(String unit) async {
      final tree = MemorySourceTree(repository);
      final diagnostics = Diagnostics();
      final resolution = Resolution.resolve(
        ReleaseConfig.parse(
          '''
schema = 2

[release.app]
path = "packages/app"
binary_platforms = ["linux-x64"]

[release.parser]
path = "native/parser"
publish = ["git-tag", "github-release"]
build = ["tool/build.sh", "{out}"]
assets = ["parser.so"]
''',
          'release.toml',
          diagnostics,
        )!,
        tree,
        diagnostics,
      )!;
      expect(diagnostics.found, isEmpty);
      final lane = ProducerLaneSource.export(
        await StageSourceSnapshot.capture(tree),
        project: resolution.unit(unit)!.projects.single,
      );
      addTearDown(lane.close);
      return [
        for (final entry in Directory(lane.path).listSync(recursive: true))
          if (entry is File) entry.path.substring(lane.path.length + 1),
      ]..sort();
    }

    test('a Dart build: its packages, every pubspec, and what sits above '
        'its own', () async {
      expect(await exported('app'), [
        'README.md',
        'analysis_options.yaml',
        'packages/README.md',
        'packages/app/bin/app.dart',
        'packages/app/pubspec.yaml',
        'packages/core/lib/core.dart',
        'packages/core/pubspec.yaml',
        'packages/core/tool/data.txt',
        'tools/script/bin/script.dart',
        'tools/script/pubspec.yaml',
      ]);
    });

    test('a project\'s own build: everything, since rk cannot know what it '
        'reads', () async {
      expect(await exported('parser'), [...repository.keys]..sort());
    });
  });

  test('an export adds what it selects beside what is there', () async {
    final snapshot = await StageSourceSnapshot.capture(
      MemorySourceTree({
        'pubspec.yaml': 'name: root\n',
        'a/pubspec.yaml': 'name: a\n',
        'a/lib/a.dart': 'library;\n',
        'b/lib/b.dart': 'library;\n',
        'c/notes.txt': 'not read\n',
      }),
    );
    final root = Directory.systemTemp.createTempSync('rk-source-scope-');
    addTearDown(() => root.deleteSync(recursive: true));
    snapshot.export(root.path, only: StageSourceSnapshot.dartBuildInputs('a'));
    snapshot.export(root.path, only: (path) => path.startsWith('b/'));
    expect(
      [
        for (final entry in root.listSync(recursive: true))
          if (entry is File) entry.path.substring(root.path.length + 1),
      ]..sort(),
      ['a/lib/a.dart', 'a/pubspec.yaml', 'b/lib/b.dart', 'pubspec.yaml'],
    );
    expect(snapshot.packageDirectories, {'.', 'a'});
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
