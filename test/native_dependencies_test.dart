import 'dart:convert';

import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/native_dependencies.dart';
import 'package:rk/src/engine/pubspec.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/native/dart/dependencies.dart';
import 'package:test/test.dart';

const _core = NativePackage(
  ecosystem: 'dart',
  source: 'registry-a',
  name: 'core',
);
const _provider = NativeCandidate(
  package: _core,
  version: '0.2.0',
  unit: 'core',
  project: 'core',
  producer: 'package-core',
);

NativeRequirement _require(
  String consumer,
  String constraint, {
  NativePackage package = _core,
  String context = 'app',
  String slot = 'core',
  String kind = 'runtime',
  Set<DependencyPhase> phases = const {
    DependencyPhase.preparation,
    DependencyPhase.publication,
  },
}) => NativeRequirement(
  context: context,
  owner: context,
  slot: slot,
  consumer: consumer,
  package: package,
  constraint: constraint,
  kind: kind,
  location: const SourceLocation('pubspec.yaml', 4),
  phases: phases,
);

List<NativeCandidateSelection> _select(
  List<NativeRequirement> requirements, {
  List<NativeCandidate> candidates = const [_provider],
  DependencyPhase phase = DependencyPhase.preparation,
}) => selectNativeCandidates(
  requirements: requirements,
  candidates: candidates,
  semantics: const DartDependencySemantics(),
  phase: phase,
);

Resolution _resolve(String dependencies) {
  final diagnostics = Diagnostics();
  final config = ReleaseConfig.parse(
    '''
schema = 2
[release.core]
path = "core"
publish = ["pub.dev"]
[release.consumer]
path = "consumer"
publish = ["pub.dev"]
''',
    'release.toml',
    diagnostics,
  )!;
  final result = Resolution.resolve(
    config,
    MemorySourceTree({
      'core/pubspec.yaml': 'name: core\nversion: 0.2.0\n',
      'consumer/pubspec.yaml': 'name: consumer\nversion: 0.1.0\n$dependencies',
    }),
    diagnostics,
  );
  expect(diagnostics.found, isEmpty);
  return result!;
}

