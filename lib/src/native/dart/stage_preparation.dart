import 'dart:io';
import 'dart:convert';

import '../../engine/canonical_json.dart';
import '../../engine/file_mode.dart';
import '../../engine/release_stage.dart';
import '../../engine/resolve.dart';
import '../../engine/source_tree.dart';
import '../../engine/stage.dart';
import '../../engine/stage_dependencies.dart';
import '../../engine/stage_receipt.dart';
import '../../engine/tools.dart';
import '../../transforms/digest.dart';
import '../package_archive.dart';
import 'archive_replay.dart';
import 'stage_context.dart';
import 'replay_sources.dart';
import 'stage_inputs.dart';

/// A private source mirror resolved exclusively from receipt-bound native
/// archives. Both Pub packaging and binary compilation use this environment.
/// The caller must already have authorized and bound the stage's contexts.
final class DartStagePreparation {
  DartStagePreparation._(this.directory, this.replay, this.context);

  final Directory directory;
  final DartArchiveReplay replay;
  final DartStageContext context;

  static DartStageContext? contextFor(
    ReleaseStage stage,
    ResolvedProject project,
    DartStageOperation operation,
    String producer,
  ) {
    final contexts = stage.dependencies.contexts
        .where((context) => context.ecosystem == 'dart')
        .map(DartStageContext.fromEnvelope)
        .toList();
    final selected = contexts
        .where(
          (context) =>
              context.envelope.owner == project.name &&
              context.operation == operation,
        )
        .toList();
    if (selected.isEmpty) return null;
    if (selected.length != 1 ||
        !selected.single.envelope.consumers.contains(producer) ||
        !stage.producerNames.contains(producer) ||
        selected.single.root.version != project.version.canonical) {
      throw StateError('Dart preparation does not match this project producer');
    }
    final context = selected.single;
    final expected = switch (operation) {
      DartStageOperation.pubArchive => {'pub-archive:${project.name}'},
      DartStageOperation.binary => {
        for (final platform in project.binaryPlatforms)
          'build:${project.name}:$platform',
      },
    };
    if (context.envelope.consumers.length != expected.length ||
        !expected.containsAll(context.envelope.consumers)) {
      throw StateError(
        'Dart preparation consumers differ from the project contract',
      );
    }
    return context;
  }

