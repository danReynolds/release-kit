import 'dart:async';
import 'dart:convert';

import 'package:rk/src/engine/checklist.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/git.dart';
import 'package:rk/src/engine/inspect.dart';
import 'package:rk/src/engine/publish_target.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/targets.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/engine/verdict.dart';
import 'package:rk/src/targets/catalog.dart';
import 'package:rk/src/targets/target_module.dart';
import 'package:test/test.dart';

import 'scripted_tools.dart';
import 'status_test.dart' show FakeRegistry;

/// The shared inspector, driven step by step.
///
/// A mutation found the hole this file closes: making a prerequisite that is
/// not live read as "live" broke nothing in the whole suite, so the cross-unit
/// ordering rule — the dependency publishes before its dependent — was
/// enforced by no executable test.
void main() {
  classificationTables();
  tagRemoteLeg();

  late Resolution resolution;
  late ResolvedUnit cli;
  late Step prerequisite;
  late Step publish;

  setUp(() {
    final diagnostics = Diagnostics();
    final config = ReleaseConfig.parse('''
schema = 2

[release.core]
tag = "example_core-v{version}"
path = "packages/core"
publish = ["git-tag", "pub.dev"]

[release.cli]
tag = "example_cli-v{version}"
path = "packages/cli"
publish = ["git-tag", "pub.dev"]
''', 'release.toml', diagnostics)!;
    resolution = Resolution.resolve(
      config,
      MemorySourceTree({
        'packages/core/pubspec.yaml': 'name: example_core\nversion: 0.3.0\n',
        'packages/cli/pubspec.yaml': '''
name: example_cli
version: 0.3.0
dependencies:
  example_core: 0.3.0
''',
      }),
      diagnostics,
    )!;
    cli = resolution.unit('cli')!;

    final checklist = Checklist.derive(cli, resolution, Diagnostics());
    prerequisite =
        checklist.steps.firstWhere((s) => s.kind == StepKind.prerequisite);
    publish =
        checklist.steps.firstWhere((s) => s.kind == StepKind.publishRegistry);
  });

  Inspector inspector(FakeRegistry registry) => Inspector(
        registry: registry,
        pubDev: registry,
        git: GitState(
          root: '/repo',
          head: 'abc123def456',
          branch: 'main',
          isClean: true,
          uncommitted: const [],
          headIsPushed: true,
          tags: const [],
          signingConfigured: false,
          originUrl: null,
        ),
      );

  group('a prerequisite is read from the registry, never assumed', () {
    test('live when the exact version is published', () async {
      final state = await inspector(FakeRegistry({
        'example_core': ['0.3.0'],
      })).inspect(prerequisite, cli);

      expect(state.verdict, Verdict.exact);
    });

    test('absent when the version is not out yet — and re-running fixes it',
        () async {
      final state = await inspector(FakeRegistry({
        'example_core': ['0.2.0'],
      })).inspect(prerequisite, cli);

      expect(
        state.verdict,
        Verdict.absent,
        reason: 'reading it as live is what lets the dependent publish '
            'against a version consumers cannot resolve',
      );
      expect(state.detail, contains('not published yet'));
    });

    test('absent when the package has never existed', () async {
      final state =
          await inspector(FakeRegistry({})).inspect(prerequisite, cli);
      expect(state.verdict, Verdict.absent);
      expect(state.detail, contains('never been published'));
    });

    test('unknown when the registry cannot be read', () async {
      final state = await inspector(FakeRegistry({}, unreachable: true))
          .inspect(prerequisite, cli);
      expect(
        state.verdict,
        Verdict.unknown,
        reason: 'an unreachable registry is not an unpublished dependency',
      );
    });
  });

  group('a destination rk was not given a way to read answers unknown', () {
    test('the forge, without tools or an origin', () async {
      final diagnostics = Diagnostics();
      final config = ReleaseConfig.parse('''
schema = 2

[release.cli]
publish = ["git-tag", "github-release"]
binary_platforms = ["macos-arm64"]
''', 'release.toml', diagnostics)!;
      final binary = Resolution.resolve(
        config,
        MemorySourceTree({
          'pubspec.yaml': '''
name: example_tool
version: 1.0.0
publish_to: none
executables:
  example-tool: example_tool
''',
        }),
        diagnostics,
      )!;
      final unit = binary.unit('cli')!;
      final release = Checklist.derive(unit, binary, Diagnostics())
          .steps
          .firstWhere((s) => s.kind == StepKind.publishRelease);

      final state = await inspector(FakeRegistry({})).inspect(release, unit);
      expect(state.verdict, Verdict.unknown);
    });

    test('local work is unknown too — this run has not looked', () async {
      final state = await inspector(FakeRegistry({})).inspect(
        Step(
          id: 'cli/build/macos-arm64',
          kind: StepKind.build,
          unit: 'cli',
          summary: 'build',
          needs: const [],
        ),
        cli,
      );
      expect(state.verdict, Verdict.unknown);
    });
  });

  test('the publish step itself asks the registry about the right coordinate',
      () async {
    final state = await inspector(FakeRegistry({
      'example_cli': ['0.3.0'],
    })).inspect(publish, cli);
    expect(state.verdict, Verdict.exact);
  });
}

