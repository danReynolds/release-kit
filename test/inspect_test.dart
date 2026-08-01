import 'package:rk/src/engine/checklist.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/git.dart';
import 'package:rk/src/engine/inspect.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
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
    prerequisite = checklist.steps
        .firstWhere((s) => s.kind == StepKind.prerequisite);
    publish = checklist.steps
        .firstWhere((s) => s.kind == StepKind.publishRegistry);
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

      final state =
          await inspector(FakeRegistry({})).inspect(release, unit);
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
