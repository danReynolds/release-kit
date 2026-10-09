import 'dart:convert';
import 'dart:io';

import 'package:rk/src/commands/release_publish.dart';
import 'package:rk/src/engine/assets.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/git.dart';
import 'package:rk/src/engine/inspect.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/stage.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/engine/unit_release.dart';
import 'package:rk/src/engine/unit_snapshot.dart';
import 'package:rk/src/output/output.dart';
import 'package:rk/src/transforms/archive.dart';
import 'package:test/test.dart';

import 'status_test.dart' show FakeRegistry;
import 'support/memory_source_tree.dart';

void main() {
  late _Fixture f;
  setUp(() async => f = await _Fixture.create());
  tearDown(() => f.root.deleteSync(recursive: true));

  List<String> confirms() =>
      f.calls.where((call) => call.startsWith('confirm:')).toList();

  test('one question covers every unit, asked before any session', () async {
    expect(await f.publication.authorize(f.runs), isTrue);
    expect(confirms(), ['confirm:Release alpha 0.1.0 and beta 0.1.0? [y/N] ']);
    expect(f.sessionCalls, isEmpty);
    expect(f.output.report.acted, isFalse);
    for (final run in f.runs) {
      expect(
        await f.publication.publish(run),
        ExitCodes.ok,
        reason: f.text.toString(),
      );
    }
    expect(confirms(), hasLength(1));
    expect(f.calls.where((call) => call.startsWith('publish:')), [
      'publish:alpha',
      'publish:beta',
    ]);
    // Both units publish to pub.dev: one sign-in serves the run.
    expect(f.sessionCalls, hasLength(1));
    expect(
      f.calls.indexOf('session'),
      greaterThan(f.calls.indexOf(confirms().single)),
    );
  });

  test('a target the question left out is never published', () async {
    // The snapshot found alpha published; if it disappears before the
    // release reaches it, the yes still did not cover publishing it.
    f.makePublic('alpha');
    final runs = [await f.read('alpha'), f.runs.last];
    f.unpublish('alpha');
    expect(await f.publication.authorize(runs), isTrue);
    expect(confirms(), ['confirm:Release beta 0.1.0? [y/N] ']);
    for (final run in runs) {
      expect(await f.publication.publish(run), ExitCodes.ok);
    }
    expect(f.calls.where((call) => call.startsWith('publish:')), [
      'publish:beta',
    ]);
  });

  test(
    'a target published since the snapshot is not published again',
    () async {
      expect(await f.publication.authorize(f.runs), isTrue);
      f.makePublic('beta');
      for (final run in f.runs) {
        expect(await f.publication.publish(run), ExitCodes.ok);
      }
      expect(f.calls.where((call) => call.startsWith('publish:')), [
        'publish:alpha',
      ]);
      final beta = f.runs.last;
      expect(
        beta.actions[beta.read.targets.single],
        ReleaseAction.alreadyPublished,
      );
    },
  );
}

final class _Fixture {
  _Fixture(this.root, this.source, this.git, this.resolution);
  static Future<_Fixture> create() async {
    final root = Directory.systemTemp.createTempSync('rk-repository-consent-');
    const names = ['alpha', 'beta'];
    final source = MemorySourceTree({
      'release.toml':
          'schema = 2\n${names.map((name) => '[release.$name]\npath = "$name"\npublish = ["pub.dev"]\n').join()}',
      for (final name in names)
        '$name/pubspec.yaml':
            'name: $name\nversion: 0.1.0\nenvironment:\n  sdk: ^3.10.4\n',
    }, description: root.path);
    final git = GitState(
      root: root.path,
      head: 'a' * 40,
      headTree: 'b' * 40,
      branch: 'main',
      isClean: true,
      uncommitted: [],
      headIsPushed: true,
      tags: [],
      signingConfigured: false,
      originUrl: 'https://example.test/repo.git',
    );
    final diagnostics = Diagnostics();
    final config = ReleaseConfig.parse(
      source.read('release.toml')!,
      'release.toml',
      diagnostics,
    )!;
    final resolution = Resolution.resolve(config, source, diagnostics)!;
    expect(diagnostics.found, isEmpty);
    final f = _Fixture(root, source, git, resolution);
    for (final unit in resolution.units) {
      f.stage(unit);
    }
    for (final name in names) {
      f.runs.add(await f.read(name));
    }
    return f;
  }

