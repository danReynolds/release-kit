import 'dart:io';

import '../../engine/assets.dart';
import '../../engine/canonical_json.dart';
import '../../engine/diagnostic.dart';
import '../../engine/native_dependencies.dart';
import '../../engine/native_publication.dart';
import '../../engine/publish_target.dart';
import '../../engine/release_stage.dart';
import '../../engine/stage_dependencies.dart';
import '../../engine/stage_receipt.dart';
import '../../engine/tools.dart';
import '../package_archive.dart';
import 'archive_replay.dart';
import 'dependencies.dart';
import 'hosted_archive.dart';
import 'hosted_requirement.dart';
import 'package_archive.dart';
import 'public_consumer.dart';
import 'stage_context.dart';
import 'version_constraints.dart';

/// Projects only original runtime requirements satisfied by frozen selections.
/// A dev-shadowed selection cannot donate its own transitive requirements to
/// the public graph. The separate native consumer solve resolves alternatives.
List<NativeRequirement> dartPublicRequirements(
  DartStageContext context, {
  required String rootManifestPath,
}) {
  if (context.operation != DartStageOperation.pubArchive) return const [];
  final result = <NativeRequirement>[];
  final visited = <String>{};
  final pending = [context.root];

  bool sdkReachesProvider(String name, Set<String> seen) {
    if (!seen.add(name)) return false;
    if (context.discovery.packages[name]?.candidate != null) return true;
    return context.discovery.graph.packages[name]?.dependencies.any(
          (child) => sdkReachesProvider(child, seen),
        ) ??
        false;
  }

  while (pending.isNotEmpty) {
    final manifest = pending.removeLast();
    if (!visited.add(manifest.name)) continue;
    final dependencies = manifest.fields['dependencies'];
    if (dependencies == null) continue;
    if (dependencies is! Map<String, Object?>) {
      throw const FormatException('invalid original runtime requirements');
    }
    for (final edge in dependencies.entries) {
      final hosted = dartHostedRequirement(edge.value, context.defaultRegistry);
      if (hosted == null) {
        if (edge.value case final Map declaration
            when declaration.containsKey('sdk')) {
          final node = context.discovery.graph.packages[edge.key];
          if (node?.source.startsWith('sdk:') != true) {
            throw StateError('runtime SDK input differs from native selection');
          }
          if (sdkReachesProvider(edge.key, {})) {
            throw UnsupportedError(
              'SDK-mediated staged runtime provider requirements are not yet supported: '
              '${manifest.name} -> ${edge.key}; the frozen SDK graph has no original hosted constraints',
            );
          }
          continue;
        }
        throw UnsupportedError(
          'runtime path or Git requirement is not supported: ${manifest.name} -> ${edge.key}',
        );
      }
      final selected = context.discovery.packages[edge.key];
      if (selected == null ||
          selected.registry != hosted.registry ||
          !dartConstraintAllows(hosted.constraint, selected.manifest.version)) {
        continue;
      }
      if (selected.developmentSource != null) {
        throw StateError(
          'a development source cannot satisfy a public runtime requirement',
        );
      }
      pending.add(selected.manifest);
      if (selected.candidate != null) {
        result.add(
          NativeRequirement(
            context: context.envelope.context,
            owner: context.root.name,
            slot: edge.key,
            consumer: manifest.name,
            package: selected.candidate!.provider.package,
            constraint: hosted.constraint,
            kind: 'runtime',
            location: SourceLocation(
              manifest.name == context.root.name
                  ? rootManifestPath
                  : 'hosted/${manifest.name}-${manifest.version}/pubspec.yaml',
            ),
            phases: const {DependencyPhase.publication},
          ),
        );
      }
    }
  }
  return List.unmodifiable(result);
}

/// Native public checks capture completed archive inputs but never alter their
/// bindings, repackage a consumer, or turn a source helper into a public edge.
final class DartPublication implements NativePublication {
  const DartPublication({
    required this.tools,
    this.timeout = const Duration(minutes: 2),
    this.maxMetadataBytes = 16 * 1024 * 1024,
    this.maxCompressedBytes = 128 * 1024 * 1024,
  });

  final Tools tools;
  final Duration timeout;
  final int maxMetadataBytes;
  final int maxCompressedBytes;

  @override
  Set<String> get ecosystems => const {'dart'};

