import 'dart:convert';
import 'dart:io';

import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/receipt.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/stage.dart';
import 'package:rk/src/engine/unit_release.dart';
import 'package:rk/src/engine/verdict.dart';
import 'package:rk/src/transforms/digest.dart';
import 'package:test/test.dart';

import 'support/memory_source_tree.dart';

const _commit = '1111111111111111111111111111111111111111';
const _tree = '2222222222222222222222222222222222222222';

const _binaryConfig = '''
schema = 2

[release.tool]
publish = ["git-tag", "github-release", "homebrew"]
binary_platforms = ["linux-x64", "macos-arm64"]
''';

void main() {
  late Directory root;
  late UnitRelease release;
  late Stage stage;

  setUp(() {
    root = Directory.systemTemp.createTempSync('rk-release-stage-');
    release = _derive(_binaryConfig, {
      'pubspec.yaml':
          'name: tool\nversion: 1.2.3\nexecutables:\n  tool: tool\n',
    }).single;
    stage = _stage(root, release);
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('lives at the content-addressed stages path', () {
    expect(stage.path, '${root.path}/.rk/work/stages/${stage.id.id}');
    expect(stage.relativePath, '.rk/work/stages/${stage.id.id}');
  });

  test('a stage begins with a receipt holding only its plan', () {
    expect(stage.check(release).state, StageState.absent);
    expect(
      stage.check(release).asInspection.detail,
      'stage.json: no completed stage receipt exists',
    );

    stage.begin();

    final check = stage.check(release);
    expect(check.state, StageState.resumable);
    expect(check.receipt!.plan, {'unit': 'tool'});
    expect(check.receipt!.producers, isEmpty);
    expect(check.asInspection.verdict, Verdict.absent);
  });

  test('recording work keeps each file it wrote and its evidence', () {
    stage.begin();
    final build = release.work.firstWhere(
      (work) => work.kind == StepKind.build,
    );
    for (final file in build.outputs) {
      stage.write(file, utf8.encode('bytes of $file'));
    }
    stage.record(
      build,
      evidence: {
        'smoke': {'status': 'passed'},
      },
    );

    final receipt = Receipt.parse(
      File(stage.pathOf('stage.json')).readAsStringSync(),
    );
    expect(receipt.producers[build.name], {
      'smoke': {'status': 'passed'},
    });
    expect(receipt.files.keys, build.outputs);
    final file = receipt.files[build.outputs.first]!;
    expect(file.producer, build.name);
    expect(
      file.sha256,
      Sha256.hex(utf8.encode('bytes of ${build.outputs.first}')),
    );
    expect(
      Directory(stage.path)
          .listSync(recursive: true)
          .where((entity) => entity.path.contains('.tmp.')),
      isEmpty,
      reason: 'the atomic rename leaves no writer temporary behind',
    );
  });

  test('a reused stage says again the warnings its work found', () {
    stage.begin();
    final notes = release.work.firstWhere(
      (work) => work.name == 'release-notes',
    );
    stage.write(notes.outputs.single, utf8.encode('notes'));
    stage.record(
      notes,
      warnings: const [
        Diagnostic(
          code: 'RK-PUB-012',
          message: 'pub validation reported one warning',
          remedy: 'review it before release',
        ),
      ],
    );

    final restored = Receipt.parse(
      File(stage.pathOf('stage.json')).readAsStringSync(),
    ).warnings(notes.name);
    expect(restored.single.code, 'RK-PUB-012');
    expect(restored.single.message, contains('one warning'));
    expect(restored.single.remedy, 'review it before release');
    expect(Receipt.parse(stage.receipt!.encode()).warnings('other'), isEmpty);
  });

  test('a complete stage is reusable, and says which stage it is', () {
    _stageAll(stage, release);

    final check = stage.check(release);
    expect(check.state, StageState.complete, reason: '${check.problems}');
    expect(check.receipt!.complete, isTrue);
    expect(check.asInspection.verdict, Verdict.exact);
    expect(check.asInspection.evidence, {'stage id': stage.id.id});
    expect(
      check.receipt!.files.keys,
      containsAll([for (final artifact in release.artifacts) artifact.path]),
    );
  });

  test('a stage is checked for what it publishes', () {
    _stageAll(stage, release);
    // The binary reaches the public only inside its archive, whose own bytes
    // are checked.
    final binary = release.work
        .firstWhere((work) => work.kind == StepKind.build)
        .outputs
        .first;
    File(stage.pathOf(binary)).deleteSync();
    stage.write('planted.txt', utf8.encode('nothing records this'));

    expect(stage.check(release).state, StageState.complete);
  });

  test('every file the release publishes is bound to its bytes', () {
    _stageAll(stage, release);

    for (final artifact in release.artifacts) {
      final file = File(stage.pathOf(artifact.path));
      final original = file.readAsBytesSync();
      _rewriteAfterAMoment(file, [...original, 0x7f]);

      final check = stage.check(release);
      expect(check.state, StageState.changed, reason: artifact.path);
      expect(check.problems, {
        artifact.path: 'artifact size, sha256 differs from the receipt',
      }, reason: artifact.path);
      expect(check.asInspection.verdict, Verdict.conflict);

      _rewriteAfterAMoment(file, original);
      expect(stage.check(release).reusable, isTrue, reason: artifact.path);
    }
  });

  test('a missing published file is a changed stage', () {
    _stageAll(stage, release);
    final archive = release.assets.first.path;
    File(stage.pathOf(archive)).deleteSync();

    final check = stage.check(release);
    expect(check.state, StageState.changed);
    expect(check.problems, {archive: 'receipt artifact is missing'});
  });

  test('a complete stage must record every file the release publishes', () {
    // What a stage records is named by its schema: an rk change that adds a
    // published file without bumping it finds the old stage incomplete.
    _stageAll(stage, release);
    final formula = release.homebrew!.files.single.path;
    final recorded = stage.receipt!;
    File(stage.pathOf('stage.json')).writeAsStringSync(
      Receipt(
        stage: recorded.stage,
        plan: recorded.plan,
        producers: recorded.producers,
        files: {...recorded.files}..remove(formula),
      ).encode(),
    );

    final check = stage.check(release);
    expect(check.state, StageState.changed);
    expect(check.problems, {formula: 'missing from the completed stage'});
  });

  test('an interrupted stage resumes only from the bytes it recorded', () {
    stage.begin();
    final work = release.work.where((work) => work.outputs.isNotEmpty).first;
    for (final file in work.outputs) {
      stage.write(file, utf8.encode('recorded'));
    }
    stage.record(work);
    expect(stage.check(release).state, StageState.resumable);

    _rewriteAfterAMoment(
      File(stage.pathOf(work.outputs.first)),
      utf8.encode('other'),
    );
    final check = stage.check(release);
    expect(check.state, StageState.broken);
    expect(check.problems, {
      'stage.json': 'receipt records an incomplete stage',
      work.outputs.first: 'artifact size, sha256 differs from the receipt',
    });
    expect(check.asInspection.verdict, Verdict.conflict);
  });

  test('a remembered check does not outlive a same-size rewrite', () {
    _stageAll(stage, release);
    expect(stage.check(release).reusable, isTrue);
    // Another view of the same stage is answered from what this process
    // learned about it...
    final again = _stage(root, release);
    expect(again.check(release).reusable, isTrue);

    // ...but not once a staged file is rewritten, even at the same length,
    // and not on the second look either.
    final file = File(stage.pathOf(release.assets.first.path));
    _rewriteAfterAMoment(file, utf8.encode('*' * file.lengthSync()));
    expect(again.check(release).state, StageState.changed);
    expect(
      again.check(release).state,
      StageState.changed,
      reason: 'a check that passes on its second run is not a check',
    );
  });

  test('an earlier schema refuses by version, not by field shape', () {
    _stageAll(stage, release);
    final document =
        jsonDecode(File(stage.pathOf('stage.json')).readAsStringSync())
            as Map<String, Object?>;
    File(stage.pathOf('stage.json')).writeAsStringSync(
      jsonEncode({...document, 'schema': stageSchemaVersion - 1}),
    );

    final check = stage.check(release);
    expect(check.state, StageState.unreadable);
    expect(check.problems['stage.json'], contains('unsupported stage schema'));
    expect(
      check.problems['stage.json'],
      contains('RK version that created it'),
    );
  });

  test('a receipt that names another stage is not this one', () {
    _stageAll(stage, release);
    final elsewhere = StageId.of(commit: '3' * 40, tree: _tree, plan: const {});
    File(
      stage.pathOf('stage.json'),
    ).writeAsStringSync(Receipt(stage: elsewhere, plan: const {}).encode());

    final check = stage.check(release);
    expect(check.state, StageState.unreadable);
    expect(check.problems, {
      'stage.json': 'receipt identity does not name this stage',
    });
  });

  test('files without a receipt are never reusable', () {
    stage.write(release.assets.first.path, utf8.encode('archive'));

    final check = stage.check(release);
    expect(check.state, StageState.absent);
    expect(check.problems, {
      'stage.json': 'files without a stage receipt are not reusable',
    });
  });

  test('a file that cannot be read is reported, not thrown', () {
    _stageAll(stage, release);
    final locked = File(stage.pathOf(release.assets.first.path));
    Process.runSync('chmod', ['000', locked.path]);
    addTearDown(() => Process.runSync('chmod', ['644', locked.path]));

    final check = stage.check(release);
    expect(check.state, StageState.changed);
    expect(
      check.problems[release.assets.first.path],
      startsWith('artifact could not be read'),
    );
  }, testOn: '!windows');

  test('checking reads, and creates nothing', () {
    expect(stage.check(release).reusable, isFalse);
    expect(Directory('${root.path}/.rk').existsSync(), isFalse);
  });

  test('begin replaces only this stage, and never follows a link', () {
    _stageAll(stage, release);
    final sibling = _stage(root, release, plan: const {'unit': 'sibling'})
      ..write('keep.txt', utf8.encode('keep'));
    final outside = Directory.systemTemp.createTempSync('rk-begin-outside-');
    addTearDown(() => outside.deleteSync(recursive: true));
    final kept = File('${outside.path}/keep.txt')..writeAsStringSync('outside');
    Link(stage.pathOf('outside-link')).createSync(outside.path);

    stage.begin();

    expect(stage.check(release).state, StageState.resumable);
    expect(stage.receipt!.producers, isEmpty);
    expect(
      Directory(stage.path).listSync().map((e) => e.path.split('/').last),
      ['stage.json'],
    );
    expect(utf8.decode(sibling.readBytes('keep.txt')!), 'keep');
    expect(kept.readAsStringSync(), 'outside');
  });

  test('discarding removes only what the receipt does not record', () {
    stage.begin();
    final [first, second, ...] = [
      for (final work in release.work)
        if (work.outputs.isNotEmpty) work,
    ];
    for (final work in [first, second]) {
      for (final file in work.outputs) {
        stage.write(file, utf8.encode('bytes'));
      }
    }
    stage.record(first);

    stage.discardUnrecorded([...first.outputs, ...second.outputs]);

    for (final file in first.outputs) {
      expect(File(stage.pathOf(file)).existsSync(), isTrue, reason: file);
    }
    for (final file in second.outputs) {
      expect(File(stage.pathOf(file)).existsSync(), isFalse, reason: file);
    }
  });

  test('a stage takes the shape of the work rk records', () {
    // A stage is named by its schema, not by the work it records: change the
    // work's names or files without bumping stageSchemaVersion, and a stage
    // an older rk left half-built would resume with intermediates it no
    // longer describes.
    final releases = [
      ..._derive(_binaryConfig, {
        'pubspec.yaml':
            'name: tool\nversion: 1.2.3\nexecutables:\n  tool: tool\n',
      }),
      ..._derive(
        '''
schema = 2

[release.core]
tag = "core-v{version}"
path = "packages/core"
publish = ["git-tag", "pub.dev"]

[release.parser]
tag = "parser-v{version}"
path = "native/parser"
publish = ["git-tag", "github-release"]
build = ["tool/build.sh", "{out}"]
assets = ["assets/parser.so", "parser.dylib"]
''',
        {
          'packages/core/pubspec.yaml': 'name: core\nversion: 1.0.0\n',
          'native/parser/Cargo.toml':
              '[package]\nname = "parser"\nversion = "0.1.0"\n',
        },
      ),
    ];
    final shape = [
      for (final release in releases)
        for (final work in release.work) [work.name, ...work.outputs],
    ];
    expect(
      (stageSchemaVersion, Sha256.hex(utf8.encode(jsonEncode(shape)))),
      (17, _workShape),
      reason:
          'the work a stage records changed: bump stageSchemaVersion, then '
          'pin the new shape here',
    );
  });
}

const _workShape =
    '6bb490886608411abb00c7b6d3a5da579418e00f7b663993ecedceca2bb8efce';

/// Records every piece of [release]'s work but the barrier, each file
/// holding bytes that name it, then completes the stage.
void _stageAll(Stage stage, UnitRelease release) {
  stage.begin();
  for (final work in release.work) {
    if (work == release.barrier) continue;
    for (final file in work.outputs) {
      stage.write(file, utf8.encode('bytes of $file'));
    }
    stage.record(work, evidence: {'work': work.name});
  }
  stage.complete(release);
}

Stage _stage(
  Directory root,
  UnitRelease release, {
  Map<String, Object?> plan = const {'unit': 'tool'},
}) => Stage(
  root: root.path,
  id: StageId.of(commit: _commit, tree: _tree, plan: plan),
  plan: plan,
  source: MemorySourceTree({}),
);

List<UnitRelease> _derive(String config, Map<String, String> files) {
  final diagnostics = Diagnostics();
  final source = MemorySourceTree({'release.toml': config, ...files});
  final resolution = Resolution.resolve(
    ReleaseConfig.parse(config, 'release.toml', diagnostics)!,
    source,
    diagnostics,
  );
  expect(resolution, isNotNull, reason: diagnostics.found.join('\n'));
  return [
    for (final unit in resolution!.units)
      UnitRelease.derive(
        unit,
        resolution,
        repository: 'owner/repo',
        problems: Diagnostics(),
      ),
  ];
}

/// Rewrites [file] after letting the clock move: two writes inside one
/// timestamp tick are indistinguishable by size, mode and time, the
/// collision the digest memo documents and cannot see.
void _rewriteAfterAMoment(File file, List<int> bytes) {
  sleep(const Duration(milliseconds: 5));
  file.writeAsBytesSync(bytes);
}
