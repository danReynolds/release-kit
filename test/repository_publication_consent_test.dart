import 'dart:convert';
import 'dart:io';

import 'package:rk/src/builds/capability.dart';
import 'package:rk/src/commands/release_preparation.dart';
import 'package:rk/src/commands/release_publication_coordinator.dart';
import 'package:rk/src/commands/release_stage_coordinator.dart';
import 'package:rk/src/engine/assets.dart';
import 'package:rk/src/engine/checklist.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/git.dart';
import 'package:rk/src/engine/inspect.dart';
import 'package:rk/src/engine/publish_target.dart';
import 'package:rk/src/engine/public_release_gate.dart';
import 'package:rk/src/engine/release_stage.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/stage_receipt.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/engine/targets.dart';
import 'package:rk/src/engine/verdict.dart';
import 'package:rk/src/output/output.dart';
import 'package:rk/src/output/report.dart';
import 'package:rk/src/targets/catalog.dart';
import 'package:rk/src/targets/target_module.dart';
import 'package:rk/src/targets/homebrew/client.dart';
import 'package:rk/src/transforms/archive.dart';
import 'package:test/test.dart';

import 'status_test.dart' show FakeRegistry;

void main() {
  late _Fixture f;
  setUp(() async => f = await _Fixture.create());
  tearDown(() => f.root.deleteSync(recursive: true));

  test(
    'public gate reads exact state after fresh history invalidation',
    () async {
      final plan = f.plans.first;
      f.makePublic('alpha');
      expect(
        (await f.inspector.inspect(plan.publicSteps.single, plan.unit)).isExact,
        isTrue,
      );
      f.onHistory = () => f.registry.published.remove('alpha');
      final snapshot = await PublicReleaseGate(f.inspector).refresh(
        unit: plan.unit,
        steps: plan.publicSteps,
        targets: plan.targets,
      );
      expect(snapshot.states.values.single.isAbsent, isTrue);
      expect(snapshot.remaining, plan.publicSteps);
      expect(snapshot.claims, hasLength(1));
    },
  );

  test(
    'all plans reviewed before one confirmation and every session',
    () async {
      expect(await f.coordinator.authorizeRepository(f.plans), isTrue);
      expect(
        f.calls.where((call) => call.startsWith('confirm:')),
        hasLength(1),
      );
      final confirm = f.calls.indexWhere((call) => call.startsWith('confirm:'));
      expect(f.calls.indexOf('complete:alpha'), lessThan(confirm));
      expect(f.calls.indexOf('complete:beta'), lessThan(confirm));
      expect(f.calls.indexOf('read:alpha'), lessThan(confirm));
      expect(f.calls.indexOf('read:beta'), lessThan(confirm));
      expect(f.sessionCalls, isEmpty);
      expect(f.output.report.acted, isFalse);
      for (final plan in f.plans) {
        expect(
          await f.coordinator.publish(plan),
          ExitCodes.ok,
          reason: f.text.toString(),
        );
      }
      expect(
        f.calls.where((call) => call.startsWith('confirm:')),
        hasLength(1),
      );
      expect(
        f.calls.indexWhere((call) => call == 'session'),
        greaterThan(confirm),
      );
      expect(f.calls.where((call) => call.startsWith('publish:')), [
        'publish:alpha',
        'publish:beta',
      ]);
    },
  );

  test(
    'private producer acted flag does not mean publication already began',
    () async {
      f.output.report.acted = true;
      expect(await f.coordinator.authorizeRepository(f.plans), isTrue);
      expect(
        f.calls.where((call) => call.startsWith('confirm:')),
        hasLength(1),
      );
      expect(f.sessionCalls, isEmpty);
    },
  );

  test(
    'declined aggregate confirmation keeps stages and acquires no sessions',
    () async {
      f.answer = 'no';
      final before = [for (final plan in f.plans) _snapshot(plan.stage)];
      expect(await f.coordinator.authorizeRepository(f.plans), isFalse);
      expect(f.problemCodes, contains('RK-AUTH-002'));
      expect(f.sessionCalls, isEmpty);
      expect(f.output.report.acted, isFalse);
      expect([for (final plan in f.plans) _snapshot(plan.stage)], before);
    },
  );

  for (final change in ['bytes', 'endpoint']) {
    test('later unit review cannot hide earlier $change drift', () async {
      var changed = false;
      f.onRead = (unit) {
        if (unit != 'beta' || changed) return;
        changed = true;
        switch (change) {
          case 'bytes':
            File(
              f.plans.first.stage.directory.resolve('release-manifest.json'),
            ).writeAsStringSync('changed');
          case 'endpoint':
            f.environment['PUB_HOSTED_URL'] = 'https://elsewhere.invalid';
        }
      };
      expect(await f.coordinator.authorizeRepository(f.plans), isFalse);
      expect(changed, isTrue);
      expect(f.calls.where((call) => call.startsWith('confirm:')), isEmpty);
      expect(f.sessionCalls, isEmpty);
      expect(f.output.report.acted, isFalse);
    });
  }

  test('endpoint baseline applies to an authentication-free target', () async {
    final tag = await _Fixture.create(tagOnly: true);
    try {
      final original = tag.plans.single;
      final changed = tag.copy(
        original,
        endpoints: {
          for (final target in original.targets)
            target.step.id: 'wrong endpoint',
        },
      );
      expect(await tag.coordinator.authorizeRepository([changed]), isFalse);
      expect(tag.problemCodes, contains('RK-DEST-001'));
      expect(tag.calls.where((call) => call.startsWith('confirm:')), isEmpty);
      expect(tag.sessionCalls, isEmpty);
      expect(tag.output.report.acted, isFalse);
    } finally {
      tag.root.deleteSync(recursive: true);
    }
  });

  test('disclosed warnings and signing identity do not prompt twice', () async {
    f.warning('alpha', 'review this warning');
    final first = f.copy(
      f.plans.first,
      signing: const ReleaseSigningContext(
        publishedRequirement: null,
        firstIdentity: true,
        certificateName: 'Developer ID Application: Example (TEAM)',
        codeId: 'alpha.id',
        certificateSha256: 'frozen fingerprint',
        designatedRequirement: 'frozen requirement',
      ),
    );
    expect(await f.coordinator.authorizeRepository([first]), isTrue);
    // Identical warning rendering has the same disclosure, not a new one.
    f.warning('alpha', 'review this warning');
    expect(
      await f.coordinator.publish(first),
      ExitCodes.ok,
      reason: f.text.toString(),
    );
    expect(f.calls.where((call) => call.startsWith('confirm:')), hasLength(1));
    expect(f.text.toString(), contains('macOS identity'));
    expect(f.problemCodes, isNot(contains('RK-AUTH-003')));
  });

  for (final change in [
    'warning',
    'global-warning',
    'signing',
    'claim',
    'receipt',
  ]) {
    test(
      '$change after consent refuses before sessions without another prompt',
      () async {
        final original = f.plans.first;
        if (change == 'claim') f.registry.published['alpha'] = ['0.0.1'];
        expect(await f.coordinator.authorizeRepository([original]), isTrue);
        var plan = original;
        switch (change) {
          case 'warning':
            f.warning('alpha', 'new warning');
          case 'global-warning':
            f.warning(null, 'new repository warning');
          case 'signing':
            plan = f.copy(
              original,
              signing: const ReleaseSigningContext(
                publishedRequirement: null,
                firstIdentity: true,
                certificateName: 'New certificate',
                codeId: 'new.id',
              ),
            );
          case 'claim':
            f.registry.published.remove('alpha');
            f.registry.forget('alpha');
          case 'receipt':
            File(
              original.stage.directory.resolve('stage.json'),
            ).writeAsStringSync('{}');
        }
        expect(await f.coordinator.publish(plan), ExitCodes.refused);
        expect(
          f.calls.where((call) => call.startsWith('confirm:')),
          hasLength(1),
        );
        expect(f.sessionCalls, isEmpty);
        expect(f.output.report.acted, isFalse);
        expect(
          f.problemCodes,
          contains(change == 'receipt' ? 'RK-STAGE-002' : 'RK-AUTH-003'),
        );
      },
    );
  }

  test('session-time warnings are refused without expanding consent', () async {
    expect(await f.coordinator.authorizeRepository([f.plans.first]), isTrue);
    f.onSession = () => f.warning('alpha', 'appeared during sign-in');
    expect(await f.coordinator.publish(f.plans.first), ExitCodes.refused);
    expect(f.calls.where((call) => call.startsWith('confirm:')), hasLength(1));
    expect(f.calls.where((call) => call.startsWith('publish:')), isEmpty);
    expect(f.problemCodes, contains('RK-AUTH-003'));
    expect(f.output.report.acted, isFalse);
  });

  test('session-time first claim is refused before the public act', () async {
    final plan = f.plans.first;
    f.registry.published['alpha'] = ['0.0.1'];
    expect(await f.coordinator.authorizeRepository([plan]), isTrue);
    f.onSession = () {
      f.registry.published.remove('alpha');
      f.registry.forget('alpha');
    };
    expect(await f.coordinator.publish(plan), ExitCodes.refused);
    expect(f.calls.where((call) => call.startsWith('confirm:')), hasLength(1));
    expect(f.calls.where((call) => call.startsWith('publish:')), isEmpty);
    expect(f.problemCodes, contains('RK-AUTH-003'));
    expect(plan.actions.values, everyElement(ReleaseAction.notAttempted));
    expect(f.output.report.acted, isFalse);
  });

  test('all-public scope does not prompt and cannot gain work later', () async {
    for (final plan in f.plans) {
      f.makePublic(plan.unit.name);
    }
    expect(await f.coordinator.authorizeRepository(f.plans), isTrue);
    expect(f.calls.where((call) => call.startsWith('confirm:')), isEmpty);
    f.registry.published.remove('alpha');
    f.registry.forget('alpha');
    expect(await f.coordinator.publish(f.plans.first), ExitCodes.refused);
    expect(f.problemCodes, contains('RK-AUTH-003'));
    expect(f.sessionCalls, isEmpty);
    expect(f.output.report.acted, isFalse);
  });

  test('prepared no-op cannot gain work before its first review', () async {
    final plan = f.copy(f.plans.first, preparedNoop: true);
    expect(await f.coordinator.authorizeRepository([plan]), isFalse);
    expect(f.problemCodes, contains('RK-AUTH-003'));
    expect(f.calls.where((call) => call.startsWith('confirm:')), isEmpty);
    expect(f.sessionCalls, isEmpty);
  });

  for (final when in ['review', 'session']) {
    test('global no-op coverage refuses $when drift in another unit', () async {
      f.makePublic('alpha');
      final noop = f.copy(f.plans.first, preparedNoop: true);
      final active = f.copy(f.plans.last);
      if (when == 'review') {
        f.onRead = (unit) {
          if (unit == 'beta') f.registry.published.remove('alpha');
        };
        expect(
          await f.coordinator.authorizeRepository([noop, active]),
          isFalse,
        );
        expect(f.calls.where((call) => call.startsWith('confirm:')), isEmpty);
        expect(f.sessionCalls, isEmpty);
      } else {
        expect(await f.coordinator.authorizeRepository([noop, active]), isTrue);
        expect(await f.coordinator.publish(noop), ExitCodes.ok);
        if (when == 'session') {
          f.onSession = () => f.registry.published.remove('alpha');
        }
        expect(await f.coordinator.publish(active), ExitCodes.refused);
        expect(
          f.calls.where((call) => call.startsWith('confirm:')),
          hasLength(1),
        );
      }
      expect(f.problemCodes, contains('RK-AUTH-003'));
      expect(active.actions.values, everyElement(ReleaseAction.notAttempted));
      expect(f.calls.where((call) => call.startsWith('publish:')), isEmpty);
      expect(f.output.report.acted, isFalse);
    });
  }

  for (final when in ['review', 'after-yes']) {
    test('local-only selected outputs remain guarded at $when', () async {
      final local = f.localOnly(f.plans.first);
      final active = f.plans.last;
      void tamper() => File(
        local.stage.directory.resolve('release-manifest.json'),
      ).writeAsStringSync('changed private output');
      if (when == 'review') {
        f.onRead = (unit) {
          if (unit == 'beta') tamper();
        };
        expect(
          await f.coordinator.authorizeRepository([local, active]),
          isFalse,
        );
        expect(f.calls.where((call) => call.startsWith('confirm:')), isEmpty);
      } else {
        expect(
          await f.coordinator.authorizeRepository([local, active]),
          isTrue,
        );
        tamper();
        expect(await f.coordinator.publish(active), ExitCodes.refused);
        expect(
          f.calls.where((call) => call.startsWith('confirm:')),
          hasLength(1),
        );
      }
      expect(f.problemCodes, contains('RK-STAGE-002'));
      expect(f.sessionCalls, isEmpty);
      expect(f.calls.where((call) => call.startsWith('publish:')), isEmpty);
      expect(f.output.report.acted, isFalse);
    });
  }

  test(
    'local-only plans require no publication confirmation or output',
    () async {
      final plan = f.localOnly(f.plans.first);
      expect(await f.coordinator.authorizeRepository([plan]), isTrue);
      expect(await f.coordinator.publish(plan), ExitCodes.ok);
      expect(f.calls.where((call) => call.startsWith('confirm:')), isEmpty);
      expect(f.sessionCalls, isEmpty);
      expect(f.text.toString(), isNot(contains('already released')));
      expect(f.output.report.acted, isFalse);
    },
  );

  test('aggregate consent freezes exact public recovery replacement', () async {
    final original = f.plans.first;
    final step = Step(
      id: 'alpha/homebrew/recovery',
      kind: StepKind.publishHomebrew,
      target: PublishTarget.homebrew,
      unit: 'alpha',
      project: 'alpha',
      summary: 'update the recovered formula',
      needs: const [],
    );
    final target = TargetPlan(
      label: 'Homebrew',
      coordinate: 'owner/tap/Formula/alpha',
      targetVersion: '0.1.0',
      step: step,
      kindLabel: 'Homebrew',
      identity: 'owner/tap',
      planNote: 'update alpha',
      artifacts: const [],
      project: original.unit.projects.single,
    );
    var replacement = 'reviewed public archive digests';
    f.inspections[step.id] = () => Inspection.absent(
      authority: HomebrewUpdateAuthority.absent(
        replacement: utf8.encode(replacement),
      ),
    );
    original.stage.reset();
    final plan = PublicationPlan(
      unit: original.unit,
      steps: [step],
      publicSteps: [step],
      targets: [target],
      states: {step.id: f.inspections[step.id]!()},
      endpointBaselines: {
        step.id: f.catalog.moduleForTarget(target).destinationBinding(
          TargetReadinessContext(
            tools: f.tools,
            git: f.git,
            environment: const {},
          ),
          original.unit,
          [target],
        ),
      },
      actions: {step.id: ReleaseAction.notAttempted},
      prepared: PreparedRelease(claims: const [], signing: null),
      stage: original.stage,
      recoversWithoutStage: true,
    );
    expect(await f.coordinator.authorizeRepository([plan]), isTrue);
    replacement = 'different public archive digests';
    expect(await f.coordinator.publish(plan), ExitCodes.refused);
    expect(f.problemCodes, contains('RK-STAGE-005'));
    expect(plan.actions.values, everyElement(ReleaseAction.notAttempted));
    expect(f.sessionCalls, isEmpty);
    expect(f.calls.where((call) => call.startsWith('publish:')), isEmpty);
    expect(f.output.report.acted, isFalse);
  });

  test('legacy per-unit publish keeps its authorization seam', () async {
    expect(
      await f.coordinator.publish(f.plans.first),
      ExitCodes.ok,
      reason: f.text.toString(),
    );
    expect(f.calls.where((call) => call.startsWith('confirm:')), hasLength(1));
    expect(f.calls, contains('publish:alpha'));
  });

  for (final when in ['after-yes', 'session']) {
    test('pending public unit remains guarded at $when', () async {
      final later = f.plans.last;
      void tamper() => File(
        later.stage.directory.resolve('release-manifest.json'),
      ).writeAsStringSync('changed later private output');
      final first = f.copy(f.plans.first);
      expect(await f.coordinator.authorizeRepository([first, later]), isTrue);
      switch (when) {
        case 'after-yes':
          tamper();
        case 'session':
          f.onSession = tamper;
      }
      expect(await f.coordinator.publish(first), ExitCodes.refused);
      expect(f.problemCodes, contains('RK-STAGE-002'));
      expect(first.actions.values, everyElement(ReleaseAction.notAttempted));
      expect(f.calls.where((call) => call.startsWith('publish:')), isEmpty);
      expect(f.output.report.acted, isFalse);
      if (when == 'after-yes') expect(f.sessionCalls, isEmpty);
    });
  }

  test(
    'completed public unit may lose its private stage after consent',
    () async {
      final first = f.plans.first;
      final later = f.plans.last;
      expect(await f.coordinator.authorizeRepository(f.plans), isTrue);
      f.makePublic('beta');
      later.stage.reset();
      expect(
        await f.coordinator.publish(first),
        ExitCodes.ok,
        reason: f.text.toString(),
      );
      expect(
        await f.coordinator.publish(later),
        ExitCodes.ok,
        reason: f.text.toString(),
      );
      expect(f.calls.where((call) => call.startsWith('publish:')), [
        'publish:alpha',
      ]);
      expect(
        f.calls.where((call) => call.startsWith('confirm:')),
        hasLength(1),
      );
    },
  );

  test(
    'scope that became public cannot disappear before another act',
    () async {
      final later = f.plans.last;
      final first = f.copy(f.plans.first);
      expect(await f.coordinator.authorizeRepository([first, later]), isTrue);
      f.makePublic('beta');
      later.stage.reset();
      f.onSession = () {
        f.registry.published.remove('beta');
        f.registry.forget('beta');
      };
      expect(await f.coordinator.publish(first), ExitCodes.refused);
      expect(f.problemCodes, contains('RK-AUTH-003'));
      expect(first.actions.values, everyElement(ReleaseAction.notAttempted));
      expect(f.calls.where((call) => call.startsWith('publish:')), isEmpty);
      expect(f.output.report.acted, isFalse);
    },
  );

  for (final change in ['endpoint']) {
    test('final provider read cannot hide changed $change', () async {
      final original = f.plans.first;
      final plan = f.copy(original);
      expect(await f.coordinator.authorizeRepository([plan]), isTrue);
      f.onSession = () {
        switch (change) {
          case 'endpoint':
            f.environment['PUB_HOSTED_URL'] = 'https://elsewhere.invalid';
        }
      };
      expect(await f.coordinator.publish(plan), ExitCodes.refused);
      expect(
        f.problemCodes,
        contains(change == 'endpoint' ? 'RK-DEST-001' : 'RK-STAGE-004'),
      );
      expect(plan.actions.values, everyElement(ReleaseAction.notAttempted));
      expect(f.calls.where((call) => call.startsWith('publish:')), isEmpty);
      expect(f.output.report.acted, isFalse);
    });
  }

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
  final inspections = <String, Inspection Function()>{};
  final environment = <String, String>{};
  int archiveStamp = 0;
  String? answer = 'yes';
  void Function(String)? onRead;
  void Function()? onSession;
  void Function()? onHistory;
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
    stages: ReleaseStageCoordinator(
      initialGit: git,
      output: output,
      refreshGit: () async => git,
      refreshStage: stages.refresh,
      tools: tools,
      capabilities: HostCapabilities(
        hostPlatform: 'macos-arm64',
        containerRuntime: null,
        hasNativeAssets: false,
      ),
      stageFor: stages.call,
      stageOnly: false,
    ),
    refreshGit: () async => git,
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
      bytes[4] = archiveStamp;
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
        endpointBaselines: {
          for (final target in targets)
            target.step.id: catalog.moduleForTarget(target).destinationBinding(
              TargetReadinessContext(
                tools: tools,
                git: git,
                environment: environment,
              ),
              unit,
              [target],
            ),
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
    endpointBaselines: const {},
    actions: const {},
    prepared: plan.prepared,
    stage: plan.stage,
    recoversWithoutStage: false,
  );

  PublicationPlan copy(
    PublicationPlan p, {
    ReleaseSigningContext? signing,
    Map<String, String>? endpoints,
    bool? preparedNoop,
  }) => PublicationPlan(
    unit: p.unit,
    steps: p.steps,
    publicSteps: p.publicSteps,
    targets: p.targets,
    states: p.states,
    endpointBaselines: endpoints ?? p.endpointBaselines,
    actions: p.actions,
    prepared: PreparedRelease(
      claims: p.prepared.claims,
      signing: signing ?? p.prepared.signing,
    ),
    stage: p.stage,
    recoversWithoutStage: p.recoversWithoutStage,
    preparedNoop: preparedNoop ?? p.preparedNoop,
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
  Future<ReleaseHistoryCheck> releaseMonotonicity(
    ResolvedUnit unit,
    Iterable<TargetPlan> targets,
    Diagnostics problems, {
    bool refreshRegistry = false,
  }) {
    if (refreshRegistry) fixture.onHistory?.call();
    return super.releaseMonotonicity(
      unit,
      targets,
      problems,
      refreshRegistry: refreshRegistry,
    );
  }

  @override
  Future<Inspection> inspect(Step step, ResolvedUnit unit) async {
    fixture.calls.add('read:${unit.name}');
    fixture.onRead?.call(unit.name);
    if (fixture.inspections[step.id] case final answer?) return answer();
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
      fixture.onSession?.call();
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
