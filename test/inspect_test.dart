import 'package:rk/src/engine/checklist.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/git.dart';
import 'package:rk/src/engine/inspect.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/engine/verdict.dart';
import 'package:test/test.dart';

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
schema = 1

[release.core]
path = "packages/core"
publish = ["pub.dev"]

[release.cli]
path = "packages/cli"
publish = ["pub.dev"]
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
schema = 1

[release.cli]
publish = ["github-release"]
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
        StepKind.publishFormula: true,
        StepKind.build: false,
        StepKind.sign: false,
        StepKind.notarize: false,
        StepKind.archive: false,
        StepKind.checksums: false,
      },
      reason: 'a prerequisite dropped from this set stops blocking a release '
          'whose dependency rk could not read',
    );
  });

  Step step(StepKind kind) => Step(
        id: 'u/x/y',
        unit: 'u',
        kind: kind,
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

  test('the formula is unknown until a tap reader exists', () async {
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
        id: 'cli/homebrew/tool',
        unit: 'cli',
        kind: StepKind.publishFormula,
        summary: 'update the formula',
        needs: const [],
      ),
      (await _binaryUnit()),
    );
    expect(
      state.verdict,
      Verdict.unknown,
      reason: 'absent would report a formula that may already point at this '
          'release as work still to do',
    );
  });

  test('the expected asset set is derived, and derives everything', () async {
    final unit = await _binaryUnit();
    expect(
      Inspector.expectedAssets(unit),
      {
        'example-tool-1.0.0-linux-x64.tar.gz',
        'example-tool-1.0.0-macos-arm64.tar.gz',
        'example-tool-1.0.0-macos-arm64.notary-result.json',
        'example-tool-1.0.0-macos-arm64.notary-log.json',
        'example-tool.rb',
        'SHA256SUMS',
      },
      reason: 'emptied, every release inspects exact and nothing notices — '
          'and the reference shape is the real keybay 0.1.0 release: '
          'archives, notary evidence per macOS platform, the formula, the '
          'checksums',
    );
  });
}

Future<ResolvedUnit> _binaryUnit() async {
  final diagnostics = Diagnostics();
  final config = ReleaseConfig.parse('''
schema = 1

[release.cli]
publish = ["pub.dev", "github-release", "homebrew"]
binary_platforms = ["linux-x64", "macos-arm64"]
''', 'release.toml', diagnostics)!;
  final resolution = Resolution.resolve(
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
  return resolution.unit('cli')!;
}

/// The tag's remote half — the leg whose absence let a killed push produce a
/// release whose authorizing tag existed only on one machine.
void tagRemoteLeg() {
  GitState gitWith({List<String> tags = const []}) => GitState(
        root: '/repo',
        head: 'abc123def456',
        branch: 'main',
        isClean: true,
        uncommitted: const [],
        headIsPushed: true,
        tags: tags,
        signingConfigured: false,
        originUrl: 'example/keybay',
      );

  Future<Inspection> inspectTag({
    required List<String> localTags,
    required ToolResult remote,
  }) async {
    final diagnostics = Diagnostics();
    final config = ReleaseConfig.parse('''
schema = 1

[release.core]
path = "packages/keybay"
publish = ["pub.dev"]
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
      git: gitWith(tags: localTags),
      tools: RecordingTools(
        results: {'git ls-remote origin refs/tags/v0.2.0': remote},
      ),
      repository: 'example/keybay',
    ).inspect(step, unit);
  }

  test('local and on origin is done', () async {
    final state = await inspectTag(
      localTags: ['v0.2.0'],
      remote:
          ToolResult(exitCode: 0, stdout: 'dead refs/tags/v0.2.0', stderr: ''),
    );
    expect(state.verdict, Verdict.exact);
    expect(state.detail, contains('pushed'));
  });

  test('local but not on origin is work remaining, not done', () async {
    final state = await inspectTag(
      localTags: ['v0.2.0'],
      remote: ToolResult(exitCode: 0, stdout: '', stderr: ''),
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
}
