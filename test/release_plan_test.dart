import 'dart:convert';

import 'package:rk/src/commands/plan.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/unit_release.dart';
import 'package:rk/src/output/output.dart';
import 'package:rk/src/output/release_plan.dart';
import 'package:test/test.dart';
import 'support/memory_source_tree.dart';

const _config = '''
schema = 2

[release.core]
tag = "core-v{version}"
path = "packages/core"
publish = ["git-tag", "pub.dev"]

[release.cli]
tag = "cli-v{version}"
path = "packages/cli"
publish = ["git-tag", "pub.dev", "github-release", "homebrew"]
binary_platforms = ["linux-x64", "macos-arm64"]
''';

final _tree = MemorySourceTree({
  'packages/core/pubspec.yaml': '''
name: example_core
version: 1.2.0
''',
  'packages/cli/pubspec.yaml': '''
name: example_cli
version: 1.2.0
dependencies:
  example_core: ^1.2.0
executables:
  example: example_cli
''',
}, description: '/source/example');

Resolution _resolve(
  String config,
  MemorySourceTree tree, {
  Diagnostics? diagnostics,
}) {
  final found = diagnostics ?? Diagnostics();
  final parsed = ReleaseConfig.parse(config, 'release.toml', found)!;
  final resolution = Resolution.resolve(parsed, tree, found);
  expect(resolution, isNotNull, reason: found.found.join('\n'));
  return resolution!;
}

/// A crate whose own build writes the release assets.
const _assetConfig = '''
schema = 2

[release.parser]
tag = "parser-v{version}"
path = "native/parser"
publish = ["git-tag", "github-release"]
build = ["tool/build.sh", "{out}"]
assets = ["parser-linux-x64.so", "parser-macos-arm64.dylib"]
''';

final _assetTree = MemorySourceTree({
  'native/parser/Cargo.toml': '[package]\nname = "parser"\nversion = "0.3.0"\n',
}, description: '/source/example');

/// A Dart package whose own build writes the release assets, and which is
/// published to pub.dev too.
const _assetsPubConfig = '''
schema = 2

[release.native]
tag = "native-v{version}"
publish = ["git-tag", "pub.dev", "github-release"]
build = ["tool/build.sh", "{out}"]
assets = ["libnative-macos-arm64.dylib", "libnative-linux-x64.so"]
''';

final _assetsPubTree = MemorySourceTree({
  'pubspec.yaml': 'name: native_assets\nversion: 1.2.0\n',
}, description: '/source/native');