void main() {
  test(
    'an incompatible root cannot be masked by a permissive transitive edge',
    () {
      final selected = _select([
        _require('app', '^0.1.0'),
        _require('bridge', '>=0.1.0 <0.3.0'),
      ]);
      expect(selected.single.candidate, isNull);
      expect(
        selected.single.toJson()['resolution'],
        'native_resolution_required',
      );
    },
  );

  test('transitive-only selection uses every incoming constraint', () {
    expect(_select([_require('bridge', '^0.1.0')]).single.candidate, isNull);
    expect(
      _select([_require('bridge', '>=0.1.0 <0.3.0')]).single.candidate,
      same(_provider),
    );
    final occurrence = _select([
      _require('bridge', '^0.2.0'),
    ]).single.requirements.single;
    expect(occurrence.consumer, 'bridge');
    expect(occurrence.owner, 'app');
  });

  test('unused candidates never become roots or obligations', () {
    const broken = NativeCandidate(
      package: NativePackage(
        ecosystem: 'dart',
        source: 'registry-a',
        name: 'unused',
      ),
      version: 'not-even-a-version',
      unit: 'unused',
      project: 'unused',
      producer: 'unusable',
    );
    expect(
      _select(
        [_require('app', '^0.2.0')],
        candidates: [_provider, broken],
      ).single.candidate,
      same(_provider),
    );
    expect(_select([], candidates: [broken]), isEmpty);
  });

  test(
    'named scope with no eligible provider leaves hosted resolution available',
    () {
      expect(
        _select([_require('app', '^0.2.0')], candidates: []).single.candidate,
        isNull,
      );
    },
  );

  test(
    'a different native source cannot satisfy the same-name requirement',
    () {
      const other = NativePackage(
        ecosystem: 'dart',
        source: 'registry-b',
        name: 'core',
      );
      expect(
        _select([_require('app', '^0.2.0', package: other)]).single.candidate,
        isNull,
      );
      expect(
        _select([
          _require('app', '^0.2.0'),
          _require('bridge', '^0.2.0', package: other),
        ]).single.candidate,
        isNull,
      );
    },
  );

  test('native phase projection keeps development out of publication', () {
    final requirements = [
      _require(
        'app',
        '^0.2.0',
        kind: 'development',
        phases: {DependencyPhase.preparation},
      ),
    ];
    expect(_select(requirements).single.candidate, same(_provider));
    expect(_select(requirements, phase: DependencyPhase.publication), isEmpty);
  });

  test(
    'non-Dart semantics support multiple versions and opaque constraints',
    () {
      const identity = NativePackage(
        ecosystem: 'fixture',
        source: 'catalog:ruby-like',
        name: 'same-name',
      );
      const first = NativeCandidate(
        package: identity,
        version: 'release-red',
        unit: 'red',
        project: 'one',
        producer: 'one',
      );
      const second = NativeCandidate(
        package: identity,
        version: 'release-blue',
        unit: 'blue',
        project: 'two',
        producer: 'two',
      );
      final selected = selectNativeCandidates(
        requirements: [
          _require(
            'left',
            'wants-red',
            package: identity,
            slot: 'left/install',
            kind: 'peer',
          ),
          _require(
            'right',
            'wants-blue',
            package: identity,
            slot: 'right/install',
            kind: 'optional',
          ),
        ],
        candidates: [first, second],
        semantics: _OpaqueSemantics(),
        phase: DependencyPhase.preparation,
      );
      expect(selected.map((selection) => selection.candidate!.version), [
        'release-red',
        'release-blue',
      ]);
    },
  );

  test('Pub native ranges and pre-1.0 caret rules select candidates', () {
    final semantics = const DartDependencySemantics();
    for (final (constraint, version, accepted) in [
      ('0.2.0', '0.2.0', true),
      ('^0.1.0', '0.2.0', false),
      ('^0.0.3', '0.0.9', true),
      ('^0.0.3', '0.1.0', false),
      ('>=0.1.0 <0.3.0', '0.2.0', true),
      ('>=0.2.0-beta.1 <0.2.0', '0.2.0-beta.2', true),
    ]) {
      expect(
        semantics.accepts(
          _require('app', constraint),
          NativeCandidate(
            package: _core,
            version: version,
            unit: 'core',
            project: 'core',
            producer: 'core',
          ),
        ),
        accepted,
        reason: '$constraint / $version',
      );
    }
    expect(
      () => _select([_require('app', 'this-is-not-a-version')]),
      throwsFormatException,
    );
  });

  test(
    'Dart facts preserve source syntax and never match SDK inputs as hosted',
    () {
      final resolution = _resolve('''
dependencies:
  core:
    hosted: https://another.example/registry/
    version: ^0.2.0
  flutter:
    sdk: flutter
  legacy:
    hosted:
      name: legacy
      url: https://legacy.example
    version: ^1.0.0
''');
      final consumer = resolution.unit('consumer')!.projects.single;
      expect(
        consumer.pubspec.dependencies['flutter']!.kind,
        DependencyKind.sdk,
      );
      expect(
        consumer.pubspec.dependencies['core']!.hostedUrl,
        'https://another.example/registry/',
      );
      final requirements = dartRequirements(consumer);
      expect(requirements.map((item) => item.package.name), ['core', 'legacy']);
      expect(
        requirements.first.package.source,
        dartRegistryIdentity('https://another.example/registry'),
      );
      expect(
        resolution.dependencyPlan.prerequisites(
          resolution.unit('consumer')!,
          Diagnostics(),
        ),
        isEmpty,
      );
    },
  );

  test(
    'original runtime requirement survives a dev constraint for private resolution',
    () {
      final resolution = _resolve(
        'dependencies:\n  core: ^0.1.0\ndev_dependencies:\n  core: ^0.2.0\n',
      );
      final requirements = dartRequirements(
        resolution.unit('consumer')!.projects.single,
      );
      final candidate = dartCandidate(resolution.unit('core')!.projects.single);
      List<NativeCandidateSelection> selected(DependencyPhase phase) =>
          selectNativeCandidates(
            requirements: requirements,
            candidates: [candidate],
            semantics: const DartDependencySemantics(),
            phase: phase,
          );
      expect(
        selected(DependencyPhase.preparation).single.candidate,
        same(candidate),
      );
      expect(selected(DependencyPhase.publication).single.candidate, isNull);
      expect(
        dartRequirements(
          resolution.unit('consumer')!.projects.single,
          publicPackage: false,
        ).expand((requirement) => requirement.phases),
        isNot(contains(DependencyPhase.publication)),
      );
    },
  );

  test(
    'source identities canonicalize Pub aliases without exposing credentials',
    () {
      expect(
        dartRegistryIdentity('https://pub.dartlang.org/'),
        dartRegistryIdentity('https://pub.dev'),
      );
      final identity = dartRegistryIdentity(
        'https://user:secret@private.example/token?secret=value',
      );
      expect(identity, startsWith('hosted:'));
      expect(
        jsonEncode(
          NativePackage(
            ecosystem: 'dart',
            source: identity,
            name: 'core',
          ).toJson(),
        ),
        isNot(contains('secret')),
      );
    },
  );

  test(
    'malformed requirements identify the dependency and its manifest line',
    () {
      final resolution = _resolve(
        'dependencies:\n  core: this-is-not-a-version\n',
      );
      final diagnostics = Diagnostics();
      resolution.dependencyPlan.requirements(
        resolution.unit('consumer')!,
        diagnostics,
      );
      final diagnostic = diagnostics.found.single;
      expect(diagnostic.code, 'RK-DEP-002');
      expect(diagnostic.message, contains('core this-is-not-a-version'));
      expect(diagnostic.source!.path, 'consumer/pubspec.yaml');
      expect(diagnostic.source!.line, 4);
    },
  );
}

final class _OpaqueSemantics implements NativeDependencySemantics {
  @override
  bool accepts(NativeRequirement requirement, NativeCandidate candidate) =>
      candidate.version ==
      requirement.constraint.replaceFirst('wants-', 'release-');
}
