import 'dart:convert';

import '../builds/binary_artifact.dart';
import '../transforms/digest.dart';
import 'canonical_json.dart';
import 'producers.dart';
import 'stage_archive.dart';
import 'stage_inspection.dart';
import 'stage_receipt.dart';

final _sha256 = RegExp(r'^[0-9a-f]{64}$');
final _cdhash = RegExp(r'^[0-9a-f]{40}$');

/// Pure consistency checks for recorded binary production. These authenticate
/// neither archive payloads nor operating-system signatures. Full inspection
/// still reads the recorded files and decodes every actual archive.
abstract final class StageBinaryEvidence {
  static List<StageIssue> validate(StageReceipt receipt) {
    final issues = <StageIssue>[];
    final steps = {for (final step in receipt.steps) step.name: step};
    for (final step in receipt.steps) {
      if (isMacosBuildReceipt(step.name)) {
        _inspectSignature(step, issues);
      }
      if (!step.name.startsWith('archive:')) continue;
      for (final output in step.outputs.where((a) => a.type == 'archive')) {
        try {
          final build = steps['build${step.name.substring('archive'.length)}'];
          final artifact = build?.evidence['artifact'];
          requireArchiveEvidence(
            step,
            artifact: artifact == null
                ? null
                : BinaryArtifact.fromJson(artifact),
            buildOutputs: build?.outputs,
          );
        } on Object catch (error) {
          issues.add(
            StageIssue(
              StageIssueKind.invalidArchive,
              'archive evidence is invalid: $error',
              path: output.path,
            ),
          );
        }
      }
    }
    return issues;
  }

  /// Shared by portable receipt checks and full inspection, which supplies the
  /// artifact decoded from actual bytes. With no artifact, inventory can select
  /// only a known single-executable or Dart bundle layout. When the corresponding
  /// build is available, its recorded output metadata also binds the inventory.
  static void requireArchiveEvidence(
    StageStep producer, {
    BinaryArtifact? artifact,
    Iterable<StageArtifact>? buildOutputs,
  }) {
    final parts = producer.name.split(':');
    if (!producer.name.startsWith('archive:')) {
      throw const FormatException(
        'archive has no archive producer in the receipt',
      );
    }
    final inventory = StageArchiveInventory.parseEvidence(
      producer.evidence['inventory'],
    );
    final byName = {for (final entry in inventory) entry.name: entry};
    final byBuildPath = buildOutputs == null
        ? null
        : {for (final output in buildOutputs) output.path: output};
    final layout = artifact ?? _artifactFromInventory(inventory);
    for (final file in layout.files) {
      final entry = byName[file.path];
      if (entry == null || entry.mode != file.mode) {
        throw FormatException(
          'archive is missing ${file.path} with mode ${file.mode}',
        );
      }
      // Generic inspection also accepts older, unbound receipts whose archive
      // name supplies no project/platform coordinates. Current producer
      // contracts enforce canonical names before authorizing those receipts.
      if (parts.length == 3) {
        final path = 'producers/${parts[1]}/${parts[2]}/${file.path}';
        final input = producer.inputs
            .where((input) => input.name == path)
            .singleOrNull;
        if (input == null || input.sha256 != entry.sha256) {
          throw FormatException(
            'archived ${file.path} differs from its producer input',
          );
        }
        if (byBuildPath != null) {
          final output = byBuildPath[path];
          if (output == null ||
              output.sha256 != entry.sha256 ||
              output.size != entry.size ||
              output.mode != entry.mode ||
              output.type != file.type) {
            throw FormatException(
              'archived ${file.path} differs from its recorded build output',
            );
          }
        }
      }
    }
    final allowed = {
      for (final file in layout.files) file.path,
      'LICENSE',
      'README.md',
    };
    for (final entry in inventory) {
      if (!allowed.contains(entry.name) ||
          ((entry.name == 'LICENSE' || entry.name == 'README.md') &&
              entry.mode != '0644')) {
        throw FormatException('unexpected artifact file: ${entry.name}');
      }
    }
    if (layout.isBundle) {
      final bytes = utf8.encode(layout.manifest);
      final manifest = byName[BinaryArtifact.manifestName]!;
      if (manifest.size != bytes.length ||
          manifest.sha256 != Sha256.hex(bytes)) {
        throw const FormatException(
          'archived bundle manifest differs from its layout',
        );
      }
    }
    if (isMacosArchiveReceipt(producer.name)) {
      final signature = producer.evidence['signature'];
      if (signature is! Map ||
          signature['status'] != 'valid' ||
          signature['scope'] != 'archive-extracted' ||
          (layout.isBundle &&
              (signature['smoke'] != 'passed' ||
                  CanonicalJson.encode(signature['files']) !=
                      CanonicalJson.encode([
                        for (final file in layout.signedFiles) file.path,
                      ])))) {
        throw const FormatException(
          'macOS archive has no final signature verification evidence',
        );
      }
    }
  }