  final Directory root;
  final MemorySourceTree source;
  final GitState git;
  final Resolution resolution;
  final registry = FakeRegistry({});
  final text = StringBuffer();
  final calls = <String>[];
  final runs = <UnitRun>[];
  String? answer = 'yes';
  late final output = Output(sink: text.write, isTerminal: false);
  late final tools = _Tools(this);
  late final stages = Stages(git.root);
  late final inspector = Inspector(
    registry: registry,
    pubDev: registry,
    git: git,
    tools: tools,
    repository: git.originUrl,
  );
  late final publication = Publication(
    inspector: inspector,
    initialGit: git,
    tools: tools,
    output: output,
    refreshEnvironment: () => const {},
    wait: (_) async {},
    confirm: (prompt) async {
      calls.add('confirm:$prompt');
      return answer;
    },
    allowInteractiveTools: false,
    confirmDeadline: Duration.zero,
    confirmInterval: Duration.zero,
  );
  List<String> get sessionCalls =>
      calls.where((call) => call == 'session').toList();

  /// Stages [unit]: its package archive, recorded, and the stage complete.
  void stage(ResolvedUnit unit) {
    final stage = stages.of(unit, git, source)..begin();
    final release = UnitRelease.derive(
      unit,
      resolution,
      repository: git.originUrl,
      problems: Diagnostics(),
    );
    for (final work in release.work) {
      if (work == release.barrier) continue;
      final project = work.project!;
      stage.write(
        ReleaseAssets.pubArchivePath(project),
        ArchiveBuilder.gzip(
          ArchiveBuilder.tar([
            ArchiveEntry(
              name: 'pubspec.yaml',
              bytes: utf8.encode(source.read('${project.name}/pubspec.yaml')!),
            ),
          ]),
        ),
      );
      stage.record(work, evidence: const {'package_archive': 'staged'});
    }
    stage.complete(release);
    expect(stage.check(release).problems, isEmpty);
  }

  /// The unit [name]'s run, read as a release reads it.
  Future<UnitRun> read(String name) async {
    final run = UnitRun(
      UnitSnapshot.start(
        resolution.unit(name)!,
        resolution: resolution,
        inspector: inspector,
        repository: git.originUrl,
        hasCommit: true,
        stageFor: (unit) => stages.of(unit, git, source),
      ),
    );
    await run.read.settle();
    return run;
  }

  void makePublic(String name) {
    final unit = resolution.unit(name)!;
    registry.published[name] = ['0.1.0'];
    registry.archives['$name@0.1.0'] = stages
        .of(unit, git, source)
        .readBytes(ReleaseAssets.pubArchivePath(unit.projects.single))!;
    registry.forget(name);
  }

  void unpublish(String name) {
    registry.published.remove(name);
    registry.archives.remove('$name@0.1.0');
    registry.forget(name);
  }
}

final class _Tools implements Tools {
  _Tools(this.fixture);
  final _Fixture fixture;
  @override
  Future<ToolResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
    List<int>? stdin,
  }) async {
    if (executable == 'git' && arguments.firstOrNull == 'ls-remote') {
      return ToolResult(exitCode: 0, stdout: '', stderr: '');
    }
    if (arguments.join(' ') == 'pub token list') {
      fixture.calls.add('session');
      return ToolResult(exitCode: 0, stdout: 'https://pub.dev\n', stderr: '');
    }
    if (arguments.contains('--from-archive')) {
      // producers/<package>/pub/<archive>
      final archive = arguments[arguments.indexOf('--from-archive') + 1];
      final parts = archive.split('/');
      final name = parts[parts.lastIndexOf('producers') + 1];
      fixture.calls.add('publish:$name');
      fixture.makePublic(name);
      return ToolResult(exitCode: 0, stdout: '', stderr: '');
    }
    throw StateError('unexpected tool: $executable ${arguments.join(' ')}');
  }

  @override
  Future<int> runInteractive(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async => throw StateError('unexpected interactive tool');
}
