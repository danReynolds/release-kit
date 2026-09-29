import 'dart:io';

import 'package:test/test.dart';

import 'rk_process.dart';

/// Exercise the real command boundary against a disposable Git destination.
/// No published package, credentials, or network are needed for a tag-only unit.
void main() {
  late Directory scratch;

  setUp(() => scratch = Directory.systemTemp.createTempSync('rk-stage-cli-'));
  tearDown(() => scratch.deleteSync(recursive: true));

  Rk repository({bool multiple = false}) {
    final repo = Rk.repository(scratch, 'source', {
      '.gitignore': '.rk/\n',
      'release.toml':
          '''
schema = 2

[release.core]
path = "packages/core"
tag = "core-v{version}"
publish = ["git-tag"]
${multiple ? '''
[release.tools]
path = "packages/tools"
tag = "tools-v{version}"
publish = ["git-tag"]
''' : ''}
''',
      for (final name in ['core', if (multiple) 'tools']) ...{
        'packages/$name/pubspec.yaml':
            'name: $name\nversion: 1.0.0\npublish_to: none\n',
        'packages/$name/CHANGELOG.md': '## 1.0.0\n\nFirst release.\n',
      },
    });
    _git(repo.root, ['config', 'commit.gpgSign', 'false']);
    _git(repo.root, ['config', 'tag.gpgSign', 'false']);
    _git(repo.root, ['config', 'user.signingkey', '']);
    repo.commit();
    final remote = '${scratch.path}/origin.git';
    _git(scratch.path, ['init', '--bare', remote]);
    _git(repo.root, ['remote', 'add', 'origin', remote]);
    _git(repo.root, ['push', '-u', 'origin', 'HEAD']);
    return repo;
  }

  void expectNoTags(Rk repo) {
    expect(_git(repo.root, ['tag', '--list']), isEmpty);
    expect(_git(repo.root, ['ls-remote', '--tags', 'origin']), isEmpty);
  }

  Map<String, Object?> stageEvidence(Run run, String unit) {
    final completed = run
        .stepsOf(unit)
        .singleWhere((step) => step['kind'] == 'completeStage');
    return completed['evidence'] as Map<String, Object?>;
  }

  test(
    'stage and the legacy alias share a private stage; release reuses it',
    () {
      final repo = repository();
      final staged = repo(['stage', '--json']);
      expect(staged.code, 0, reason: staged.all);
      expect(staged.json['command'], 'stage');
      expect(staged.json, isNot(contains('mode')));
      expect(staged.json['next'], ['rk release core']);
      final evidence = stageEvidence(staged, 'core');
      expect(evidence['stage id'], isNotEmpty);
      expect(
        Directory('${repo.root}/${evidence['stage path']}').existsSync(),
        isTrue,
      );
      expectNoTags(repo);

      final alias = repo(['release', 'core', '--stage', '--json']);
      expect(alias.code, 0, reason: alias.all);
      expect(alias.json['command'], 'release');
      expect(alias.json['mode'], {'stage': true});
      expect(stageEvidence(alias, 'core'), evidence);
      expect(
        alias.stepsOf('core').where((step) => step['action'] == 'attempted'),
        isEmpty,
      );
      expectNoTags(repo);

      // A full release uses the same evidence and still requires authorization.
      final release = repo(['release', 'core', '--json']);
      expect(release.code, 1, reason: release.all);
      expect(release.json['mode'], {'stage': false});
      expect(release.problems.single['code'], 'RK-AUTH-001');
      expect(stageEvidence(release, 'core')['stage id'], evidence['stage id']);
      expectNoTags(repo);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'stage requires a unit when ambiguous and stages only the named unit',
    () {
      final repo = repository(multiple: true);
      for (final args in [
        ['stage', '--json'],
        ['release', '--stage', '--json'],
      ]) {
        final refused = repo(args);
        expect(refused.code, 2, reason: refused.all);
        expect(refused.problems.single['code'], 'RK-CLI-004');
        expect(refused.problems.single['remedy'], contains('rk stage <unit>'));
        expect(refused.units, isEmpty);
        expectNoTags(repo);
      }

      final named = repo(['stage', 'tools', '--json']);
      expect(named.code, 0, reason: named.all);
      expect(named.units.map((unit) => unit['name']), ['tools']);
      expect(stageEvidence(named, 'tools')['stage id'], isNotEmpty);
      expect(named.json['next'], ['rk release tools']);
      expectNoTags(repo);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

String _git(String root, List<String> args) {
  final result = Process.runSync('git', args, workingDirectory: root);
  expect(
    result.exitCode,
    0,
    reason: 'git $args: ${result.stdout}${result.stderr}',
  );
  return (result.stdout as String).trim();
}
