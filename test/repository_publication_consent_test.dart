import 'dart:convert';
import 'dart:io';

import 'package:rk/src/commands/release_preparation.dart';
import 'package:rk/src/commands/release_publication_coordinator.dart';
import 'package:rk/src/engine/assets.dart';
import 'package:rk/src/engine/checklist.dart';
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
import 'package:rk/src/output/output.dart';
import 'package:rk/src/output/report.dart';
import 'package:rk/src/targets/catalog.dart';
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

  test('a declined question keeps the stages and signs in nowhere', () async {
    f.answer = 'no';
    final before = [for (final plan in f.plans) _snapshot(plan.stage)];
    expect(await f.coordinator.authorize(f.plans), isFalse);
    expect(f.problemCodes, contains('RK-AUTH-002'));
    expect(f.sessionCalls, isEmpty);
    expect(f.output.report.acted, isFalse);
    expect([for (final plan in f.plans) _snapshot(plan.stage)], before);
  });

  test('publication needs the question asked first', () {
    expect(() => f.coordinator.publish(f.plans.first), throwsStateError);
  });

  test('local-only plans ask nothing and say nothing', () async {
    final plan = f.localOnly(f.plans.first);
    expect(await f.coordinator.authorize([plan]), isTrue);
    expect(await f.coordinator.publish(plan), ExitCodes.ok);
    expect(confirms(), isEmpty);
    expect(f.sessionCalls, isEmpty);
    expect(f.text.toString(), isNot(contains('already released')));
    expect(f.output.report.acted, isFalse);
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
        beta.actions[beta.publicSteps.single.id],
        ReleaseAction.alreadyPublished,
      );
    },
  );

  test('staged bytes changed after the yes stop the act', () async {
    expect(await f.coordinator.authorize(f.plans), isTrue);
    final plan = f.plans.first;
    File(
      plan.stage.directory.resolve(
        ReleaseAssets.pubArchivePath(plan.unit.projects.single),
      ),
    ).writeAsBytesSync([1, 2, 3]);
    expect(await f.coordinator.publish(plan), ExitCodes.refused);
    expect(f.problemCodes, contains('RK-STAGE-002'));
    expect(f.calls.where((call) => call.startsWith('publish:')), isEmpty);
  });

  test('warning facts include globals and deduplicate evidence by content', () {
    final report = Report('release');
    const warning = Diagnostic(
      code: 'TEST',
      message: 'warn',
      evidence: 'details',
    );
    report.warning(warning, unit: 'alpha');
    report.warning(warning, unit: 'alpha');
    report.warning(const Diagnostic(code: 'GLOBAL', message: 'global'));
    report.warning(
      const Diagnostic(code: 'OTHER', message: 'other'),
      unit: 'beta',
    );
    final facts = report.warningEvidenceFor('alpha');
    expect(facts, hasLength(2));
    expect(
      facts.singleWhere((fact) => fact['code'] == 'TEST')['evidence'],
      'details',
    );
    expect(() => facts.clear(), throwsUnsupportedError);
    expect(() => facts.first['message'] = 'changed', throwsUnsupportedError);
  });
}

final class _Fixture {
  _Fixture(this.root, this.source, this.git, this.resolution);
  static Future<_Fixture> create({bool tagOnly = false}) async {
    final root = Directory.systemTemp.createTempSync('rk-repository-consent-');
    final names = tagOnly ? ['alpha'] : ['alpha', 'beta'];
    final source = MemorySourceTree({
      'release.toml':
          'schema = 2\n${names.map((name) => '[release.$name]\npath = "$name"\npublish = ["${tagOnly ? 'git-tag' : 'pub.dev'}"]\n${tagOnly ? 'tag = "v{version}"\n' : ''}').join()}',
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
  final environment = <String, String>{};
  String? answer = 'yes';
  late final output = Output(sink: text.write, isTerminal: false);
  late final tools = _Tools(this);
  late final catalog = TargetCatalog.builtIn();
  late final stages = ReleaseStages(
    source: source,
    git: git,
    stageContracts: catalog.stageContractResolver(resolution),
  );
  late final inspector = _Inspector(this);
  late final coordinator = ReleasePublicationCoordinator(
    inspector: inspector,
    initialGit: git,
    tools: tools,
    output: output,
    refreshEnvironment: () => Map.of(environment),
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
  List<String> get problemCodes =>
      ((jsonDecode(output.report.encode(exit: 0)) as Map)['problems'] as List)
          .map((value) => '${(value as Map)['code']}')
          .toList();
  void warning(String? unit, String message) => output.warning(
    Diagnostic(code: 'TEST-WARNING', message: message),
    unit: unit,
  );

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
    final checklist = Checklist.derive(unit, resolution, Diagnostics());
    final targets = catalog.derive(unit, checklist, repository: git.originUrl);
    plans.add(
      PublicationPlan(
        unit: unit,
        steps: checklist.steps,
        publicSteps: checklist.steps.where((step) => step.isPublic),
        targets: targets,
        states: {
          for (final step in checklist.steps)
            step.id: const Inspection.absent(),
        },
        actions: {
          for (final target in targets)
            target.step.id: ReleaseAction.notAttempted,
        },
        prepared: PreparedRelease(claims: const [], signing: null),
        stage: stage,
        recoversWithoutStage: false,
      ),
    );
    calls.add('complete:${unit.name}');
  }

  PublicationPlan localOnly(PublicationPlan plan) => PublicationPlan(
    unit: plan.unit,
    steps: plan.steps.where((step) => !step.isPublic),
    publicSteps: const [],
    targets: const [],
    states: plan.states,
    actions: const {},
    prepared: plan.prepared,
    stage: plan.stage,
    recoversWithoutStage: false,
  );

  /// [plan] as a snapshot that found every target already published.
  PublicationPlan published(PublicationPlan plan) => PublicationPlan(
    unit: plan.unit,
    steps: plan.steps,
    publicSteps: plan.publicSteps,
    targets: plan.targets,
    states: {
      for (final step in plan.steps)
        step.id: const Inspection.exact(detail: 'live'),
    },
    actions: {
      for (final target in plan.targets)
        target.step.id: ReleaseAction.alreadyPublished,
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

final class _Inspector extends Inspector {
  _Inspector(this.fixture)
    : super(
        registry: fixture.registry,
        pubDev: fixture.registry,
        git: fixture.git,
        tools: fixture.tools,
        repository: fixture.git.originUrl,
        stageFor: fixture.stages.call,
      );
  final _Fixture fixture;
  @override
  Future<Inspection> inspect(Step step, ResolvedUnit unit) async {
    fixture.calls.add('read:${unit.name}');
    if (step.target == PublishTarget.gitTag) return const Inspection.absent();
    return super.inspect(step, unit);
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
    if (arguments.take(3).join(' ') == 'pub cache add') {
      fixture.calls.add('availability');
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

/// Every file in [stage], by path, with its bytes.
Map<String, List<int>> _snapshot(ReleaseStage stage) => {
  for (final file in Directory(
    stage.directory.path,
  ).listSync(recursive: true).whereType<File>())
    file.path: file.readAsBytesSync(),
};
