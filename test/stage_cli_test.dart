import 'dart:convert';
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
    'stage is reusable and release still requires publication approval',
    () {
      final repo = repository(multiple: true);
      final staged = repo(['stage', 'core', '--json']);
      expect(staged.code, 0, reason: staged.all);
      expect(staged.json['rk'], 12);
      expect(staged.json['command'], 'stage');
      expect(staged.units.map((unit) => unit['name']), ['core']);
      expect(staged.json['next'], ['rk release core']);
      final evidence = stageEvidence(staged, 'core');
      expect(evidence['stage id'], isNotEmpty);
      expect(
        Directory('${repo.root}/${evidence['stage path']}').existsSync(),
        isTrue,
      );
      expect(
        Directory(
          '${repo.root}/.rk/work/stages',
        ).listSync().whereType<Directory>(),
        hasLength(1),
        reason: 'a named stage prepares that unit alone',
      );
      expectNoTags(repo);

      // A bare stage prepares every unit, and reuses the one already staged.
      final all = repo(['stage', '--json']);
      expect(all.code, 0, reason: all.all);
      expect(all.units.map((unit) => unit['name']), ['core', 'tools']);
      expect(stageEvidence(all, 'core'), evidence);
      expect(
        all.stepsOf('core').where((step) => step['action'] == 'attempted'),
        isEmpty,
      );
      expect(stageEvidence(all, 'tools')['stage id'], isNotEmpty);
      expectNoTags(repo);

      // A full release uses the same evidence and still requires authorization.
      final release = repo(['release', 'core', '--json']);
      expect(release.code, 1, reason: release.all);
      expect(release.json['command'], 'release');
      expect(release.problems.single['code'], 'RK-AUTH-001');
      expect(stageEvidence(release, 'core')['stage id'], evidence['stage id']);
      expectNoTags(repo);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    '--timings says where a stage went without changing the plain report',
    () {
      final repo = repository();
      final traceFile = File('${repo.root}/.rk/timings.json');

      final timed = repo(['stage', '--json', '--timings']);
      expect(timed.code, 0, reason: timed.all);

      // The breakdown goes to stderr, so stdout stays one JSON document.
      expect(timed.json['command'], 'stage');
      expect(timed.stderr, contains('Timings'));
      expect(timed.stderr, contains('preparing'));
      expect(timed.stderr, contains('Total'));
      expect(
        timed.stderr,
        matches(RegExp(r'rk: wrote timings to /\S+/\.rk/timings\.json')),
      );

      final trace = jsonDecode(traceFile.readAsStringSync()) as Map;
      final slices = (trace['traceEvents'] as List).where(
        (event) => (event as Map)['ph'] == 'X',
      );
      expect(
        slices.map((slice) => (slice as Map)['name']),
        contains('preparing'),
      );

      // It is written only as a plain file in rk's own directory, never
      // through a link that could point outside the repository.
      final outside = File('${scratch.path}/outside.json');
      traceFile.deleteSync();
      Link(traceFile.path).createSync(outside.path);
      final linked = repo(['stage', '--json', '--timings']);
      expect(linked.code, 0, reason: linked.all);
      expect(linked.stderr, contains('did not write timings'));
      expect(outside.existsSync(), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('a released unit stays released while its own files are unchanged', () {
    final repo = repository(multiple: true);
    final core = repo(['release', 'core', '--yes', '--json']);
    expect(core.code, 0, reason: core.all);

    // A later commit that changes only the other unit.
    File(
      '${repo.root}/packages/tools/CHANGELOG.md',
    ).writeAsStringSync('## 1.0.0\n\nFirst release, with notes.\n');
    _git(repo.root, ['commit', '-qam', 'tools notes']);
    _git(repo.root, ['push', '-q']);
    final both = repo(['release', '--yes', '--json']);
    expect(both.code, 0, reason: both.all);
    expect(
      _git(repo.root, ['ls-remote', '--tags', 'origin']),
      allOf(
        contains('refs/tags/core-v1.0.0'),
        contains('refs/tags/tools-v1.0.0'),
      ),
    );

    // A commit that changes core is new source for a version already out.
    File(
      '${repo.root}/packages/core/CHANGELOG.md',
    ).writeAsStringSync('## 1.0.0\n\nFirst release, amended.\n');
    _git(repo.root, ['commit', '-qam', 'core amended']);
    _git(repo.root, ['push', '-q']);
    final changed = repo(['release', '--yes', '--json']);
    expect(changed.code, isNot(0));
    expect(
      (changed.json['problems'] as List).map((p) => (p as Map)['code']),
      contains('RK-MONO-004'),
    );
  });

  group("a crate's own build", () {
    // A stand-in for gh, answering the three reads a stage makes of a
    // repository that has no releases yet, and a signed-in session. It
    // refuses everything else, so a release gets no further than its tag.
    const gh = r'''#!/bin/bash
case "$*" in
  "api repos/example/parser/releases/tags/"*)
    echo '{"message":"Not Found","status":"404"}'
    echo 'gh: Not Found (HTTP 404)' >&2
    exit 1;;
  "repo view example/parser --json name") echo '{"name":"parser"}';;
  "auth status --active --hostname github.com") ;;
  "api --paginate --slurp repos/example/parser/releases") echo '[[]]';;
  *) echo "unexpected gh $*" >&2; exit 2;;
esac
''';

    ({Rk repo, Map<String, String> environment}) crate(
      String build, {
      bool linksAgents = false,
    }) {
      final repo = Rk.repository(scratch, 'source', {
        '.gitignore': '.rk/\n',
        'release.toml': '''
schema = 2

[release.parser]
tag = "flark_parse-v{version}"
path = "native/parser"
publish = ["git-tag", "github-release"]
build = ["tool/build.sh", "{out}"]
assets = ["assets/parser-linux-x64.so", "parser-macos-arm64.dylib", "src.tar.gz"]
''',
        'native/parser/Cargo.toml':
            '[package]\nname = "flark_parse"\nversion = "0.1.0"\n',
        'native/parser/CHANGELOG.md': '## 0.1.0\n\nFirst release.\n',
        'native/parser/tool/build.sh': build,
      });
      Process.runSync('chmod', [
        '+x',
        '${repo.root}/native/parser/tool/build.sh',
      ]);
      if (linksAgents) {
        // The usual way a repository shares one agent guide.
        File('${repo.root}/AGENTS.md').writeAsStringSync('# Agents\n');
        Link('${repo.root}/CLAUDE.md').createSync('AGENTS.md');
      }
      _git(repo.root, ['config', 'commit.gpgSign', 'false']);
      _git(repo.root, ['config', 'tag.gpgSign', 'false']);
      _git(repo.root, ['config', 'user.signingkey', '']);
      repo.commit();
      // rk reads the forge's owner/name from origin's URL.
      final remote = '${scratch.path}/forge/github.com/example/parser.git';
      Directory(remote).createSync(recursive: true);
      _git(scratch.path, ['init', '--bare', remote]);
      _git(repo.root, ['remote', 'add', 'origin', remote]);
      _git(repo.root, ['push', '-u', 'origin', 'HEAD']);
      final bin = Directory('${scratch.path}/bin')..createSync();
      File('${bin.path}/gh').writeAsStringSync(gh);
      Process.runSync('chmod', ['+x', '${bin.path}/gh']);
      return (
        repo: repo,
        environment: {'PATH': '${bin.path}:${Platform.environment['PATH']}'},
      );
    }

    Map<String, Object?> problem(Run run, String code) =>
        (run.json['problems'] as List).cast<Map<String, Object?>>().singleWhere(
          (problem) => problem['code'] == code,
        );

    test('stages the files it declares, built from the committed source', () {
      final (:repo, :environment) = crate(r'''#!/bin/bash
set -euo pipefail
mkdir -p "$1/assets"
printf '%s %s %s %s' "$RK_SOURCE_COMMIT" "$RK_REPOSITORY" "$RK_VERSION" \
  "$RK_TAG" > "$1/assets/parser-linux-x64.so"
printf 'dylib' > "$1/parser-macos-arm64.dylib"
printf 'tarball' > "$1/src.tar.gz"
printf 'scratch' > "$1/unrelated.txt"
[ "$RK_OUT" = "$1" ]
''');
      final staged = repo([
        'stage',
        'parser',
        '--json',
      ], environment: environment);
      expect(staged.code, 0, reason: staged.all);
      final build = staged
          .stepsOf('parser')
          .singleWhere((step) => step['kind'] == 'buildAssets');
      expect(build['id'], 'parser/build/flark_parse');

      final stage =
          '${repo.root}/${stageEvidence(staged, 'parser')['stage path']}';
      expect(
        File(
          '$stage/producers/flark_parse/assets/parser-linux-x64.so',
        ).readAsStringSync(),
        '${_git(repo.root, ['rev-parse', 'HEAD'])} example/parser 0.1.0 '
        'flark_parse-v0.1.0',
        reason: 'the build is told what it is building',
      );
      expect(
        {
          for (final file in Directory(
            '$stage/producers',
          ).listSync(recursive: true).whereType<File>())
            file.path.substring(stage.length + 1),
        },
        {
          'producers/flark_parse/assets/parser-linux-x64.so',
          'producers/flark_parse/assets/parser-macos-arm64.dylib',
          'producers/flark_parse/assets/src.tar.gz',
        },
        reason: 'what the build wrote and did not declare stays behind',
      );
      final manifest =
          jsonDecode(File('$stage/release-manifest.json').readAsStringSync())
              as Map<String, Object?>;
      expect(
        [
          for (final artifact
              in (manifest['artifacts'] as List).cast<Map<String, Object?>>())
            (artifact['name'], artifact['type']),
        ],
        [
          ('parser-linux-x64.so', 'asset'),
          ('parser-macos-arm64.dylib', 'asset'),
          ('src.tar.gz', 'asset'),
        ],
        reason: 'an asset is an asset, whatever its file name says',
      );
      expectNoTags(repo);

      final repeat = repo([
        'stage',
        'parser',
        '--json',
      ], environment: environment);
      expect(repeat.code, 0, reason: repeat.all);
      expect(
        stageEvidence(repeat, 'parser')['stage id'],
        stageEvidence(staged, 'parser')['stage id'],
        reason: 'a complete stage is reused, not built again',
      );
    });

    test('stages a repository that tracks a symbolic link', () {
      final (:repo, :environment) = crate(r'''#!/bin/bash
set -euo pipefail
# The build sees the link as the repository has it.
[ "$(readlink ../../CLAUDE.md)" = "AGENTS.md" ]
mkdir -p "$1/assets"
printf 'so' > "$1/assets/parser-linux-x64.so"
printf 'dylib' > "$1/parser-macos-arm64.dylib"
printf 'tarball' > "$1/src.tar.gz"
''', linksAgents: true);
      expect(
        _git(repo.root, ['ls-files', '-s', 'CLAUDE.md']),
        startsWith('120000 '),
      );

      final staged = repo([
        'stage',
        'parser',
        '--json',
      ], environment: environment);
      expect(staged.code, 0, reason: staged.all);
    });

    test('refuses a submodule its build would go without', () {
      final (:repo, :environment) = crate(r'''#!/bin/bash
set -euo pipefail
mkdir -p "$1/assets"
printf 'so' > "$1/assets/parser-linux-x64.so"
printf 'dylib' > "$1/parser-macos-arm64.dylib"
printf 'tarball' > "$1/src.tar.gz"
''');
      // The commit records the submodule's commit, and none of its files;
      // the checkout has the empty directory of an uninitialized one.
      Directory('${repo.root}/native/parser/vendor').createSync();
      _git(repo.root, [
        'update-index',
        '--add',
        '--cacheinfo',
        '160000,${'a' * 40},native/parser/vendor',
      ]);
      _git(repo.root, ['commit', '-qm', 'vendor a parser library']);
      _git(repo.root, ['push', '-q', 'origin', 'HEAD']);

      final staged = repo([
        'stage',
        'parser',
        '--json',
      ], environment: environment);
      expect(staged.code, isNot(0), reason: staged.all);
      expect(
        problem(staged, 'RK-STAGE-003')['message'],
        allOf(contains('native/parser/vendor'), contains('flark_parse')),
      );
      expect(
        (staged.json['halt'] as Map)['kind'],
        'beforeActing',
        reason: 'nothing was built: re-running cannot get past it',
      );
    });

    test('finishes an interrupted release from the commit its tag names', () {
      final (:repo, :environment) = crate(r'''#!/bin/bash
set -euo pipefail
mkdir -p "$1/assets"
printf 'so' > "$1/assets/parser-linux-x64.so"
printf 'dylib' > "$1/parser-macos-arm64.dylib"
printf 'tarball' > "$1/src.tar.gz"
''');
      // The tag goes out, and the forge refuses the release.
      final interrupted = repo([
        'release',
        'parser',
        '--yes',
        '--json',
      ], environment: environment);
      expect(interrupted.code, isNot(0));
      expect(
        _git(repo.root, ['ls-remote', '--tags', 'origin']),
        contains('refs/tags/flark_parse-v0.1.0'),
      );

      // Later work that leaves the crate alone.
      File('${repo.root}/NOTES.md').writeAsStringSync('notes\n');
      _git(repo.root, ['add', 'NOTES.md']);
      _git(repo.root, ['commit', '-qm', 'notes']);
      _git(repo.root, ['push', '-q']);

      final resumed = repo([
        'release',
        'parser',
        '--yes',
        '--json',
      ], environment: environment);
      expect(resumed.code, isNot(0));
      final unfinished = problem(resumed, 'RK-GIT-009');
      expect(
        unfinished['message'],
        startsWith('flark_parse-v0.1.0 was released from '),
      );
      final tagged = _git(repo.root, ['rev-parse', 'flark_parse-v0.1.0^{}']);
      expect(
        unfinished['remedy'],
        contains('git checkout $tagged\n'),
        reason:
            'the tag binds what was staged at its commit; this commit\'s '
            'bytes must not be published under it',
      );

      // The remedy works: from the tagged commit the release carries on, and
      // gets as far as the forge again.
      _git(repo.root, ['checkout', '-q', tagged]);
      final recovered = repo([
        'release',
        'parser',
        '--yes',
        '--json',
      ], environment: environment);
      final codes = [
        for (final problem in recovered.json['problems'] as List)
          (problem as Map)['code'],
      ];
      expect(codes, isNot(contains('RK-GIT-009')));
      expect(codes, isNot(contains('RK-STAGE-005')));
      expect(recovered.all, contains('POST repos/example/parser/releases'));
    });

    test('refuses when the build fails, and keeps its whole account', () {
      final (:repo, :environment) = crate('''#!/bin/bash
exec >&2
for i in 1 2 3 4 5 6 7 8 9 10; do echo "step \$i"; done
echo "no compiler for the target"
exit 3
''');
      final run = repo(['stage', 'parser', '--json'], environment: environment);
      expect(run.code, isNot(0));
      expect(
        problem(run, 'RK-BUILD-003')['message'],
        'flark_parse: its build failed',
      );
      // The refusal shows the build's last lines; the diagnosis the run
      // leaves keeps all of them.
      final diagnosis = repo.diagnoses().single;
      final failed = (diagnosis['problems'] as List)
          .cast<Map<String, Object?>>()
          .singleWhere((problem) => problem['code'] == 'RK-BUILD-003');
      expect(
        (diagnosis['attachments'] as Map)[failed['evidence']],
        allOf(
          contains('step 1\nstep 2\nstep 3\n'),
          contains('no compiler for the target'),
        ),
      );
      expectNoTags(repo);
    });

    test('keeps what it caches from one stage to the next', () {
      final (:repo, :environment) = crate(r'''#!/bin/bash
set -euo pipefail
echo built >> "$RK_CACHE/builds"
mkdir -p "$1/assets"
printf 'so' > "$1/assets/parser-linux-x64.so"
printf 'dylib' > "$1/parser-macos-arm64.dylib"
cp "$RK_CACHE/builds" "$1/src.tar.gz"
''');
      final first = repo([
        'stage',
        'parser',
        '--json',
      ], environment: environment);
      expect(first.code, 0, reason: first.all);
      File(
        '${repo.root}/native/parser/CHANGELOG.md',
      ).writeAsStringSync('## 0.1.0\n\nThe first release.\n');
      repo.commit();
      _git(repo.root, ['push']);

      final second = repo([
        'stage',
        'parser',
        '--json',
      ], environment: environment);
      expect(second.code, 0, reason: second.all);
      expect(
        stageEvidence(second, 'parser')['stage id'],
        isNot(stageEvidence(first, 'parser')['stage id']),
      );
      final stage =
          '${repo.root}/${stageEvidence(second, 'parser')['stage path']}';
      expect(
        File(
          '$stage/producers/flark_parse/assets/src.tar.gz',
        ).readAsStringSync(),
        'built\nbuilt\n',
        reason: 'the second build finds what the first one kept',
      );
      expect(
        File(
          '${repo.root}/.rk/cache/parser/flark_parse/builds',
        ).readAsStringSync(),
        'built\nbuilt\n',
      );
    });
  });
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
