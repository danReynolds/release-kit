import 'dart:io';

import '../../engine/assets.dart';
import '../../engine/canonical_json.dart';
import '../../engine/native_stage_authorization.dart';
import '../../engine/release_stage.dart';
import '../../engine/resolve.dart';
import '../../engine/stage_dependencies.dart';
import '../../engine/stage_receipt.dart';
import '../package_archive.dart';
import 'hosted_archive.dart';
import 'hosted_discovery.dart';
import 'package_archive.dart';
import 'stage_authorization.dart';
import 'stage_context.dart';

/// Dart's frozen native verifier and archive reader behind the generic saved
/// stage boundary. This bridge never discovers replacement dependency choices.
final class DartStageAuthority implements NativeStageAuthority {
  const DartStageAuthority(this.authorization);

  final DartStageAuthorization authorization;

  @override
  Set<String> get ecosystems => const {'dart'};

  @override
  Map<String, Object?> readIntent(ResolvedUnit unit) =>
      authorization.readIntent(unit);

  @override
  Future<AuthorizedNativeStage> authorize(
    ResolvedUnit unit,
    StageReceipt receipt,
  ) async {
    final discoveries = await authorization.authorize(unit, receipt);
    return _AuthorizedDartStage(
      authorization.resolution.unit(unit.name)!,
      receipt,
      discoveries,
    );
  }
}

final class _AuthorizedDartStage implements AuthorizedNativeStage {
  _AuthorizedDartStage(this.unit, this.receipt, this.discoveries)
    : dependencies = receipt.plan!['dependency_inputs'] == null
          ? StageDependencies()
          : StageDependencies.fromJson(receipt.plan!['dependency_inputs']);

  final ResolvedUnit unit;
  final StageReceipt receipt;
  final StageDependencies dependencies;
  final Map<String, DartDiscoveryResult> discoveries;

  @override
  Future<void> validateRetained(
    ReleaseStage stage,
    StageReceipt retained,
  ) async {
    if (retained.encode() != receipt.encode() ||
        stage.directory.identity.id != receipt.identity.id ||
        CanonicalJson.encode(stage.dependencies.toJson()) !=
            CanonicalJson.encode(dependencies.toJson())) {
      throw StateError('retained stage differs from native authorization');
    }
    final steps = {for (final step in receipt.steps) step.name: step};
    final jobs = <String, _ArchiveCheck>{};

    void record(
      String producer,
      String path,
      String type,
      DartPackageManifest manifest, {
      StageArtifact? expected,
      Iterable<String> consumers = const [],
    }) {
      final step = steps[producer];
      if (step == null) {
        if (receipt.complete ||
            consumers.any(steps.containsKey) ||
            receipt.artifacts.any((artifact) => artifact.path == path)) {
          throw StateError('retained native archive has no recorded producer');
        }
        return; // A genuinely pending producer claims no payload.
      }
      final output = step.outputs.where((a) => a.path == path).singleOrNull;
      if (output == null ||
          output.type != type ||
          (expected != null &&
              CanonicalJson.encode(output.toJson()) !=
                  CanonicalJson.encode(expected.toJson()))) {
        throw StateError(
          'retained native archive differs from its declaration',
        );
      }
      final prior = jobs[path];
      if (prior != null) {
        prior.manifest.requireSameManifest(manifest);
        if (CanonicalJson.encode(prior.artifact.toJson()) !=
            CanonicalJson.encode(output.toJson())) {
          throw StateError('native archive has conflicting retained bindings');
        }
      } else {
        jobs[path] = _ArchiveCheck(output, manifest);
      }
    }

    for (final envelope in dependencies.contexts.where(
      (context) => context.ecosystem == 'dart',
    )) {
      final context = DartStageContext.fromEnvelope(envelope);
      if (context.operation == DartStageOperation.pubArchive) {
        final project = unit.projects.singleWhere(
          (project) => project.name == envelope.owner,
        );
        record(
          'pub-archive:${project.name}',
          ReleaseAssets.pubArchivePath(project),
          'pub-archive',
          context.root,
        );
      }
      for (final binding in envelope.bindings) {
        final selected = discoveries[envelope.context]!.packages[binding.slot]!;
        if (binding.provider case final provider?) {
          if (provider.unit == unit.name) {
            final input = dependencies.local.singleWhere(
              (input) =>
                  input.use.context == envelope.context &&
                  input.use.slot == binding.slot,
            );
            record(
              provider.producer,
              input.path,
              input.type,
              selected.manifest,
              consumers: input.use.consumers,
            );
          } else {
            final input = dependencies.imports.singleWhere(
              (input) =>
                  input.use.context == envelope.context &&
                  input.use.slot == binding.slot,
            );
            record(
              StageDependencies.importProducer,
              input.archive.path,
              input.archive.type,
              selected.manifest,
              expected: input.archive,
              consumers: input.use.consumers,
            );
          }
        } else {
          final input = dependencies.external.singleWhere(
            (input) =>
                input.context == envelope.context &&
                input.binding.slot == binding.slot,
          );
          record(
            StageDependencies.importProducer,
            input.archive.path,
            input.archive.type,
            selected.manifest,
            expected: input.archive,
            consumers: input.consumers,
          );
        }
      }
    }
    for (final job in jobs.values) {
      job.requireUnchanged(stage);
    }
    for (final job in jobs.values) {
      final archive = await NativePackageArchive.read(
        File(stage.directory.resolve(job.artifact.path)),
        expectedSha256: job.artifact.sha256,
      );
      DartPackageManifest.fromArchive(
        archive,
      ).requireSameManifest(job.manifest);
      job.requireUnchanged(stage);
    }
    // A later asynchronous read must not leave an earlier archive changed.
    for (final job in jobs.values) {
      job.requireUnchanged(stage);
    }
  }