/// The classification tables, frozen the way the version vectors are.
///
/// These restate the implementation on purpose: they are contracts other code
/// keys on, and a mutation pass showed each line here can be flipped without
/// anything else noticing.
void classificationTables() {
  test('which step kinds have public state', () {
    expect(
      {
        for (final kind in StepKind.values) kind: Inspector.hasPublicState(kind)
      },
      {
        StepKind.tag: true,
        StepKind.prerequisite: true,
        StepKind.publishRegistry: true,
        StepKind.publishRelease: true,
        StepKind.publishCask: true,
        StepKind.build: false,
        StepKind.notarize: false,
        StepKind.archive: false,
        StepKind.completeStage: false,
      },
      reason: 'a prerequisite dropped from this set stops blocking a release '
          'whose dependency rk could not read',
    );
  });

  Step step(StepKind kind) => Step(
        id: 'u/x/y',
        unit: 'u',
        kind: kind,
        target: switch (kind) {
          StepKind.tag => PublishTarget.gitTag,
          StepKind.publishRegistry => PublishTarget.pubDev,
          StepKind.publishRelease => PublishTarget.githubRelease,
          StepKind.publishCask => PublishTarget.homebrew,
          _ => null,
        },
        summary: 'x',
        needs: const [],
      );

  test('what blocks a release, by verdict and kind', () {
    // Conflict always blocks; unknown blocks only where the state was
    // supposed to be readable; the one blocking absence is a prerequisite.
    expect(
      Inspector.blocks(
          step(StepKind.publishRegistry), const Inspection.conflict('differs')),
      isTrue,
    );
    expect(
      Inspector.blocks(
          step(StepKind.publishRelease), const Inspection.unknown('unread')),
      isTrue,
      reason: 'not knowing is not permission to publish',
    );
    expect(
      Inspector.blocks(step(StepKind.build), const Inspection.unknown('local')),
      isFalse,
      reason: 'local steps answer unknown by design — they are the work',
    );
    expect(
      Inspector.blocks(step(StepKind.prerequisite), const Inspection.absent()),
      isTrue,
      reason: 'the dependency has not shipped',
    );
    expect(
      Inspector.blocks(
          step(StepKind.publishRegistry), const Inspection.absent()),
      isFalse,
      reason: 'an absent coordinate is the work this release does',
    );
    expect(
      Inspector.blocks(
          step(StepKind.tag), const Inspection.exact(detail: 'tagged')),
      isFalse,
    );
  });

  group('an unread tag target is not agreement', () {
    Future<List<Diagnostic>> guardsFor({
      required Map<String, String> tagTargets,
    }) async {
      final resolution = await _binaryResolution();
      final unit = resolution.unit('cli')!; // 1.0.0, tag v1.0.0
      final git = GitState(
        root: '/repo',
        head: 'abc123def456',
        branch: 'main',
        isClean: true,
        uncommitted: const [],
        headIsPushed: true,
        tags: const ['v1.0.0'],
        tagTargets: tagTargets,
        signingConfigured: false,
        originUrl: 'example/tool',
      );
      final inspector = Inspector(registry: FakeRegistry({}), git: git);
      final checklist = Checklist.derive(unit, resolution, Diagnostics());
      // The version is not published yet, so the publish step is absent —
      // which is what arms both placement guards.
      final states = {
        for (final s in checklist.steps) s.id: const Inspection.absent(),
      };
      return inspector.tagGuards(unit, checklist, states);
    }

    test('unread refuses rather than reading as "at HEAD"', () async {
      // One unreachable tag object anywhere empties the whole map, so this
      // is reachable without the tag rk cares about being broken. Silent,
      // it publishes from a commit the tag does not name — and a burned
      // pub.dev version is what re-running cannot fix.
      final found = await guardsFor(tagTargets: const {});

      expect(found.map((d) => d.code), contains('RK-GIT-007'));
    });

    test('read and elsewhere still names the commit', () async {
      final found =
          await guardsFor(tagTargets: const {'v1.0.0': 'fedcba987654'});

      expect(found.map((d) => d.code), contains('RK-GIT-005'));
      final guard = found.singleWhere((d) => d.code == 'RK-GIT-005');
      expect(guard.remedy, isNot(contains('push -f')));
      expect(guard.remedy, contains('do not move it'));
    });

    test('the prose says unread too, not just the refusal', () async {
      final resolution = await _binaryResolution();
      final unit = resolution.unit('cli')!;
      final inspector = Inspector(
        registry: FakeRegistry({}),
        git: GitState(
          root: '/repo',
          head: 'abc123def456',
          branch: 'main',
          isClean: true,
          uncommitted: const [],
          headIsPushed: true,
          tags: const ['v1.0.0'],
          tagTargets: const {},
          signingConfigured: false,
          originUrl: 'example/tool',
        ),
        tools: ScriptedTools({
          'git': ToolResult(
            exitCode: 0,
            stdout: 'deadbeef refs/tags/v1.0.0',
            stderr: '',
          ),
        }),
      );
      final tag = Checklist.derive(unit, resolution, Diagnostics())
          .steps
          .firstWhere((s) => s.kind == StepKind.tag);

      final state = await inspector.inspect(tag, unit);
      expect(
        state.detail,
        contains('could not read'),
        reason: 'folding unread in with "at HEAD" is the same collapse the '
            'refusal below prevents, one surface along',
      );
    });

    test('read and at HEAD is quiet', () async {
      final found =
          await guardsFor(tagTargets: const {'v1.0.0': 'abc123def456'});

      expect(found, isEmpty);
    });
  });

  group('local monotonicity is a git fact, read without a registry', () {
    Future<List<Diagnostic>> problemsFor(List<String> tags) async {
      final inspector = Inspector(
        registry: null,
        git: GitState(
          root: '/repo',
          head: 'abc123def456',
          branch: 'main',
          isClean: true,
          uncommitted: const [],
          headIsPushed: true,
          tags: tags,
          signingConfigured: false,
          originUrl: 'example/tool',
        ),
      );
      final resolution = await _binaryResolution();
      final unit = resolution.unit('cli')!;
      final checklist = Checklist.derive(unit, resolution, Diagnostics());
      final targets = TargetCatalog.builtIn().derive(
        unit,
        checklist,
        repository: 'example/tool',
      );
      final problems = Diagnostics();
      // The unit is 1.0.0, so a v2.0.0 tag is a namespace already ahead.
      await inspector.releaseMonotonicity(
        unit,
        targets.where((target) => target.target == PublishTarget.gitTag),
        problems,
      );
      return problems.found;
    }

    test('the tag half is a local git fact, refused without any read',
        () async {
      final found = await problemsFor(['v2.0.0']);

      expect(
        found.map((d) => d.code),
        contains('RK-MONO-001'),
        reason: 'the tag loop reads git and nothing else — guarding it '
            'behind the registry handed --json callers an empty problems '
            'array for a repository whose tags are ahead of its manifests',
      );
    });
  });

  group('release monotonicity reads complete public histories', () {
    Future<({ResolvedUnit unit, List<TargetPlan> targets})>
        releaseTargets() async {
      final resolution = await _binaryResolution();
      final unit = resolution.unit('cli')!;
      final checklist = Checklist.derive(unit, resolution, Diagnostics());
      return (
        unit: unit,
        targets: TargetCatalog.builtIn().derive(
          unit,
          checklist,
          repository: 'example/tool',
        ),
      );
    }

    test('starts independent lane reads together and omits Homebrew', () async {
      final fixture = await releaseTargets();
      final inspector = _LatestInspector(expectedConcurrent: 3);
      final problems = Diagnostics();

      final checking = inspector.releaseMonotonicity(
        fixture.unit,
        fixture.targets,
        problems,
      );
      await inspector.allStarted.future;

      expect(inspector.maximumActive, 3);
      expect(
        inspector.started,
        {'gitTag', 'pubDev', 'githubRelease'},
        reason: 'the authenticated cask inspection already owns the '
            'Homebrew forward-only decision',
      );
      inspector.finish();
      await checking;
      expect(problems, isEmpty);
    });

    test('an unreadable lane is a refusal and newer remote lanes are named',
        () async {
      final fixture = await releaseTargets();
      final inspector = _LatestInspector(answers: {
        'gitTag': const Inspection.exact(
          evidence: {'version': '2.0.0'},
        ),
        'pubDev': const Inspection.exact(
          evidence: {'version': '1.1.0'},
        ),
        'githubRelease': const Inspection.unknown('GitHub timed out'),
      });
      final problems = Diagnostics();

      await inspector.releaseMonotonicity(
        fixture.unit,
        fixture.targets,
        problems,
      );

      expect(
        problems.found.map((problem) => problem.code),
        containsAll(['RK-MONO-002', 'RK-MONO-003', 'RK-REL-001']),
      );
      expect(
        problems.found
            .singleWhere((problem) => problem.code == 'RK-MONO-003')
            .message,
        allOf(contains('Git tag'), contains('2.0.0'), contains('1.0.0')),
      );
      expect(
        problems.found
            .singleWhere((problem) => problem.code == 'RK-REL-001')
            .message,
        allOf(contains('GitHub Release'), contains('timed out')),
      );
    });

    test('a foreign pub.dev repository keeps its provider-specific remedy',
        () async {
      final fixture = await releaseTargets();
      final inspector = _LatestInspector(answers: {
        'pubDev': const Inspection.conflict(
          'example_cli points to another repository on pub.dev',
          evidence: {
            'published repository': 'https://github.com/another/example_cli',
            'this repository': 'https://github.com/example/tool',
          },
        ),
      });
      final problems = Diagnostics();

      await inspector.releaseMonotonicity(
        fixture.unit,
        fixture.targets,
        problems,
      );

      final diagnostic = problems.found.singleWhere(
        (problem) => problem.code == 'RK-PUB-010',
      );
      expect(diagnostic.message, contains('another/example_cli'));
      expect(diagnostic.remedy, contains('choose an unclaimed package name'));
      expect(
        problems.found.where((problem) => problem.code == 'RK-REL-001'),
        isEmpty,
      );
    });

    test('one remote ahead tag is not repeated as a local-tag problem',
        () async {
      final fixture = await releaseTargets();
      final inspector = _LatestInspector(
        tags: const ['v2.0.0'],
        answers: {
          'gitTag': const Inspection.exact(
            evidence: {'version': '2.0.0'},
          ),
        },
      );
      final problems = Diagnostics();

      await inspector.releaseMonotonicity(
        fixture.unit,
        fixture.targets,
        problems,
      );

      expect(
        problems.found
            .where((problem) =>
                problem.code == 'RK-MONO-001' || problem.code == 'RK-MONO-003')
            .map((problem) => problem.code),
        ['RK-MONO-003'],
      );
    });
  });

  group('an unread origin never reports a tag as done', () {
    Future<Inspection> tagUnread({required List<String> tags}) async {
      final inspector = Inspector(
        registry: FakeRegistry({}),
        git: GitState(
          root: '/repo',
          head: 'abc123def456',
          branch: 'main',
          isClean: true,
          uncommitted: const [],
          headIsPushed: true,
          tags: tags,
          tagTargets: {for (final t in tags) t: 'abc123def456'},
          signingConfigured: false,
          originUrl: 'example/tool',
        ),
      );
      return inspector.inspect(
        Step(
          id: 'cli/tag',
          unit: 'cli',
          kind: StepKind.tag,
          target: PublishTarget.gitTag,
          summary: 'tag the release',
          needs: const [],
        ),
        await _binaryUnit(),
      );
    }

    test('a local-only tag is unknown, never exact', () async {
      final state = await tagUnread(tags: ['v1.0.0']);

      expect(
        state.verdict,
        Verdict.unknown,
        reason: 'origin was not read, and a local tag is not a pushed tag — '
            'exact here would make not reading the more confident answer '
            'than reading, which online returns absent for this same world',
      );
      expect(state.detail, contains('no tools to read origin with'));
    });

    test('no local tag is unknown because origin was not read', () async {
      final state = await tagUnread(tags: const []);

      expect(
        state.verdict,
        Verdict.unknown,
        reason: 'a fresh clone can lack a tag that origin already has; local '
            'absence is not public absence',
      );
    });
  });

  test('the cask is unknown until a tap reader exists', () async {
    final inspector = Inspector(
      registry: FakeRegistry({}),
      git: GitState(
        root: '/repo',
        head: 'abc123def456',
        branch: 'main',
        isClean: true,
        uncommitted: const [],
        headIsPushed: true,
        tags: const [],
        signingConfigured: false,
        originUrl: null,
      ),
    );
    final state = await inspector.inspect(
      Step(
        id: 'cli/homebrew/example_tool/example-tool',
        unit: 'cli',
        project: 'example_tool',
        kind: StepKind.publishCask,
        target: PublishTarget.homebrew,
        summary: 'update the cask',
        needs: const [],
      ),
      (await _binaryUnit()),
    );
    expect(
      state.verdict,
      Verdict.unknown,
      reason: 'absent would report a cask that may already point at this '
          'release as work still to do',
    );
  });

  group('the cask inspection reads the public tap', () {
    Future<Inspection> cask(ToolResult? Function(String key) answers) async {
      final inspector = Inspector(
        registry: FakeRegistry({}),
        git: GitState(
          root: '/repo',
          head: 'abc123def456',
          branch: 'main',
          isClean: true,
          uncommitted: const [],
          headIsPushed: true,
          tags: const [],
          signingConfigured: false,
          originUrl: 'example/tool',
        ),
        tools: RecordingTools(answers: answers),
        repository: 'example/tool',
      );
      return inspector.inspect(
        Step(
          id: 'cli/homebrew/example_tool/example-tool',
          unit: 'cli',
          project: 'example_tool',
          kind: StepKind.publishCask,
          target: PublishTarget.homebrew,
          summary: 'update the cask',
          needs: const [],
        ),
        (await _binaryUnit()),
      );
    }

    String contentsOf(String text) =>
        '{"content":"${base64Encode(utf8.encode(text))}"}';

    test('a hand-written cask is a conflict without a manifest proof',
        () async {
      final state = await cask((key) => key.contains('/contents/')
          ? ok(contentsOf('class T < Cask\n  version "1.0.0"\nend\n'))
          : null);
      expect(state.verdict, Verdict.conflict);
      expect(state.detail, contains('not a recognizable rk-generated'));
    });

    test('an older-looking cask is not trusted without exact bytes', () async {
      // A version substring in arbitrary Ruby is not authority to overwrite
      // the file. Only RK's generated channel format may advance.
      final state = await cask((key) => key.contains('/contents/')
          ? ok(contentsOf('class T < Cask\n  version "0.9.0"\nend\n'))
          : null);
      expect(state.verdict, Verdict.conflict);
    });

    test('404 with a readable tap is absent; with an unreadable tap, unknown',
        () async {
      final missing = await cask((key) {
        if (key.contains('/contents/')) {
          return failed('gh: Not Found (HTTP 404)');
        }
        if (key.startsWith('gh repo view')) return ok('{"name":"tap"}');
        return null;
      });
      expect(missing.verdict, Verdict.absent);

      final unreadable = await cask((key) {
        if (key.contains('/contents/')) {
          return failed('gh: Not Found (HTTP 404)');
        }
        if (key.startsWith('gh repo view')) {
          return failed('Could not resolve to a Repository');
        }
        return null;
      });
      expect(
        unreadable.verdict,
        Verdict.unknown,
        reason: 'GitHub answers 404 for a tap the token cannot see, and '
            'absent is what lets the step act',
      );
    });

    test('an answer that does not decode is unknown, never absent', () async {
      final state = await cask(
          (key) => key.contains('/contents/') ? ok('not json at all') : null);
      expect(state.verdict, Verdict.unknown);
    });
  });

  test('the checklist summary counts the same assets the inspector expects',
      () async {
    // Both derivations read ReleaseAssets now, so comparing them to each
    // other would compare a thing to itself. The pin is the literal: this
    // fixture's frozen four-name vector lives in the sibling test below, and
    // a summary that says any other number has drifted from the grammar
    // whatever the grammar says.
    final resolution = await _binaryResolution();
    final unit = resolution.unit('cli')!;
    final steps = Checklist.derive(unit, resolution, Diagnostics()).steps;
    final summary =
        steps.firstWhere((s) => s.kind == StepKind.publishRelease).summary;
    final counted = int.parse(
        RegExp(r'publish (\d+) assets').firstMatch(summary)!.group(1)!);
    expect(counted, 3);
  });

  test('the expected asset set is derived, and derives everything', () async {
    final unit = await _binaryUnit();
    expect(
      Inspector.expectedAssets(unit),
      {
        'example-tool-1.0.0-linux-x64.tar.gz',
        'example-tool-1.0.0-macos-arm64.tar.gz',
        'release-manifest.json',
      },
      reason: 'emptied, every release inspects exact and nothing notices. '
          'Notary evidence is stage-local: a consumer verifies the binary '
          'with Apple directly, so the JSON files beside it stopped being '
          'assets',
    );
  });
}

