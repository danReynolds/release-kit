import 'dart:convert';
import 'dart:io';

import 'package:rk/src/commands/release_preparation.dart';
import 'package:rk/src/commands/release_publication_coordinator.dart';
import 'package:rk/src/engine/assets.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/git.dart';
import 'package:rk/src/engine/inspect.dart';
import 'package:rk/src/engine/publish_target.dart';
import 'package:rk/src/engine/release_stage.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/stage_receipt.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/engine/verdict.dart';
import 'package:rk/src/engine/unit_release.dart';
import 'package:rk/src/output/output.dart';
import 'package:rk/src/transforms/archive.dart';
import 'package:test/test.dart';

import 'status_test.dart' show FakeRegistry;

void main() {
  late _Fixture f;
  setUp(() async => f = await _Fixture.create());
  tearDown(() => f.root.deleteSync(recursive: true));

  List<String> confirms() =>
      f.calls.where((call) => call.startsWith('confirm:')).toList();

  test('one question covers every unit, asked before any session', () async {
    expect(await f.coordinator.authorize(f.plans), isTrue);
    expect(confirms(), ['confirm:Release alpha 0.1.0 and beta 0.1.0? [y/N] ']);
    expect(f.sessionCalls, isEmpty);
    expect(f.output.report.acted, isFalse);
    for (final plan in f.plans) {
      expect(
        await f.coordinator.publish(plan),
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
    final plans = [f.published(f.plans.first), f.plans.last];
    expect(await f.coordinator.authorize(plans), isTrue);
    expect(confirms(), ['confirm:Release beta 0.1.0? [y/N] ']);
    for (final plan in plans) {
      expect(await f.coordinator.publish(plan), ExitCodes.ok);
    }
    expect(f.calls.where((call) => call.startsWith('publish:')), [
      'publish:beta',
    ]);
  });

  test(
    'a target published since the snapshot is not published again',
    () async {
      expect(await f.coordinator.authorize(f.plans), isTrue);
      f.makePublic('beta');
      for (final plan in f.plans) {
        expect(await f.coordinator.publish(plan), ExitCodes.ok);
      }
      expect(f.calls.where((call) => call.startsWith('publish:')), [
        'publish:alpha',
      ]);
      final beta = f.plans.last;
      expect(
        beta.actions[beta.targets.single.id],
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
      await f.prepare(unit);
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
  final plans = <PublicationPlan>[];
  String? answer = 'yes';
  late final output = Output(sink: text.write, isTerminal: false);
  late final tools = _Tools(this);
  late final stages = ReleaseStages(
    source: source,
    git: git,
    resolution: resolution,
  );
  late final inspector = Inspector(
    registry: registry,
    pubDev: registry,
    git: git,
    tools: tools,
    repository: git.originUrl,
    stageFor: stages.call,
  );
  late final coordinator = ReleasePublicationCoordinator(
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

  Future<void> prepare(ResolvedUnit unit) async {
    final stage = stages(unit);
    final steps = <StageStep>[];
    stage.writeProgress(steps);
    for (final project in unit.projects.where(
      (project) => project.publish.contains(PublishTarget.pubDev),
    )) {
      final path = ReleaseAssets.pubArchivePath(project);
      final bytes = ArchiveBuilder.gzip(
        ArchiveBuilder.tar([
          ArchiveEntry(
            name: 'pubspec.yaml',
            bytes: utf8.encode(source.read('${project.name}/pubspec.yaml')!),
          ),
        ]),
      );
      stage.directory.writeBytesAtomically(path, bytes);
      final name = 'pub-archive:${project.name}';
      steps.add(
        StageStep(
          name: name,
          outputs: [
            StageArtifact.capture(
              stage: stage.directory,
              path: path,
              type: 'pub-archive',
            ),
          ],
          evidence: const {'package_archive': 'staged'},
        ),
      );
      stage.writeProgress(steps);
    }
    stage.finalize(releaseAssets: const []);
    expect(stage.inspect().issues, isEmpty);
    final release = UnitRelease.derive(
      unit,
      resolution,
      repository: git.originUrl,
      problems: Diagnostics(),
    );
    plans.add(
      PublicationPlan(
        release: release,
        states: {
          for (final step in release.steps) step.id: const Inspection.absent(),
        },
        actions: {
          for (final target in release.targets)
            target.id: ReleaseAction.notAttempted,
        },
        prepared: PreparedRelease(claims: const [], signing: null),
        stage: stage,
        recoversWithoutStage: false,
      ),
    );
  }

  /// [plan] as a snapshot that found every target already published.
  PublicationPlan published(PublicationPlan plan) => PublicationPlan(
    release: plan.release,
    states: {
      for (final step in plan.steps)
        step.id: const Inspection.exact(detail: 'live'),
    },
    actions: {
      for (final target in plan.targets)
        target.id: ReleaseAction.alreadyPublished,
    },
    prepared: plan.prepared,
    stage: plan.stage,
    recoversWithoutStage: true,
  );

  void makePublic(String name) {
    final plan = plans.singleWhere((plan) => plan.unit.name == name);
    final project = plan.unit.projects.single;
    registry.published[name] = ['0.1.0'];
    registry.archives['$name@0.1.0'] = File(
      plan.stage.directory.resolve(ReleaseAssets.pubArchivePath(project)),
    ).readAsBytesSync();
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