  @override
  Future<List<NativePublicationCheck>> prepare(ReleaseStage stage) async {
    final receipt = stage.requireReceipt();
    final saved = receipt.encode();
    final projects = stage.unit.projects
        .where((project) => project.publish.contains(PublishTarget.pubDev))
        .toList();
    final contexts = stage.dependencies.contexts
        .where((envelope) => envelope.ecosystem == 'dart')
        .map(DartStageContext.fromEnvelope)
        .where((context) => context.operation == DartStageOperation.pubArchive)
        .toList();
    if (contexts.length != projects.length ||
        contexts.map((context) => context.root.name).toSet().length !=
            projects.length ||
        !contexts
            .map((context) => context.root.name)
            .toSet()
            .containsAll(projects.map((project) => project.name))) {
      throw StateError(
        'publication requires complete frozen Dart package contexts',
      );
    }
    final checks = <_DartPublicationCheck>[];
    for (final project in projects) {
      final context = contexts.singleWhere(
        (context) => context.root.name == project.name,
      );
      final producer = 'pub-archive:${project.name}';
      if (context.envelope.consumers.length != 1 ||
          context.envelope.consumers.single != producer) {
        throw StateError('publication context has unrelated producers');
      }
      final own = _recorded(
        receipt,
        producer,
        ReleaseAssets.pubArchivePath(project),
        'pub-archive',
      );
      final archives = <StageArtifact>[own];
      final requirements = <NativePublicArchiveRequirement>[];
      final providers = <String, DartPackageManifest>{};
      final causes = <String, List<NativeRequirement>>{};
      try {
        for (final cause in dartPublicRequirements(
          context,
          rootManifestPath: project.pubspec.path,
        )) {
          (causes[cause.slot] ??= []).add(cause);
        }
      } on UnsupportedError catch (error) {
        throw RkFailure([_diagnostic(project.name, '$error')]);
      }
      for (final entry in causes.entries) {
        final selected = context.discovery.packages[entry.key]!;
        final local = stage.dependencies.local
            .where(
              (input) =>
                  input.use.context == context.envelope.context &&
                  input.use.slot == entry.key,
            )
            .singleOrNull;
        final imported = stage.dependencies.imports
            .where(
              (input) =>
                  input.use.context == context.envelope.context &&
                  input.use.slot == entry.key,
            )
            .singleOrNull;
        if ((local == null) == (imported == null)) {
          throw StateError(
            'runtime provider has no unique consumer-stage archive',
          );
        }
        final use = local?.use ?? imported!.use;
        if (CanonicalJson.encode(use.provider.toJson()) !=
                CanonicalJson.encode(selected.candidate!.provider.toJson()) ||
            use.consumers.length != 1 ||
            use.consumers.single != producer) {
          throw StateError(
            'runtime archive provider differs from native selection',
          );
        }
        final artifact = local != null
            ? _recorded(receipt, use.provider.producer, local.path, local.type)
            : _recorded(
                receipt,
                StageDependencies.importProducer,
                imported!.archive.path,
                imported.archive.type,
              );
        if (imported != null &&
            CanonicalJson.encode(artifact.toJson()) !=
                CanonicalJson.encode(imported.archive.toJson())) {
          throw StateError(
            'recorded public dependency differs from imported bytes',
          );
        }
        archives.add(artifact);
        requirements.add(
          NativePublicArchiveRequirement(
            use: use,
            archive: artifact,
            causes: entry.value,
          ),
        );
        providers[entry.key] = selected.manifest;
      }
      final compiler = stage.compiler?.executable;
      if (compiler == null) {
        throw StateError(
          'native publication requires the staged Dart compiler',
        );
      }
      final ownArchive = await _readArchive(
        stage,
        saved,
        own,
        context.root,
        maxCompressedBytes,
      );
      for (final requirement in requirements) {
        await _readArchive(
          stage,
          saved,
          requirement.archive,
          providers[requirement.use.slot]!,
          maxCompressedBytes,
        );
      }
      final check = _DartPublicationCheck(
        options: this,
        stage: stage,
        receipt: saved,
        compiler: compiler,
        context: context,
        consumer: DartReplayArchive(
          registry: dartHostedRegistry(
            project.pubspec.publishTo ?? context.defaultRegistry,
          ),
          archive: ownArchive,
          discoveredManifest: context.root,
        ),
        producer: producer,
        requirements: requirements,
        artifacts: archives,
      );
      check.requireCurrent();
      checks.add(check);
    }
    for (final check in checks) {
      check.requireCurrent();
    }
    return List.unmodifiable(checks);
  }
}

final class _DartPublicationCheck implements NativePublicationCheck {
  _DartPublicationCheck({
    required this.options,
    required this.stage,
    required this.receipt,
    required this.compiler,
    required this.context,
    required this.consumer,
    required this.producer,
    required Iterable<NativePublicArchiveRequirement> requirements,
    required Iterable<StageArtifact> artifacts,
  }) : requirements = List.unmodifiable(requirements),
       artifacts = List.unmodifiable(artifacts);

  final DartPublication options;
  final ReleaseStage stage;
  final String receipt;
  final String compiler;
  final DartStageContext context;
  final DartReplayArchive consumer;
  final List<StageArtifact> artifacts;
  @override
  final String producer;
  @override
  final List<NativePublicArchiveRequirement> requirements;

  void requireCurrent() {
    if (stage.requireReceipt().encode() != receipt) {
      throw StateError('publication stage changed during native checks');
    }
    for (final artifact in artifacts) {
      _confirm(stage, artifact);
    }
  }