  @override
  Future<ExternalStageDependency> recoverExternal(
    ExternalStageDependency input,
  ) async {
    final frozen = dependencies.external
        .where(
          (candidate) =>
              candidate.context == input.context &&
              candidate.binding.slot == input.binding.slot,
        )
        .singleOrNull;
    final selected = discoveries[input.context]?.packages[input.binding.slot];
    if (frozen == null ||
        selected == null ||
        CanonicalJson.encode(frozen.toJson()) !=
            CanonicalJson.encode(input.toJson())) {
      throw StateError('external recovery differs from native authorization');
    }
    if (receipt.complete ||
        receipt.steps.any(
          (step) =>
              step.name == StageDependencies.importProducer ||
              input.consumers.contains(step.name),
        )) {
      throw StateError(
        'recorded native archives cannot be recovered as pending',
      );
    }
    final archive = await DartHostedArchive.fetch(selected);
    final recovered = ExternalStageDependency.fromBytes(
      context: frozen.context,
      binding: frozen.binding,
      consumers: frozen.consumers,
      bytes: archive.archive.bytes,
      expectedSha256: frozen.archive.sha256,
    );
    if (CanonicalJson.encode(recovered.toJson()) !=
        CanonicalJson.encode(frozen.toJson())) {
      throw StateError('recovered native archive differs from frozen metadata');
    }
    return recovered;
  }
}

final class _ArchiveCheck {
  const _ArchiveCheck(this.artifact, this.manifest);
  final StageArtifact artifact;
  final DartPackageManifest manifest;

  void requireUnchanged(ReleaseStage stage) {
    final actual = StageArtifact.capture(
      stage: stage.directory,
      path: artifact.path,
      type: artifact.type,
    );
    if (CanonicalJson.encode(actual.toJson()) !=
        CanonicalJson.encode(artifact.toJson())) {
      throw StateError('retained native archive changed: ${artifact.path}');
    }
  }
}