  static Future<DartStagePreparation> open({
    required ReleaseStage stage,
    required ResolvedProject project,
    required DartStageContext context,
    required String producer,
    required Tools tools,
  }) async {
    final authorized = contextFor(stage, project, context.operation, producer);
    if (authorized == null ||
        CanonicalJson.encode(authorized.envelope.toJson()) !=
            CanonicalJson.encode(context.envelope.toJson())) {
      throw StateError('Dart context is not bound to this stage');
    }
    final snapshot = stage.requireProducerProgress().steps.singleWhere(
      (step) => step.name == 'source-snapshot',
    );
    final recordedHelpers = context.developmentSources;
    final mirror = Directory.systemTemp.createTempSync('rk-dart-source-');
    try {
      _requireOutsideGit(mirror);
      final modes = <String, String>{};
      for (final artifact in snapshot.outputs) {
        final parts = StagePath.segments(artifact.path);
        if (artifact.type != 'source' ||
            parts.length < 2 ||
            parts.first != 'source') {
          throw StateError('Dart preparation received a non-source artifact');
        }
        final bytes = File(
          stage.directory.resolve(artifact.path),
        ).readAsBytesSync();
        if (bytes.length != artifact.size ||
            Sha256.hex(bytes) != artifact.sha256) {
          throw StateError('Dart source snapshot changed during preparation');
        }
        final file = File([mirror.path, ...parts].join(Platform.pathSeparator));
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(bytes);
        modes[file.path] = artifact.mode;
        if (recordedHelpers.isNotEmpty) {
          final helper = File(
            [
              mirror.path,
              'helpers',
              ...parts.skip(1),
            ].join(Platform.pathSeparator),
          );
          helper.parent.createSync(recursive: true);
          helper.writeAsBytesSync(bytes);
          modes[helper.path] = artifact.mode;
        }
      }
      setFileModes(modes);
      final root = Directory(project.directoryIn('${mirror.path}/source'));
      final inputs = DartStageInputs.read(
        source: SnapshotSourceTree('${mirror.path}/source'),
        project: project,
        operation: context.operation,
      );
      inputs.requireMatches(context.root, context.lock);
      final originalRootSha256 = Sha256.hex(
        File('${root.path}/pubspec.yaml').readAsBytesSync(),
      );
      DartReplaySources? helperSnapshot;
      if (recordedHelpers.isNotEmpty) {
        final helperRoot = Directory('${mirror.path}/helpers');
        for (final helper in recordedHelpers) {
          final parts = StagePath.segments(helper.manifestPath);
          final directory = [
            helperRoot.path,
            ...parts.take(parts.length - 1),
          ].join(Platform.pathSeparator);
          File('$directory/pubspec_overrides.yaml').writeAsStringSync(
            jsonEncode({'resolution': null, 'workspace': <String>[]}),
          );
        }
        helperSnapshot = DartReplaySources.capture(
          root: helperRoot,
          bindings: recordedHelpers,
        );
      }
      await inputs.authorizeDevelopmentSources(
        recordedHelpers,
        tools: tools,
        compiler: stage.compiler!.executable,
        defaultRegistry: context.defaultRegistry,
      );
      helperSnapshot?.verify();
      void requireOriginalInputs() {
        if (Sha256.hex(File('${root.path}/pubspec.yaml').readAsBytesSync()) !=
            originalRootSha256) {
          throw StateError('Dart source root changed during preparation');
        }
        if (inputs.lockPath case final path?) {
          final file = File('${mirror.path}/source/$path');
          final type = FileSystemEntity.typeSync(file.path, followLinks: false);
          final expected = inputs.lock?.binding.sha256;
          if (expected == null
              ? type != FileSystemEntityType.notFound
              : type != FileSystemEntityType.file ||
                    Sha256.hex(file.readAsBytesSync()) != expected) {
            throw StateError(
              'Dart effective source lock changed during preparation',
            );
          }
        }
      }

      requireOriginalInputs();
      final manifest = inputs.root;
      // Only the recorded development-source mappings may introduce overrides
      // later, after original constraints have passed native verification.
      if (manifest.fields.containsKey('dependency_overrides')) {
        throw StateError(
          'Dart archive preparation does not authorize dependency overrides',
        );
      }
      final overrides = File('${root.path}/pubspec_overrides.yaml');
      if (overrides.existsSync()) {
        // Do not silently discard an override file whose resolution was never
        // authorized. Workspace detachment is written only in this owned copy.
        throw StateError(
          'Dart archive preparation found an unbound pubspec_overrides.yaml',
        );
      }
      for (final entry in Directory(
        '${mirror.path}/source',
      ).listSync(recursive: true, followLinks: false).toList()) {
        final name = entry.path.split(Platform.pathSeparator).last;
        if ((entry is Directory && name == '.dart_tool') ||
            (context.operation == DartStageOperation.pubArchive &&
                entry is File &&
                name == 'pubspec.lock')) {
          if (entry.existsSync()) entry.deleteSync(recursive: true);
        }
      }
      if (manifest.fields.containsKey('resolution') ||
          manifest.fields.containsKey('workspace')) {
        overrides.writeAsStringSync('resolution: null\nworkspace: []\n');
      }
      if (context.operation == DartStageOperation.binary) {
        final lock = File('${root.path}/pubspec.lock');
        if (inputs.lock case final effective?) {
          lock.writeAsBytesSync(effective.bytes);
        } else if (lock.existsSync()) {
          // A detached member must not inherit a stray member lock when the
          // effective workspace root did not commit one.
          lock.deleteSync();
        }
      }
      final archives = <DartReplayArchive>[];
      for (final binding in context.envelope.bindings) {
        final artifact = _input(
          stage,
          context.envelope.context,
          binding.slot,
          producer,
        );
        final selected = context.discovery.packages[binding.slot]!;
        if (selected.archiveSha256 != null &&
            selected.archiveSha256 != artifact.sha256) {
          throw StateError(
            'external archive differs from frozen native integrity',
          );
        }
        archives.add(
          DartReplayArchive(
            registry: selected.registry,
            archive: await NativePackageArchive.read(
              File(stage.directory.resolve(artifact.path)),
              expectedSha256: artifact.sha256,
            ),
            discoveredManifest: selected.manifest,
          ),
        );
      }
      requireOriginalInputs();
      helperSnapshot?.verify();
      final replay = await DartArchiveReplay.prepare(
        root: root,
        tools: tools,
        compiler: stage.compiler!.executable,
        defaultRegistry: context.defaultRegistry,
        discovered: context.discovery.graph,
        archives: archives,
        developmentSources: helperSnapshot,
        discovery: context.discovery,
        discoveryLock: inputs.lock,
      );
      return DartStagePreparation._(mirror, replay, context);
    } on Object {
      mirror.deleteSync(recursive: true);
      rethrow;
    }
  }

  static StageArtifact _input(
    ReleaseStage stage,
    String context,
    String slot,
    String consumer,
  ) {
    final paths = <({String producer, String path, String type})>[
      for (final input in stage.dependencies.local)
        if (input.use.context == context && input.use.slot == slot)
          (
            producer: input.use.provider.producer,
            path: input.path,
            type: input.type,
          ),
      for (final input in stage.dependencies.imports)
        if (input.use.context == context && input.use.slot == slot)
          (
            producer: StageDependencies.importProducer,
            path: input.archive.path,
            type: input.archive.type,
          ),
      for (final input in stage.dependencies.external)
        if (input.context == context && input.binding.slot == slot)
          (
            producer: StageDependencies.importProducer,
            path: input.archive.path,
            type: input.archive.type,
          ),
    ];
    if (paths.length != 1 ||
        !stage.producerContract(consumer).inputs.contains(paths.single.path)) {
      throw StateError('Dart archive is not a declared producer input');
    }
    final input = paths.single;
    return stage.requireProducerArtifact(
      producer: input.producer,
      path: input.path,
      type: input.type,
    );
  }

  void close() {
    try {
      replay.close();
    } finally {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    }
  }
}

void _requireOutsideGit(Directory directory) {
  var current = Directory(directory.resolveSymbolicLinksSync());
  while (true) {
    if (FileSystemEntity.typeSync('${current.path}/.git', followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw StateError(
        'native preparation temporary directory is inside a Git worktree',
      );
    }
    if (current.parent.path == current.path) return;
    current = current.parent;
  }
}