/// What `rk plan --json` reported for that unit before the release model,
/// as rk 0.1.14 at 9fc714f printed it. No golden repository has a unit like
/// it, so this pins its rows, their order and their edges.
const _assetsPubPlan = {
  'units': [
    {
      'name': 'native',
      'version': '1.2.0',
      'tag': 'native-v1.2.0',
      'requires_units': [],
      'nodes': [
        {
          'id': 'native/stage/source',
          'kind': 'sourceSnapshot',
          'phase': 'stage',
          'summary': 'source snapshot',
          'needs': [],
        },
        {
          'id': 'native/stage/pub-archive:native_assets',
          'kind': 'targetStage',
          'phase': 'stage',
          'summary': 'package archive',
          'needs': ['native/stage/source'],
          'producer': 'pub-archive:native_assets',
          'project': 'native_assets',
          'target': 'pubDev',
          'coordinate': 'native_assets',
          'lane': 'pubDev',
        },
        {
          'id': 'native/stage/release-notes',
          'kind': 'targetStage',
          'phase': 'stage',
          'summary': 'release notes',
          'needs': ['native/stage/source'],
          'producer': 'release-notes',
          'target': 'githubRelease',
          'coordinate': 'example/native/releases/tag/native-v1.2.0',
          'lane': 'githubRelease',
        },
        {
          'id': 'native/build/native_assets',
          'kind': 'buildAssets',
          'phase': 'stage',
          'summary': 'build the release assets',
          'needs': ['native/stage/source'],
          'producer': 'assets:native_assets',
          'project': 'native_assets',
        },
        {
          'id': 'native/stage/complete',
          'kind': 'completeStage',
          'phase': 'stage',
          'summary': 'complete and validate stage',
          'needs': [
            'native/stage/source',
            'native/stage/pub-archive:native_assets',
            'native/stage/release-notes',
            'native/build/native_assets',
          ],
          'producer': 'complete-stage',
        },
        {
          'id': 'native/tag/native-v1.2.0',
          'kind': 'tag',
          'phase': 'publish',
          'summary': 'tag native-v1.2.0',
          'needs': ['native/stage/complete'],
          'target': 'gitTag',
          'coordinate': 'native-v1.2.0',
          'lane': 'gitTag',
        },
        {
          'id': 'native/pub.dev/native_assets@1.2.0',
          'kind': 'publishRegistry',
          'phase': 'publish',
          'summary': 'publish native_assets 1.2.0 to pub.dev',
          'needs': ['native/tag/native-v1.2.0'],
          'project': 'native_assets',
          'target': 'pubDev',
          'coordinate': 'native_assets@1.2.0',
          'lane': 'pubDev',
        },
        {
          'id': 'native/github-release/native-v1.2.0',
          'kind': 'publishRelease',
          'phase': 'publish',
          'summary': 'publish 3 assets to the native-v1.2.0 release',
          'needs': ['native/tag/native-v1.2.0'],
          'target': 'githubRelease',
          'coordinate': 'example/native/releases/tag/native-v1.2.0',
          'lane': 'githubRelease',
        },
      ],
    },
  ],
};

/// Every unit's release, as `rk plan` derives them.
List<UnitRelease> _plan({
  String config = _config,
  MemorySourceTree? tree,
  String? repository = 'example/repository',
}) {
  final diagnostics = Diagnostics();
  final plan = UnitRelease.all(
    _resolve(config, tree ?? _tree),
    repository: repository,
    problems: diagnostics,
  );
  expect(plan, isNotNull, reason: diagnostics.found.join('\n'));
  return plan!;
}

List<UnitRelease> _select(List<UnitRelease> plan, String unit) => [
  for (final release in plan)
    if (release.unit.name == unit) release,
];

/// The units [release] needs first, as `rk plan --json` reports them.
List<Object?> _requiresUnits(UnitRelease release) =>
    ((planJson([release])['units']! as List).single
            as Map<String, Object?>)['requires_units']!
        as List<Object?>;

Iterable<PlanNode> _phase(UnitRelease release, StepPhase phase) =>
    release.planNodes.where((node) => node.phase == phase);

String _render(
  List<UnitRelease> plan, {
  required bool terminal,
  required bool color,
  int? width,
}) {
  final buffer = StringBuffer();
  final output = Output(
    sink: buffer.write,
    isTerminal: terminal,
    useColor: color,
    terminalWidth: width,
  );
  renderPlan(
    output,
    plan,
    repository: 'example',
    source: sourceIdentity('main', '1234567', 0),
  );
  return buffer.toString();
}

String _withoutAnsi(String value) =>
    value.replaceAll(RegExp(r'\x1b\[[0-9;]*m'), '');

