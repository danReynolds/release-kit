import 'dart:convert';
import 'dart:io';

import '../transforms/digest.dart';
import 'canonical_json.dart';
import 'release_manifest.dart';
import 'release_stage.dart';
import 'stage.dart';
import 'stage_receipt.dart';
import 'stage_store.dart';

/// Advisory comparisons with the latest recorded stage of this unit/version.
/// At most 32 recent, size-bounded receipts and manifests are read. Old
/// artifacts are neither inspected nor adopted, and unavailable history
/// cannot block a release.
abstract final class StageHistory {
  static List<String> rebuildReasons(ReleaseStage current) {
    try {
      final store = StageStore(current.directory.repositoryRoot);
      final candidates = <({File receipt, DateTime modified})>[];
      for (final entry in store.inventory()) {
        if (entry.type != FileSystemEntityType.directory ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(entry.name) ||
            entry.name == current.directory.identity.id) {
          continue;
        }
        final file = File('${store.path}/${entry.name}/stage.json');
        if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
            FileSystemEntityType.file) {
          continue;
        }
        final stat = file.statSync();
        if (stat.size > 4 * 1024 * 1024) continue;
        candidates.add((receipt: file, modified: stat.modified));
      }
      candidates.sort((a, b) {
        final byTime = b.modified.compareTo(a.modified);
        return byTime != 0 ? byTime : a.receipt.path.compareTo(b.receipt.path);
      });
      for (final candidate in candidates.take(32)) {
        try {
          final receipt =
              StageReceipt.parse(candidate.receipt.readAsStringSync());
          if (!receipt.complete) continue;
          final directory = StageDirectory(
            repositoryRoot: current.directory.repositoryRoot,
            identity: receipt.identity,
          );
          if (directory.resolve('stage.json') != candidate.receipt.path ||
              directory.unsafeFixedPath() != null) {
            continue;
          }
          final evidence = receipt.steps.last.evidence;
          final encodedPlan = evidence['release_plan'];
          Map? plan;
          if (encodedPlan != null) {
            if (encodedPlan is! Map ||
                Sha256.hex(utf8.encode(CanonicalJson.encode(encodedPlan))) !=
                    receipt.identity.planSha256) {
              continue;
            }
            plan = encodedPlan;
            final unit = plan['unit'];
            if (unit is! Map ||
                unit['name'] != current.unit.name ||
                unit['version'] != current.unit.version.canonical) {
              continue;
            }
          } else {
            // Older receipts retain enough evidence for source/SDK changes.
            final manifestArtifact = receipt.steps.last.outputs
                .where((output) => output.path == 'release-manifest.json')
                .firstOrNull;
            if (manifestArtifact == null ||
                manifestArtifact.size > 1024 * 1024) {
              continue;
            }
            final file = File(directory.resolve(manifestArtifact.path));
            if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
                    FileSystemEntityType.file ||
                file.lengthSync() > 1024 * 1024) {
              continue;
            }
            final bytes = file.readAsBytesSync();
            if (Sha256.hex(bytes) != manifestArtifact.sha256) continue;
            final manifest = ReleaseManifest.parse(utf8.decode(bytes));
            if (manifest.unit != current.unit.name ||
                manifest.version != current.unit.version.canonical ||
                manifest.commit != receipt.identity.headCommit) {
              continue;
            }
          }
          return _compare(current, receipt, plan);
        } on Object {
          // Corrupt, obsolete, or concurrently removed history is optional.
          continue;
        }
      }
    } on Object {
      // The authoritative stage path is checked separately by preparation.
    }
    return const [];
  }

  static List<String> _compare(
    ReleaseStage current,
    StageReceipt previous,
    Map? previousPlan,
  ) {
    final reasons = <String>[];
    final before = previous.identity;
    final after = current.directory.identity;
    if (before.isGitBound != after.isGitBound || !before.isGitBound) {
      reasons.add('the previous source snapshot was limited to one run');
    } else if (before.headCommit != after.headCommit) {
      reasons.add('source commit changed '
          '(${before.headCommit!.substring(0, 7)} → '
          '${after.headCommit!.substring(0, 7)})');
    } else if (before.headTree != after.headTree) {
      reasons.add('source tree changed');
    }
    final plan = current.resolvedPlan;
    if (plan != null && previousPlan != null) {
      final oldTools = previousPlan['toolchain'] as Map;
      final newTools = plan['toolchain'] as Map;
      for (final (key, label) in const [
        ('dart', 'Dart SDK'),
        ('rk', 'RK executable'),
        ('launcher', 'native compiler'),
      ]) {
        if (!_same(oldTools[key], newTools[key])) reasons.add('$label changed');
      }
      if (!_same(oldTools['host_os'], newTools['host_os']) ||
          !_same(oldTools['host_abi'], newTools['host_abi'])) {
        reasons.add('build host changed');
      }
      if (!_same(previousPlan['tag_signing'], plan['tag_signing'])) {
        reasons.add('tag-signing policy changed');
      }
      final oldConfig = Map.of(previousPlan)
        ..remove('toolchain')
        ..remove('source_binding')
        ..remove('tag_signing');
      final newConfig = Map.of(plan)
        ..remove('toolchain')
        ..remove('source_binding')
        ..remove('tag_signing');
      if (!_same(oldConfig, newConfig)) {
        reasons.add('release configuration changed');
      }
    } else {
      final oldCompiler = previous.steps.last.evidence['dart_compiler'];
      if (oldCompiler is Map &&
          current.compiler != null &&
          !_same((Map.of(oldCompiler)..remove('executable')),
              (Map.of(current.compiler!.toJson())..remove('executable')))) {
        reasons.add('Dart SDK changed');
      } else if (before.planSha256 != after.planSha256) {
        reasons.add('release settings or tooling changed');
      }
    }
    return reasons;
  }

  static bool _same(Object? left, Object? right) =>
      CanonicalJson.encode(left) == CanonicalJson.encode(right);
}
