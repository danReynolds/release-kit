import 'dart:async';
import 'dart:convert';

import 'package:rk/src/engine/assets.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/git.dart';
import 'package:rk/src/engine/inspect.dart';
import 'package:rk/src/engine/publish_target.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/stage.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/engine/unit_release.dart';
import 'package:rk/src/engine/verdict.dart';
import 'package:rk/src/targets/target_module.dart';
import 'package:test/test.dart';

import 'scripted_tools.dart';
import 'status_test.dart' show FakeRegistry;
import 'support/memory_source_tree.dart';

/// The shared inspector, driven step by step.
///
/// A mutation found the hole this file closes: making a prerequisite that is
/// not live read as "live" broke nothing in the whole suite, so the cross-unit
/// ordering rule — the dependency publishes before its dependent — was
/// enforced by no executable test.
void main() {
  targetReads();
  tagRemoteLeg();

  late Resolution resolution;
  late ResolvedUnit cli;
  late Step prerequisite;
  late Step publish;

  setUp(() {
    final diagnostics = Diagnostics();
    final config = ReleaseConfig.parse(
      '''
schema = 2

[release.core]
tag = "example_core-v{version}"
path = "packages/core"
publish = ["git-tag", "pub.dev"]

[release.cli]
tag = "example_cli-v{version}"
path = "packages/cli"
publish = ["git-tag", "pub.dev"]
''',
      'release.toml',
      diagnostics,
    )!;
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

    final release = _derive(cli, resolution);
    prerequisite = release.requirements.single;
    publish = release.packages.single;
  });

  Inspector inspector(FakeRegistry registry, {Tools? tools}) => Inspector(
    registry: registry,
    pubDev: registry,
    tools: tools,
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
      final state = await inspector(
        FakeRegistry({
          'example_core': ['0.3.0'],
        }),
      ).inspect(prerequisite, cli);

      expect(state.verdict, Verdict.exact);
    });

    test(
      'absent when the version is not out yet — and re-running fixes it',
      () async {
        final state = await inspector(
          FakeRegistry({
            'example_core': ['0.2.0'],
          }),
        ).inspect(prerequisite, cli);

        expect(
          state.verdict,
          Verdict.absent,
          reason:
              'reading it as live is what lets the dependent publish '
              'against a version consumers cannot resolve',
        );
        expect(state.detail, contains('not published yet'));
      },
    );

    test('absent when the package has never existed', () async {
      final state = await inspector(
        FakeRegistry({}),
      ).inspect(prerequisite, cli);
      expect(state.verdict, Verdict.absent);
      expect(state.detail, contains('never been published'));
    });

    test('unknown when the registry cannot be read', () async {
      final state = await inspector(
        FakeRegistry({}, unreachable: true),
      ).inspect(prerequisite, cli);
      expect(
        state.verdict,
        Verdict.unknown,
        reason: 'an unreachable registry is not an unpublished dependency',
      );
    });
  });

  group('what this run cannot read is unknown, never absent', () {
    test('the forge, when the repository has no origin remote', () async {
      final diagnostics = Diagnostics();
      final config = ReleaseConfig.parse(
        '''
schema = 2

[release.cli]
publish = ["git-tag", "github-release"]
binary_platforms = ["macos-arm64"]
''',
        'release.toml',
        diagnostics,
      )!;
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
      final release = _derive(unit, binary).github!;

      final tools = ScriptedTools({});
      final state = await inspector(
        FakeRegistry({}),
        tools: tools,
      ).inspect(release, unit);
      expect(state.verdict, Verdict.unknown);
      expect(state.detail, 'no origin remote to ask');
      expect(tools.calls, isEmpty, reason: 'there is no forge to ask');
    });

    test('local work is unknown too — this run has not looked', () async {
      final resolution = await _binaryResolution();
      final unit = resolution.unit('cli')!;
      final state = await inspector(FakeRegistry({})).inspect(
        _derive(unit, resolution).step('cli/build/example_tool/macos-arm64')!,
        unit,
      );
      expect(state.verdict, Verdict.unknown);
    });
  });

  test(
    'the publish step itself asks the registry about the right coordinate',
    () async {
      final state = await inspector(
        FakeRegistry({
          'example_cli': ['0.3.0'],
        }),
      ).inspect(publish, cli);
      expect(state.verdict, Verdict.exact);
    },
  );
}