void main() {
  group('canonical release plan', () {
    test('orders units and exposes the cross-unit publication requirement', () {
      final plan = _plan();

      expect(plan.map((release) => release.unit.name), ['core', 'cli']);
      expect(_requiresUnits(plan.first), isEmpty);
      expect(_requiresUnits(plan.last), ['core']);

      final requirement = _phase(plan.last, StepPhase.inspect).single;
      expect(requirement.id, 'cli/requires/pub.dev/example_core/1.2.0');
      expect(requirement.coordinate, 'pub.dev/example_core/1.2.0');
      expect(requirement.requiresUnit, 'core');
      expect(
        requirement.project,
        isNull,
        reason:
            'the requirement node represents a coordinate, not one '
            'possibly-arbitrary dependent',
      );
      expect(requirement.needs, isEmpty);
    });

    test('one external coordinate can gate several dependent projects', () {
      const config = '''
schema = 2

[release.core]
path = "packages/core"
publish = ["pub.dev"]

[release.consumers]

[[release.consumers.project]]
path = "packages/one"
publish = ["pub.dev"]

[[release.consumers.project]]
path = "packages/two"
publish = ["pub.dev"]
''';
      final tree = MemorySourceTree({
        'packages/core/pubspec.yaml': 'name: shared_core\nversion: 1.2.0\n',
        'packages/one/pubspec.yaml': '''
name: consumer_one
version: 1.2.0
dependencies:
  shared_core: ^1.2.0
''',
        'packages/two/pubspec.yaml': '''
name: consumer_two
version: 1.2.0
dependencies:
  shared_core: ^1.2.0
''',
      });
      final plan = _plan(config: config, tree: tree, repository: null);

      final consumers = _select(plan, 'consumers').single;
      final requirement = _phase(consumers, StepPhase.inspect).single;
      expect(requirement.coordinate, 'pub.dev/shared_core/1.2.0');
      expect(requirement.project, isNull);
      expect(requirement.requiresUnit, 'core');
      final publications = _phase(consumers, StepPhase.publish).toList();
      expect(publications, hasLength(2));
      expect(
        publications.every((node) => node.needs.contains(requirement.id)),
        isTrue,
      );
      final rendered = _render(
        _select(plan, 'consumers'),
        terminal: true,
        color: false,
        width: 180,
      );
      expect(
        RegExp('serialized in pub\\.dev lane').allMatches(rendered),
        hasLength(4),
        reason:
            'two package archives and two public writes share one target '
            'lane; sibling branches must not imply guaranteed concurrency',
      );
    });

    test('a unit with its own build and a pub.dev package keeps its rows, '
        'their order and their edges', () {
      expect(
        planJson(
          _plan(
            config: _assetsPubConfig,
            tree: _assetsPubTree,
            repository: 'example/native',
          ),
        ),
        _assetsPubPlan,
      );
    });

    test('preserves every direct public dependency from the release', () {
      for (final release in _plan()) {
        final expected = {
          for (final target in release.targets)
            target.id: [for (final need in target.needs) need.id],
        };
        final actual = {
          for (final node in _phase(release, StepPhase.publish))
            node.id: node.needs,
        };
        expect(actual, expected);
      }
    });

    test('emits unique, self-contained nodes in dependency order', () {
      for (final release in _plan()) {
        final unit = release.unit;
        final seen = <String>{};
        for (final node in release.planNodes) {
          expect(seen.add(node.id), isTrue, reason: '${unit.name}: ${node.id}');
          expect(
            seen,
            containsAll(node.needs),
            reason: '${unit.name}: ${node.id} must follow every direct need',
          );
        }
      }
    });

    test('JSON describes topology without inventing observations', () {
      final json = planJson(_plan());
      final encoded = jsonEncode(json);
      final units = (json['units']! as List).cast<Map<String, Object?>>();
      final cli = units.singleWhere((unit) => unit['name'] == 'cli');
      final nodes = (cli['nodes']! as List).cast<Map<String, Object?>>();
      final complete = nodes.singleWhere(
        (node) => node['kind'] == 'completeStage',
      );
      final publicByKind = {
        for (final node in nodes.where((node) => node['phase'] == 'publish'))
          node['kind']: node,
      };

      expect(json.keys, ['units'], reason: 'every plan is source-only');
      expect(encoded, isNot(contains('"verdict"')));
      expect(encoded, isNot(contains('"action"')));
      expect(encoded, isNot(contains('"state"')));
      expect(publicByKind['tag']!['coordinate'], 'cli-v1.2.0');
      expect(
        publicByKind['publishRegistry']!['coordinate'],
        'example_cli@1.2.0',
      );
      expect(
        publicByKind['publishRelease']!['coordinate'],
        'example/repository/releases/tag/cli-v1.2.0',
      );
      expect(
        publicByKind['publishHomebrew']!['coordinate'],
        'example/homebrew-tap/Formula/example.rb',
      );
      expect(
        complete['needs'],
        containsAll(<String>[
          'cli/stage/source',
          'cli/stage/pub-archive:example_cli',
          'cli/stage/release-notes',
          'cli/stage/homebrew-formula:example_cli',
          'cli/archive/example_cli/linux-x64',
          'cli/archive/example_cli/macos-arm64',
        ]),
      );
    });

    test('JSON freezes node kinds and target-lane scheduling semantics', () {
      const kindVocabulary = [
        'prerequisite',
        'sourceSnapshot',
        'targetStage',
        'build',
        'notarize',
        'archive',
        'buildAssets',
        'completeStage',
        'tag',
        'publishRegistry',
        'publishRelease',
        'publishHomebrew',
      ];
      expect(
        StepKind.values.map((kind) => kind.name),
        kindVocabulary,
        reason:
            'kind names are what a --json caller keys on, not incidental '
            'implementation labels',
      );

      final json = planJson(_plan());
      final units = (json['units']! as List).cast<Map<String, Object?>>();
      final built = planJson(_plan(config: _assetConfig, tree: _assetTree));
      final allNodes =
          [...units, ...(built['units']! as List).cast<Map<String, Object?>>()]
              .expand(
                (unit) => (unit['nodes']! as List).cast<Map<String, Object?>>(),
              )
              .toList();
      expect(
        allNodes.map((node) => node['kind']).toSet(),
        kindVocabulary.toSet(),
        reason: 'the fixtures exercise every frozen node kind',
      );

      for (final node in allNodes) {
        final targetOwned =
            node['kind'] == 'targetStage' ||
            node['phase'] == StepPhase.publish.name;
        if (targetOwned) {
          expect(node['target'], isNotNull, reason: '${node['id']}');
          expect(
            node['lane'],
            node['target'],
            reason: '${node['id']} is serialized by its target kind',
          );
        } else {
          expect(
            node,
            isNot(contains('lane')),
            reason:
                '${node['id']} is a dependency node or local producer; '
                'its needs edges, not a target mutex, order it',
          );
        }
      }

      final cli = units.singleWhere((unit) => unit['name'] == 'cli');
      final cliNodes = (cli['nodes']! as List).cast<Map<String, Object?>>();
      for (final target in ['pubDev', 'githubRelease', 'homebrew']) {
        final stage = cliNodes.singleWhere(
          (node) => node['kind'] == 'targetStage' && node['target'] == target,
        );
        final publication = cliNodes.singleWhere(
          (node) => node['phase'] == 'publish' && node['target'] == target,
        );
        expect(stage['lane'], publication['lane'], reason: target);
      }
    });

    test('unit selection changes scope without rewriting its graph', () {
      final plan = _plan();
      final selected = _select(plan, 'cli');

      expect(selected.map((release) => release.unit.name), ['cli']);
      expect(_requiresUnits(selected.single), ['core']);
      expect(
        selected.single.planNodes.map((node) => node.toJson()),
        plan.last.planNodes.map((node) => node.toJson()),
      );
    });

    test(
      'a local-output-only unit has a complete stage and no public acts',
      () {
        const config = '''
schema = 2

[release.tool]
binary_platforms = ["linux-x64"]
''';
        final tree = MemorySourceTree({
          'pubspec.yaml': '''
name: local_tool
version: 1.0.0
publish_to: none
executables:
  local: local_tool
''',
        });
        final plan = _plan(config: config, tree: tree, repository: null);

        final unit = plan.single;
        expect(_phase(unit, StepPhase.publish), isEmpty);
        expect(_phase(unit, StepPhase.stage).map((node) => node.kind), [
          StepKind.sourceSnapshot,
          StepKind.build,
          StepKind.archive,
          StepKind.completeStage,
        ]);
        expect(
          _render(plan, terminal: true, color: false, width: 180),
          contains('PUBLISH\n      none'),
        );
      },
    );

    test('leaves an incompatible candidate to native hosted resolution', () {
      const incompatible = '''
schema = 2

[release.core]
path = "packages/core"
publish = ["pub.dev"]

[release.cli]
path = "packages/cli"
publish = ["pub.dev"]
''';
      final tree = MemorySourceTree({
        'packages/core/pubspec.yaml': 'name: core\nversion: 2.0.0\n',
        'packages/cli/pubspec.yaml': '''
name: cli
version: 1.0.0
dependencies:
  core: ^1.0.0
''',
      });
      final resolution = _resolve(incompatible, tree);
      final diagnostics = Diagnostics();

      final plan = UnitRelease.all(
        resolution,
        repository: 'example/repository',
        problems: diagnostics,
      );

      expect(plan, isNotNull);
      expect(diagnostics.found, isEmpty);
      expect(_requiresUnits(plan!.last), isEmpty);
    });
  });

  group('release plan rendering', () {
    test('wide terminals show the release flow and its parallel branches', () {
      final rendered = _render(
        _plan(),
        terminal: true,
        color: false,
        width: 180,
      );

      expect(rendered, contains('EXAMPLE RELEASE PLAN'));
      expect(
        rendered,
        contains(
          'requires  [example_core@1.2.0 on pub.dev · provided by core]',
        ),
      );
      expect(rendered, contains('STAGE'));
      expect(rendered, contains('PUBLISH'));
      expect(rendered, contains('├─▶ [package archive · example_cli]'));
      expect(rendered, contains('├─▶ linux-x64'));
      expect(rendered, contains('[build] ─▶ [archive]'));
      expect(
        rendered,
        contains('[Homebrew formula · example_cli] · needs archives'),
        reason: 'the formula is target work that waits on local archives',
      );
      expect(rendered, contains('[finalize stage]'));
      expect(rendered, contains('no destination checks · no changes'));
    });

    test('narrow terminals fall back to a dependency-complete outline', () {
      final rendered = _render(
        _select(_plan(), 'cli'),
        terminal: true,
        color: false,
        width: 52,
      );

      expect(rendered, contains('example · release plan'));
      expect(rendered, isNot(contains('EXAMPLE RELEASE PLAN')));
      expect(rendered, contains('publish'));
      expect(rendered, contains('finalize stage'));
      expect(rendered, contains('needs source snapshot'));
      expect(rendered, contains('needs tag cli-v1.2.0'));
      expect(rendered, contains('needs GitHub Release'));
      expect(
        rendered,
        contains('Homebrew formula · example_cli needs archives'),
      );
      expect(rendered, isNot(contains('cli/stage/source')));
      expect(rendered, isNot(contains('cli/tag/cli-v1.2.0')));
      expect(rendered, isNot(contains('cli/github-release/cli-v1.2.0')));
      expect(rendered, contains('no destination checks · no changes'));
    });

    test('semantic colors never change the graph text', () {
      final plan = _plan();
      final plain = _render(plan, terminal: true, color: false, width: 180);
      final colored = _render(plan, terminal: true, color: true, width: 180);

      expect(colored, contains('\x1b'));
      expect(_withoutAnsi(colored), plain);
    });

    test('a pipe gets the append-only outline with no control codes', () {
      final rendered = _render(
        _select(_plan(), 'cli'),
        terminal: false,
        color: true,
        width: 180,
      );

      expect(rendered, contains('example · release plan'));
      expect(rendered, isNot(contains('\x1b')));
      expect(rendered, isNot(contains('├─▶')));
    });
  });
}