  Future<void> _requirePublic(
    NativePublicArchiveRequirement requirement,
  ) async {
    final selected = context.discovery.packages[requirement.use.slot]!;
    await DartHostedArchive.fetchPublic(
      registry: selected.registry,
      manifest: selected.manifest,
      expectedSha256: requirement.archive.sha256,
      timeout: options.timeout,
      maxMetadataBytes: options.maxMetadataBytes,
      maxCompressedBytes: options.maxCompressedBytes,
    );
    requireCurrent();
  }

  @override
  Future<NativePublicationOutcome> verify() async {
    final public = <Map<String, Object?>>[];
    try {
      requireCurrent();
      for (final requirement in requirements) {
        await _requirePublic(requirement);
        public.add({
          'context': requirement.use.context,
          'slot': requirement.use.slot,
          'provider': requirement.use.provider.toJson(),
          'archive_sha256': requirement.archive.sha256,
        });
      }
      final graph = await DartPublicConsumer.resolve(
        consumer: consumer,
        tools: options.tools,
        compiler: compiler,
        defaultRegistry: context.defaultRegistry,
        timeout: options.timeout,
      );
      requireCurrent();
      // A broad public range may choose a different compatible version. If it
      // chooses this staged coordinate, it must observe the exact same bytes
      // checked above, including registry changes during the native solve.
      for (final requirement in requirements) {
        final provider = requirement.use.provider;
        final observed = graph.packages[provider.package.name];
        if (observed?.source == provider.package.source &&
            observed?.version == provider.version &&
            observed?.archiveSha256 != requirement.archive.sha256) {
          throw StateError(
            'public provider archive changed during native resolution: '
            '${provider.package.name} ${provider.version}',
          );
        }
      }
      // The frozen provider remains an independent public-byte obligation
      // even when this fresh solve legitimately chooses a newer version.
      for (final requirement in requirements) {
        await _requirePublic(requirement);
      }
      return NativePublicationReady(
        evidence: {
          'ecosystem': 'dart',
          'producer': producer,
          'consumer_archive_sha256': consumer.archive.sha256,
          'public_archives': public,
          'runtime_resolution': graph.toJson(),
        },
      );
    } on Object catch (error) {
      final detail = _safeDetail('$error');
      return NativePublicationBlocked(
        diagnostic: _diagnostic(context.root.name, detail),
        evidence: {
          'ecosystem': 'dart',
          'producer': producer,
          'verified_public_archives': public,
          'failure': detail,
        },
      );
    }
  }
}

StageArtifact _recorded(
  StageReceipt receipt,
  String producer,
  String path,
  String type,
) {
  final output = receipt.steps
      .where((step) => step.name == producer)
      .singleOrNull
      ?.outputs
      .where((artifact) => artifact.path == path && artifact.type == type)
      .singleOrNull;
  if (output == null) {
    throw StateError('publication archive has no exact recorded producer');
  }
  return output;
}

void _confirm(ReleaseStage stage, StageArtifact artifact) {
  if (CanonicalJson.encode(
        StageArtifact.confirm(artifact, stage: stage.directory).toJson(),
      ) !=
      CanonicalJson.encode(artifact.toJson())) {
    throw StateError('publication archive changed: ${artifact.path}');
  }
}

Future<NativePackageArchive> _readArchive(
  ReleaseStage stage,
  String receipt,
  StageArtifact artifact,
  DartPackageManifest manifest,
  int maxCompressedBytes,
) async {
  _confirm(stage, artifact);
  final archive = await NativePackageArchive.read(
    File(stage.directory.resolve(artifact.path)),
    expectedSha256: artifact.sha256,
    maxCompressedBytes: maxCompressedBytes,
  );
  DartPackageManifest.fromArchive(archive).requireSameManifest(manifest);
  _confirm(stage, artifact);
  if (stage.requireReceipt().encode() != receipt) {
    throw StateError(
      'publication receipt changed while reading native archives',
    );
  }
  return archive;
}

Diagnostic _diagnostic(String name, String detail) => Diagnostic(
  code: 'RK-PUB-018',
  message: 'the native publication check for $name did not pass',
  remedy:
      'The staged archive was not uploaded. Resolve the public dependency or integrity issue, then re-run.\n$detail',
  evidence: detail,
);

String _safeDetail(String value) {
  final redacted = value.replaceAllMapped(RegExp(r'https?://[^\s<>"\x27]+'), (
    match,
  ) {
    final url = Uri.tryParse(match.group(0)!);
    if (url == null) return '<invalid URL>';
    return url
        .replace(userInfo: '', query: null, fragment: null)
        .toString()
        .split('?')
        .first
        .split('#')
        .first;
  });
  return redacted.length <= 12000
      ? redacted
      : '${redacted.substring(0, 12000)}\n[truncated]';
}