/// How each target's public state is read, and what that reading blocks.
void targetReads() {
  group('a tag released from an earlier commit', () {
    Future<List<Diagnostic>> guardsFor({
      required bool finished,
      Inspection rest = const Inspection.absent(),
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
        tagTargets: const {'v1.0.0': 'fedcba9876543210'},
        signingConfigured: false,
        originUrl: 'example/tool',
      );
      final inspector = Inspector(registry: FakeRegistry({}), git: git);
      final release = _derive(unit, resolution);
      // What the tag inspection answers when the unit's own files are
      // unchanged since the tagged commit.
      final states = {
        for (final s in release.steps)
          s.id: s.kind == StepKind.tag
              ? const Inspection.exact(
                  detail: 'nothing this unit releases has changed since',
                  releasedFrom: 'fedcba9876543210',
                )
              : finished
              ? const Inspection.exact(detail: 'published')
              : rest,
      };
      return inspector.tagGuards(unit, release, states);
    }

    test('is released once everything it publishes is out', () async {
      expect(await guardsFor(finished: true), isEmpty);
    });

    test('finishes an unfinished release from that commit, not this '
        'one', () async {
      // The tag binds what was staged at its commit. Finishing from HEAD
      // would publish HEAD's bytes under it.
      final found = await guardsFor(finished: false);

      final guard = found.singleWhere((d) => d.code == 'RK-GIT-009');
      expect(
        guard.message,
        'v1.0.0 was released from fedcba987654, and its '
        'release is unfinished',
      );
      expect(
        guard.remedy,
        contains('git checkout fedcba9876543210\n'),
        reason: 'the commit origin names, not a local ref that may differ',
      );
      expect(guard.remedy, contains('rk release cli'));
    });

    test('leaves what it cannot read to that target', () async {
      // Unread is not unfinished: the target's own refusal says what is
      // wrong, and sending the operator to the tag would not help.
      final found = await guardsFor(
        finished: false,
        rest: const Inspection.unknown('gh is not signed in'),
      );

      expect(found.map((d) => d.code), isNot(contains('RK-GIT-009')));
    });
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
      final release = _derive(unit, resolution);
      // The version is not published yet, so the publish step is absent —
      // which is what arms both placement guards.
      final states = {
        for (final s in release.steps) s.id: const Inspection.absent(),
      };
      return inspector.tagGuards(unit, release, states);
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
      final found = await guardsFor(
        tagTargets: const {'v1.0.0': 'fedcba987654'},
      );

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
      final tag = _derive(unit, resolution).tag!;

      final state = await inspector.inspect(tag, unit);
      expect(
        state.detail,
        contains('could not read'),
        reason:
            'folding unread in with "at HEAD" is the same collapse the '
            'refusal below prevents, one surface along',
      );
    });

    test('read and at HEAD is quiet', () async {
      final found = await guardsFor(
        tagTargets: const {'v1.0.0': 'abc123def456'},
      );

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
      final targets = _derive(
        unit,
        resolution,
        repository: 'example/tool',
      ).targets;
      // The unit is 1.0.0, so a v2.0.0 tag is a namespace already ahead.
      return _history(
        inspector,
        unit,
        targets.where((target) => target.target == PublishTarget.gitTag),
      );
    }

    test(
      'the tag half is a local git fact, refused without any read',
      () async {
        final found = await problemsFor(['v2.0.0']);

        expect(
          found.map((d) => d.code),
          contains('RK-MONO-001'),
          reason:
              'the tag loop reads git and nothing else — guarding it '
              'behind the registry handed --json callers an empty problems '
              'array for a repository whose tags are ahead of its manifests',
        );
      },
    );
  });

  group('release monotonicity reads complete public histories', () {
    Future<({ResolvedUnit unit, List<Target> targets})> releaseTargets() async {
      final resolution = await _binaryResolution();
      final unit = resolution.unit('cli')!;
      return (
        unit: unit,
        targets: _derive(unit, resolution, repository: 'example/tool').targets,
      );
    }

    test(
      'an unreadable lane is a refusal and newer remote lanes are named',
      () async {
        final fixture = await releaseTargets();
        final inspector = _LatestInspector(
          answers: {
            'gitTag': const Inspection.exact(evidence: {'version': '2.0.0'}),
            'pubDev': const Inspection.exact(evidence: {'version': '1.1.0'}),
            'githubRelease': const Inspection.unknown('GitHub timed out'),
          },
        );
        final found = await _history(inspector, fixture.unit, fixture.targets);

        expect(
          found.map((problem) => problem.code),
          containsAll(['RK-MONO-002', 'RK-MONO-003', 'RK-REL-001']),
        );
        expect(
          found.singleWhere((problem) => problem.code == 'RK-MONO-003').message,
          allOf(contains('Git tag'), contains('2.0.0'), contains('1.0.0')),
        );
        expect(
          found.singleWhere((problem) => problem.code == 'RK-REL-001').message,
          allOf(contains('GitHub Release'), contains('timed out')),
        );
      },
    );

    test(
      'one remote ahead tag is not repeated as a local-tag problem',
      () async {
        final fixture = await releaseTargets();
        final inspector = _LatestInspector(
          tags: const ['v2.0.0'],
          answers: {
            'gitTag': const Inspection.exact(evidence: {'version': '2.0.0'}),
          },
        );
        final found = await _history(inspector, fixture.unit, fixture.targets);

        expect(
          found
              .where(
                (problem) =>
                    problem.code == 'RK-MONO-001' ||
                    problem.code == 'RK-MONO-003',
              )
              .map((problem) => problem.code),
          ['RK-MONO-003'],
        );
      },
    );
  });

  group('the formula inspection reads the public tap', () {
    Future<Inspection> formula(ToolResult? Function(String key) answers) async {
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
      final resolution = await _binaryResolution();
      final unit = resolution.unit('cli')!;
      return inspector.inspect(
        _derive(unit, resolution, repository: 'example/tool').homebrew!,
        unit,
      );
    }

    String contentsOf(String text) =>
        '{"content":"${base64Encode(utf8.encode(text))}"}';

    test(
      'a hand-written formula is a conflict without a manifest proof',
      () async {
        final state = await formula(
          (key) => key.contains('/contents/')
              ? ok(contentsOf('class T < Formula\n  version "1.0.0"\nend\n'))
              : null,
        );
        expect(state.verdict, Verdict.conflict);
        expect(state.detail, contains('not a recognizable rk-generated'));
      },
    );

    test(
      'an older-looking formula is not trusted without exact bytes',
      () async {
        // A version substring in arbitrary Ruby is not authority to overwrite
        // the file. Only RK's generated channel format may advance.
        final state = await formula(
          (key) => key.contains('/contents/')
              ? ok(contentsOf('class T < Formula\n  version "0.9.0"\nend\n'))
              : null,
        );
        expect(state.verdict, Verdict.conflict);
      },
    );

    test(
      '404 with a readable tap is absent; with an unreadable tap, unknown',
      () async {
        final missing = await formula((key) {
          if (key.contains('/contents/')) {
            return failed('gh: Not Found (HTTP 404)');
          }
          if (key.startsWith('gh repo view')) return ok('{"name":"tap"}');
          return null;
        });
        expect(missing.verdict, Verdict.absent);

        final unreadable = await formula((key) {
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
          reason:
              'GitHub answers 404 for a tap the token cannot see, and '
              'absent is what lets the step act',
        );
      },
    );

    test('an answer that does not decode is unknown, never absent', () async {
      final state = await formula(
        (key) => key.contains('/contents/') ? ok('not json at all') : null,
      );
      expect(state.verdict, Verdict.unknown);
    });
  });

  test('the expected asset set is derived, and derives everything', () async {
    final unit = await _binaryUnit();
    expect(
      ReleaseAssets.expectedForUnit(unit),
      {
        'example-tool-1.0.0-linux-x64.tar.gz',
        'example-tool-1.0.0-macos-arm64.tar.gz',
        'release-manifest.json',
      },
      reason:
          'emptied, every release inspects exact and nothing notices. '
          'Notary evidence is stage-local: a consumer verifies the binary '
          'with Apple directly, so the JSON files beside it stopped being '
          'assets',
    );
  });
}