Future<ResolvedUnit> _binaryUnit() async =>
    (await _binaryResolution()).unit('cli')!;

class _LatestInspector extends Inspector {
  _LatestInspector({
    this.answers = const {},
    this.expectedConcurrent = 0,
    List<String> tags = const [],
  }) : super(
          registry: FakeRegistry({}),
          git: GitState(
            root: '/repo',
            head: '1111111111111111111111111111111111111111',
            branch: 'main',
            isClean: true,
            uncommitted: const [],
            headIsPushed: true,
            tags: tags,
            signingConfigured: true,
            originUrl: 'example/tool',
          ),
        );

  final Map<String, Inspection> answers;
  final int expectedConcurrent;
  final Completer<void> allStarted = Completer<void>();
  final Completer<void> _finish = Completer<void>();
  final Set<String> started = {};
  var active = 0;
  var maximumActive = 0;

  @override
  Future<TargetHistory?> inspectHistory(
    TargetPlan target,
    ResolvedUnit unit, {
    bool fresh = false,
  }) async {
    if (target.kind == 'homebrew') return null;
    started.add(target.kind);
    if (expectedConcurrent > 0) {
      active++;
      if (active > maximumActive) maximumActive = active;
      if (started.length == expectedConcurrent && !allStarted.isCompleted) {
        allStarted.complete();
      }
      await _finish.future;
      active--;
    }
    final inspection = answers[target.kind] ?? const Inspection.absent();
    if (target.kind == 'pubDev' && inspection.verdict == Verdict.conflict) {
      final project = target.project!;
      final published = inspection.evidence['published repository'];
      final local = inspection.evidence['this repository'];
      return TargetHistory(
        inspection: inspection,
        problems: [
          Diagnostic(
            code: 'RK-PUB-010',
            message: '${project.name} on pub.dev points to $published, not '
                '$local',
            remedy: 'choose an unclaimed package name in pubspec.yaml; '
                'pub.dev package names cannot be reclaimed by publishing '
                'a newer version',
          ),
        ],
      );
    }
    return TargetHistory.versioned(
      inspection: inspection,
      target: target,
      regressionDiagnostic: target.kind == 'pubDev'
          ? (publicVersion) => Diagnostic(
                code: 'RK-MONO-002',
                message: '${target.project!.name} ${target.targetVersion} is '
                    'behind published version $publicVersion',
                remedy: 'a release moves forward — bump past $publicVersion',
              )
          : null,
    );
  }