  static BinaryArtifact _artifactFromInventory(
    List<StageArchiveEntry> inventory,
  ) {
    final bundle = inventory.any(
      (entry) => entry.name == BinaryArtifact.manifestName,
    );
    final executables = inventory
        .where(
          (entry) => entry.executable && (!bundle || !entry.name.contains('/')),
        )
        .toList();
    if (executables.length != 1) {
      throw const FormatException(
        'archive inventory has no unique artifact layout',
      );
    }
    return bundle
        ? BinaryArtifact.dartBundle(executables.single.name)
        : BinaryArtifact.single(executables.single.name);
  }

  static void _inspectSignature(StageStep producer, List<StageIssue> issues) {
    final signature = producer.evidence['signature'];
    BinaryArtifact? artifact;
    String? root;
    try {
      if (producer.evidence.containsKey('artifact')) {
        artifact = BinaryArtifact.fromJson(producer.evidence['artifact']);
        final parts = producer.name.split(':');
        root = 'producers/${parts[1]}/${parts[2]}';
        final expected = {
          for (final file in artifact.files) '$root/${file.path}': file,
        };
        if (producer.outputs.length != expected.length ||
            producer.outputs.any(
              (output) =>
                  expected[output.path]?.mode != output.mode ||
                  expected[output.path]?.type != output.type,
            )) {
          throw const FormatException(
            'signed build has an incomplete artifact inventory',
          );
        }
        if (artifact.isBundle) {
          final bytes = utf8.encode(artifact.manifest);
          final manifest = producer.outputs.singleWhere(
            (output) => output.path == '$root/${BinaryArtifact.manifestName}',
          );
          if (manifest.size != bytes.length ||
              manifest.sha256 != Sha256.hex(bytes)) {
            throw const FormatException(
              'signed build manifest differs from its receipt',
            );
          }
        }
      }
    } on Object catch (error) {
      issues.add(
        StageIssue(
          StageIssueKind.invalidStructure,
          '$error',
          path: 'stage.json',
        ),
      );
      return;
    }
    final binary = artifact != null
        ? producer.outputs
              .where(
                (output) => output.path == '$root/${artifact!.identityFile}',
              )
              .firstOrNull
        : producer.outputs.length == 1 &&
              producer.outputs.single.type == 'executable'
        ? producer.outputs.single
        : null;
    String? problem;
    if (binary == null) {
      problem = 'signed build does not produce exactly one executable';
    } else if (signature is! Map) {
      problem = 'signed build has no signature evidence';
    } else {
      final signedSmoke = producer.evidence['signed_smoke'];
      final certificate = signature['certificate'];
      final fingerprint = signature['certificate_sha256'];
      final firstIdentity = signature['first_identity'];
      final hasPublishedRequirement = signature.containsKey(
        'published_requirement',
      );
      final publishedRequirement = signature['published_requirement'];
      final designatedRequirement = signature['designated_requirement'];
      final codeId = signature['code_id'];
      final unsigned = signature['unsigned_sha256'];
      final signed = signature['signed_sha256'];
      final verifiedAfterSmoke = signature['verified_after_smoke'];
      if (signedSmoke is! Map ||
          signedSmoke['status'] != 'pass' ||
          signedSmoke['command'] != '--version') {
        problem = 'signed build has no successful signed smoke-test evidence';
      } else if (certificate is! String || certificate.trim().isEmpty) {
        problem = 'signature evidence has no certificate identity';
      } else if (fingerprint is! String || !_sha256.hasMatch(fingerprint)) {
        problem = 'signature evidence has no certificate SHA-256 fingerprint';
      } else if (firstIdentity is! bool) {
        problem = 'signature evidence does not say whether identity is first';
      } else if (!hasPublishedRequirement ||
          (firstIdentity && publishedRequirement != null) ||
          (!firstIdentity &&
              (publishedRequirement is! String ||
                  publishedRequirement.trim().isEmpty))) {
        problem = 'signature evidence has an inconsistent published baseline';
      } else if (codeId is! String || codeId.trim().isEmpty) {
        problem = 'signature evidence has no code identifier';
      } else if (designatedRequirement is! String ||
          designatedRequirement.trim().isEmpty) {
        problem = 'signature evidence has no designated requirement';
      } else if (unsigned is! String || !_sha256.hasMatch(unsigned)) {
        problem = 'signature evidence has no unsigned input digest';
      } else if (signed != binary.sha256) {
        problem = 'signature evidence is not bound to the signed bytes';
      } else if (verifiedAfterSmoke != true) {
        problem = 'signature was not verified after the signed smoke test';
      }
    }
    if (problem == null && artifact != null) {
      final signatures = producer.evidence['signatures'];
      if (signatures is! Map ||
          signatures.length != artifact.signedFiles.length ||
          CanonicalJson.encode(signatures[artifact.identityFile]) !=
              CanonicalJson.encode(signature)) {
        problem = 'signed build has no complete per-file signature evidence';
      } else {
        for (final file in artifact.signedFiles) {
          final record = signatures[file.path];
          final output = producer.outputs.singleWhere(
            (output) => output.path == '$root/${file.path}',
          );
          if (record is! Map ||
              signature is! Map ||
              record['code_id'] !=
                  '${signature['code_id']}${file.codeSuffix}' ||
              record['certificate'] != signature['certificate'] ||
              record['certificate_sha256'] != signature['certificate_sha256'] ||
              record['designated_requirement'] is! String ||
              (record['designated_requirement'] as String).trim().isEmpty ||
              record['unsigned_sha256'] is! String ||
              !_sha256.hasMatch(record['unsigned_sha256'] as String) ||
              record['signed_sha256'] != output.sha256 ||
              record['verified_after_smoke'] != true) {
            problem =
                'signature evidence for ${file.path} is missing or not bound to its bytes and identity';
            break;
          }
        }
        if (problem == null && artifact.libraries.isNotEmpty) {
          problem = _pinProblem(artifact, signatures);
        }
      }
    }
    if (problem != null) {
      issues.add(
        StageIssue(
          StageIssueKind.invalidStructure,
          problem,
          path: 'stage.json',
        ),
      );
    }
  }

  /// Why a bundle's receipt does not show its runtime admitting exactly the
  /// modules it ships, or null when it does. Without the pin, the signed
  /// runtime would run any module signed by the same team.
  static String? _pinProblem(BinaryArtifact artifact, Map signatures) {
    final shipped = <String>{};
    for (final file in artifact.libraries) {
      final hashes = (signatures[file.path] as Map)['cdhashes'];
      if (hashes is! List ||
          hashes.isEmpty ||
          hashes.any((hash) => hash is! String || !_cdhash.hasMatch(hash))) {
        return 'signature evidence for ${file.path} records no code hash';
      }
      shipped.addAll(hashes.cast<String>());
    }
    final pinned =
        (signatures[artifact.identityFile] as Map)['pinned_library_cdhashes'];
    if (CanonicalJson.encode(pinned) !=
        CanonicalJson.encode(shipped.toList()..sort())) {
      return 'signed runtime does not pin exactly the modules it ships with';
    }
    return null;
  }
}