Future<ResolvedUnit> _binaryUnit() async =>
    (await _binaryResolution()).unit('cli')!;

/// What a release learns from [targets]' histories, read as a unit
/// snapshot reads them.
Future<List<Diagnostic>> _history(
  Inspector inspector,
  ResolvedUnit unit,
  Iterable<Target> targets,
) async {
  final listed = targets.toList();
  final read = [
    for (final read in await Future.wait([
      for (final target in listed) inspector.read(target, unit),
    ]))
      read.history,
  ];
  final problems = Diagnostics();
  Inspector.historyFindings([
    for (final (index, target) in listed.indexed) (target, read[index]),
  ], problems);
  return problems.found;
}

class _LatestInspector extends Inspector {
  _LatestInspector({this.answers = const {}, List<String> tags = const []})
    : super(
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

  @override
  Future<TargetRead> read(
    Target target,
    ResolvedUnit unit, {
    Stage? stage,
  }) async => (state: const Inspection.absent(), history: _history(target));

  TargetHistory? _history(Target target) {
    final kind = target.target.wireName;
    if (kind == 'homebrew') return null;
    final inspection = answers[kind] ?? const Inspection.absent();
    return TargetHistory.versioned(
      inspection: inspection,
      target: target,
      regressionDiagnostic: kind == 'pubDev'
          ? (publicVersion) => Diagnostic(
              code: 'RK-MONO-002',
              message:
                  '${target.project!.name} ${target.targetVersion} is '
                  'behind published version $publicVersion',
              remedy: 'a release moves forward — bump past $publicVersion',
            )
          : null,
    );
  }
}

Future<Resolution> _binaryResolution() async {
  final diagnostics = Diagnostics();
  final config = ReleaseConfig.parse(
    '''
schema = 2

[release.cli]
publish = ["git-tag", "pub.dev", "github-release", "homebrew"]
binary_platforms = ["linux-x64", "macos-arm64"]
''',
    'release.toml',
    diagnostics,
  )!;
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
    stdout:
        'object $head\n'
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
  }) => GitState(
    root: '/repo',
    head: head,
    branch: 'main',
    isClean: true,
    uncommitted: const [],
    headIsPushed: true,
    tags: tags,
    tagTargets: {for (final tag in tags) tag: head},
    tagObjects: tagObjects,
    signingConfigured: signing,
    tagSigningRequested: signing,
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
    final config = ReleaseConfig.parse(
      '''
schema = 2

[release.core]
path = "packages/keybay"
publish = ["git-tag", "pub.dev"]
''',
      'release.toml',
      diagnostics,
    )!;
    final resolution = Resolution.resolve(
      config,
      MemorySourceTree({
        'packages/keybay/pubspec.yaml': 'name: keybay\nversion: 0.2.0\n',
      }),
      diagnostics,
    )!;
    final unit = resolution.unit('core')!;
    final step = _derive(unit, resolution).tag!;

    return Inspector(
      registry: FakeRegistry({}),
      git: gitWith(tags: localTags, tagObjects: tagObjects, signing: signing),
      tools: RecordingTools(
        results: {'git ls-remote --tags origin': remote, ...additionalResults},
      ),
      repository: 'example/keybay',
    ).inspect(step, unit);
  }

  test(
    'an annotated origin tag with a readable release binding is done',
    () async {
      final state = await inspectTag(
        localTags: const [],
        remote: ToolResult(
          exitCode: 0,
          stdout:
              '$object refs/tags/v0.2.0\n'
              '$head refs/tags/v0.2.0^{}',
          stderr: '',
        ),
        additionalResults: {'git cat-file tag $object': annotatedTagObject()},
      );
      expect(state.verdict, Verdict.exact);
      expect(state.detail, contains('release manifest'));
    },
  );

  test(
    'a fresh checkout never calls a matching lightweight ref exact',
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
    },
  );

  test(
    'a fresh checkout does not call a peeled commit exact by itself',
    () async {
      final state = await inspectTag(
        localTags: const [],
        remote: ToolResult(
          exitCode: 0,
          stdout:
              '$object refs/tags/v0.2.0\n'
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
    },
  );

  test(
    'a definitively absent remote tag stays absent in a fresh checkout',
    () async {
      final state = await inspectTag(
        localTags: const [],
        remote: ToolResult(exitCode: 0, stdout: '', stderr: ''),
      );

      expect(state.verdict, Verdict.absent);
      expect(state.detail, contains('not on origin'));
    },
  );

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
      reason:
          'read as done, a killed push produced a release whose '
          'authorizing tag existed only on this machine — silently',
    );
    expect(state.detail, contains('not on origin'));
  });

  test('an unreadable origin is unknown, which blocks', () async {
    final state = await inspectTag(
      localTags: ['v0.2.0'],
      remote: ToolResult(
        exitCode: 128,
        stdout: '',
        stderr: 'could not resolve host',
      ),
    );
    expect(state.verdict, Verdict.unknown);
  });

  test(
    'a signed tag this machine cannot verify is still the release: a '
    'key that expired or lives elsewhere changes nothing published',
    () async {
      final state = await inspectTag(
        localTags: const ['v0.2.0'],
        tagObjects: const {'v0.2.0': object},
        signing: true,
        remote: ToolResult(
          exitCode: 0,
          stdout:
              '$object refs/tags/v0.2.0\n'
              '$head refs/tags/v0.2.0^{}',
          stderr: '',
        ),
        additionalResults: {
          'git cat-file tag $object': ToolResult(
            exitCode: 0,
            stdout:
                'object $head\n'
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
            stderr: 'error: key expired',
          ),
        },
      );

      expect(state.verdict, Verdict.exact, reason: state.detail);
    },
  );

  test('a known unsigned lightweight tag is not an exact release record '
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

/// [unit]'s release, as every command derives it.
UnitRelease _derive(
  ResolvedUnit unit,
  Resolution resolution, {
  String? repository,
}) => UnitRelease.derive(
  unit,
  resolution,
  repository: repository,
  problems: Diagnostics(),
);