  void finish() {
    if (!_finish.isCompleted) _finish.complete();
  }
}

Future<Resolution> _binaryResolution() async {
  final diagnostics = Diagnostics();
  final config = ReleaseConfig.parse('''
schema = 2

[release.cli]
publish = ["git-tag", "pub.dev", "github-release", "homebrew"]
binary_platforms = ["linux-x64", "macos-arm64"]
''', 'release.toml', diagnostics)!;
  return Resolution.resolve(
    config,
    MemorySourceTree({
      'pubspec.yaml': '''
name: example_tool
version: 1.0.0
executables:
  example-tool: example_tool
''',
    }),
    diagnostics,
  )!;
}

/// The tag's remote half — the leg whose absence let a killed push produce a
/// release whose authorizing tag existed only on one machine.
void tagRemoteLeg() {
  const head = '1111111111111111111111111111111111111111';
  const object = '2222222222222222222222222222222222222222';
  const digest =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  ToolResult annotatedTagObject() => ToolResult(
        exitCode: 0,
        stdout: 'object $head\n'
            'type commit\n'
            'tag v0.2.0\n'
            'tagger Test <test@example.com> 0 +0000\n\n'
            'core 0.2.0\n\n'
            'release-manifest-sha256: $digest\n',
        stderr: '',
      );

  GitState gitWith({
    List<String> tags = const [],
    Map<String, String> tagObjects = const {},
    bool signing = false,
  }) =>
      GitState(
        root: '/repo',
        head: head,
        branch: 'main',
        isClean: true,
        uncommitted: const [],
        headIsPushed: true,
        tags: tags,
        tagTargets: {
          for (final tag in tags) tag: head,
        },
        tagObjects: tagObjects,
        signingConfigured: signing,
        originUrl: 'example/keybay',
      );

  Future<Inspection> inspectTag({
    required List<String> localTags,
    required ToolResult remote,
    Map<String, String> tagObjects = const {},
    bool signing = false,
    Map<String, ToolResult> additionalResults = const {},
  }) async {
    final diagnostics = Diagnostics();
    final config = ReleaseConfig.parse('''
schema = 2

[release.core]
path = "packages/keybay"
publish = ["git-tag", "pub.dev"]
''', 'release.toml', diagnostics)!;
    final resolution = Resolution.resolve(
      config,
      MemorySourceTree({
        'packages/keybay/pubspec.yaml': 'name: keybay\nversion: 0.2.0\n',
      }),
      diagnostics,
    )!;
    final unit = resolution.unit('core')!;
    final step = Checklist.derive(unit, resolution, Diagnostics())
        .steps
        .firstWhere((s) => s.kind == StepKind.tag);

    return Inspector(
      registry: FakeRegistry({}),
      git: gitWith(
        tags: localTags,
        tagObjects: tagObjects,
        signing: signing,
      ),
      tools: RecordingTools(
        results: {
          'git ls-remote origin refs/tags/v0.2.0 '
              'refs/tags/v0.2.0^{}': remote,
          ...additionalResults,
        },
      ),
      repository: 'example/keybay',
    ).inspect(step, unit);
  }

  test('an annotated origin tag with a readable release binding is done',
      () async {
    final state = await inspectTag(
      localTags: const [],
      remote: ToolResult(
        exitCode: 0,
        stdout: '$object refs/tags/v0.2.0\n'
            '$head refs/tags/v0.2.0^{}',
        stderr: '',
      ),
      additionalResults: {'git cat-file tag $object': annotatedTagObject()},
    );
    expect(state.verdict, Verdict.exact);
    expect(state.detail, contains('release manifest'));
  });

  test('a fresh checkout never calls a matching lightweight ref exact',
      () async {
    final state = await inspectTag(
      localTags: const [],
      remote: ToolResult(
        exitCode: 0,
        stdout: '$head refs/tags/v0.2.0',
        stderr: '',
      ),
    );

    expect(state.verdict, Verdict.conflict);
    expect(state.detail, contains('lightweight release tag'));
  });

  test('a fresh checkout does not call a peeled commit exact by itself',
      () async {
    final state = await inspectTag(
      localTags: const [],
      remote: ToolResult(
        exitCode: 0,
        stdout: '$object refs/tags/v0.2.0\n'
            '$head refs/tags/v0.2.0^{}',
        stderr: '',
      ),
      additionalResults: {
        'git cat-file tag $object': ToolResult(
          exitCode: 128,
          stdout: '',
          stderr: 'fatal: Not a valid object name',
        ),
      },
    );

    expect(state.verdict, Verdict.unknown);
    expect(state.detail, contains('tag object could not be read'));
  });

  test('a definitively absent remote tag stays absent in a fresh checkout',
      () async {
    final state = await inspectTag(
      localTags: const [],
      remote: ToolResult(exitCode: 0, stdout: '', stderr: ''),
    );

    expect(state.verdict, Verdict.absent);
    expect(state.detail, contains('not on origin'));
  });

  test('local but not on origin is work remaining, not done', () async {
    final state = await inspectTag(
      localTags: const ['v0.2.0'],
      tagObjects: const {'v0.2.0': object},
      remote: ToolResult(exitCode: 0, stdout: '', stderr: ''),
      additionalResults: {'git cat-file tag $object': annotatedTagObject()},
    );
    expect(
      state.verdict,
      Verdict.absent,
      reason: 'read as done, a killed push produced a release whose '
          'authorizing tag existed only on this machine — silently',
    );
    expect(state.detail, contains('not on origin'));
  });

  test('an unreadable origin is unknown, which blocks', () async {
    final state = await inspectTag(
      localTags: ['v0.2.0'],
      remote: ToolResult(
          exitCode: 128, stdout: '', stderr: 'could not resolve host'),
    );
    expect(state.verdict, Verdict.unknown);
  });

  test(
      'a configured tag remains non-exact when its signature fails without '
      'a stage', () async {
    final state = await inspectTag(
      localTags: const ['v0.2.0'],
      tagObjects: const {'v0.2.0': object},
      signing: true,
      remote: ToolResult(
        exitCode: 0,
        stdout: '$object refs/tags/v0.2.0\n'
            '$head refs/tags/v0.2.0^{}',
        stderr: '',
      ),
      additionalResults: {
        'git cat-file tag $object': ToolResult(
          exitCode: 0,
          stdout: 'object $head\n'
              'type commit\n'
              'tag v0.2.0\n'
              'tagger Test <test@example.com> 0 +0000\n\n'
              'core 0.2.0\n\n'
              'release-manifest-sha256: $digest\n',
          stderr: '',
        ),
        'git verify-tag $object': ToolResult(
          exitCode: 1,
          stdout: '',
          stderr: 'BAD signature',
        ),
      },
    );

    expect(state.verdict, Verdict.conflict);
    expect(state.detail, contains('signature could not be verified'));
  });

  test(
      'a known unsigned lightweight tag is not an exact release record '
      'without a stage', () async {
    final state = await inspectTag(
      localTags: const ['v0.2.0'],
      tagObjects: const {'v0.2.0': head},
      remote: ToolResult(
        exitCode: 0,
        stdout: '$head refs/tags/v0.2.0',
        stderr: '',
      ),
    );

    expect(state.verdict, Verdict.conflict);
    expect(state.detail, contains('lightweight release tag'));
  });
}
