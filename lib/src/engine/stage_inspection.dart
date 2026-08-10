import 'dart:convert';
import 'dart:io';

import '../transforms/digest.dart';
import 'release_manifest.dart';
import 'stage.dart';
import 'stage_archive.dart';
import 'stage_receipt.dart';
import 'verdict.dart';

final _sha256 = RegExp(r'^[0-9a-f]{64}$');

enum StageIssueKind {
  missingReceipt,
  invalidReceipt,
  incompleteReceipt,
  wrongStage,
  unsafePath,
  missingArtifact,
  changedArtifact,
  wrongType,
  symlink,
  extraArtifact,
  unreadable,
  invalidStructure,
  invalidManifest,
  invalidChecksums,
  invalidArchive,
  invalidNotary,
}

class StageIssue {
  const StageIssue(this.kind, this.message, {this.path});

  final StageIssueKind kind;
  final String message;
  final String? path;

  @override
  String toString() => path == null ? message : '$path: $message';
}

class StageInspection {
  StageInspection({required this.receipt, required Iterable<StageIssue> issues})
      : issues = List<StageIssue>.unmodifiable(issues);

  final StageReceipt? receipt;
  final List<StageIssue> issues;

  bool get reusable => receipt?.complete == true && issues.isEmpty;

  /// Whether an interrupted receipt can be resumed without adopting any
  /// unchecked file. Every recorded byte and dependency has validated; only
  /// the deliberately incomplete barrier remains.
  bool get validProgress =>
      receipt?.complete == false &&
      issues.isNotEmpty &&
      issues.every((issue) => issue.kind == StageIssueKind.incompleteReceipt);

  /// The shared verdict used by status and release for the stage barrier.
  ///
  /// A missing or interrupted receipt is ordinary work. A receipt that once
  /// claimed completion but no longer validates is a conflict: publication
  /// must not silently replace bytes the operator may already have reviewed.
  Inspection get asInspection {
    if (reusable) {
      return Inspection.exact(
        detail: 'staged and validated',
        evidence: {'stage id': receipt!.identity.id},
      );
    }
    final details = issues.map((issue) => issue.toString()).join('; ');
    final onlyIncomplete = issues.every(
      (issue) =>
          issue.kind == StageIssueKind.missingReceipt ||
          issue.kind == StageIssueKind.incompleteReceipt,
    );
    if (receipt?.complete != true && onlyIncomplete) {
      return Inspection.absent(
        detail: details.isEmpty ? 'not staged' : details,
      );
    }
    return Inspection.conflict(
      details.isEmpty ? 'the completed stage is invalid' : details,
      evidence: {
        for (var index = 0; index < issues.length; index++)
          'stage issue ${index + 1}': issues[index].toString(),
      },
    );
  }
}

/// Hashes and inventories an existing stage without executing artifacts,
/// contacting a service, or changing the filesystem.
class StageInspector {
  const StageInspector();

  StageInspection inspect(StageDirectory stage) {
    final issues = <StageIssue>[];
    final unsafe = stage.unsafeFixedPath();
    if (unsafe != null) {
      return StageInspection(
        receipt: null,
        issues: [
          StageIssue(
            StageIssueKind.unsafePath,
            'the fixed stage path contains a symlink or non-directory',
            path: unsafe,
          ),
        ],
      );
    }

    final rootType = FileSystemEntity.typeSync(stage.path, followLinks: false);
    if (rootType == FileSystemEntityType.notFound) {
      return StageInspection(
        receipt: null,
        issues: const [
          StageIssue(
            StageIssueKind.missingReceipt,
            'no completed stage receipt exists',
            path: 'stage.json',
          ),
        ],
      );
    }
    if (rootType != FileSystemEntityType.directory) {
      return StageInspection(
        receipt: null,
        issues: [
          StageIssue(
            StageIssueKind.unsafePath,
            'the stage root is not a directory',
            path: stage.path,
          ),
        ],
      );
    }

    StageReceipt? receipt;
    try {
      receipt = StageReceiptStore(stage).read();
      if (receipt == null) {
        issues.add(const StageIssue(
          StageIssueKind.missingReceipt,
          'files without a stage receipt are not reusable',
          path: 'stage.json',
        ));
      }
    } on Object catch (error) {
      issues.add(StageIssue(
        '$error'.contains('escapes the stage')
            ? StageIssueKind.unsafePath
            : StageIssueKind.invalidReceipt,
        'stage receipt is invalid: $error',
        path: 'stage.json',
      ));
    }

    if (receipt != null) {
      if (receipt.identity.id != stage.identity.id) {
        issues.add(const StageIssue(
          StageIssueKind.wrongStage,
          'receipt identity does not name this stage',
          path: 'stage.json',
        ));
      }
      if (!receipt.complete) {
        issues.add(const StageIssue(
          StageIssueKind.incompleteReceipt,
          'receipt records an incomplete stage',
          path: 'stage.json',
        ));
      }
      for (final artifact in receipt.artifacts) {
        _inspectArtifact(stage, artifact, issues);
      }
      _inspectStructure(stage, receipt, issues);
    }

    _inspectInventory(stage, receipt, issues);
    issues.sort((left, right) {
      final byPath = (left.path ?? '').compareTo(right.path ?? '');
      return byPath != 0 ? byPath : left.kind.index.compareTo(right.kind.index);
    });
    return StageInspection(receipt: receipt, issues: _deduplicate(issues));
  }

  static void _inspectArtifact(
    StageDirectory stage,
    StageArtifact expected,
    List<StageIssue> issues,
  ) {
    var partial = '';
    final parts = StagePath.segments(expected.path);
    for (var i = 0; i < parts.length; i++) {
      partial = partial.isEmpty ? parts[i] : '$partial/${parts[i]}';
      final type = FileSystemEntity.typeSync(
        stage.resolve(partial),
        followLinks: false,
      );
      if (type == FileSystemEntityType.link) {
        issues.add(StageIssue(
          StageIssueKind.symlink,
          'symlinks are never staged artifacts',
          path: partial,
        ));
        return;
      }
      final wanted = i == parts.length - 1
          ? FileSystemEntityType.file
          : FileSystemEntityType.directory;
      if (type == FileSystemEntityType.notFound) {
        issues.add(StageIssue(
          StageIssueKind.missingArtifact,
          'receipt artifact is missing',
          path: expected.path,
        ));
        return;
      }
      if (type != wanted) {
        issues.add(StageIssue(
          StageIssueKind.wrongType,
          'receipt path is not a regular file beneath regular directories',
          path: partial,
        ));
        return;
      }
    }

    try {
      final file = File(stage.resolve(expected.path));
      final stat = file.statSync();
      final bytes = file.readAsBytesSync();
      final differences = <String>[];
      if (_mode(stat.mode) != expected.mode) differences.add('mode');
      if (bytes.length != expected.size) differences.add('size');
      if (Sha256.hex(bytes) != expected.sha256) differences.add('sha256');
      if (differences.isNotEmpty) {
        issues.add(StageIssue(
          StageIssueKind.changedArtifact,
          'artifact ${differences.join(', ')} differs from the receipt',
          path: expected.path,
        ));
      }
    } on FileSystemException catch (error) {
      issues.add(StageIssue(
        StageIssueKind.unreadable,
        'artifact could not be read: ${error.message}',
        path: expected.path,
      ));
    }
  }

  static void _inspectStructure(
    StageDirectory stage,
    StageReceipt receipt,
    List<StageIssue> issues,
  ) {
    final priorSteps = <String, StageStep>{};
    final priorArtifacts = <String, StageArtifact>{};
    final completeIndexes = <int>[];

    if (receipt.steps.isEmpty) {
      _structure(issues, 'receipt has no producer steps');
      return;
    }

    for (var index = 0; index < receipt.steps.length; index++) {
      final step = receipt.steps[index];
      if (step.name == 'complete-stage') completeIndexes.add(index);

      for (final input in step.inputs) {
        final expected = _inputDigest(
          receipt.identity,
          input.name,
          priorSteps,
          priorArtifacts,
        );
        if (expected == null) {
          _structure(
            issues,
            '${step.name} names an input no earlier step produced: '
            '${input.name}',
          );
        } else if (expected != input.sha256) {
          _structure(
            issues,
            '${step.name} input digest differs from its producer: '
            '${input.name}',
          );
        }
      }
      for (final output in step.outputs) {
        priorArtifacts[output.path] = output;
      }
      priorSteps[step.name] = step;
    }

    final source = receipt.steps.first;
    if (source.name != 'source-snapshot') {
      _structure(issues, 'source-snapshot must be the first receipt step');
    } else {
      final expectedInputs = {
        'stage:commit': Sha256.hex(utf8.encode(receipt.identity.headCommit)),
        'stage:tree': Sha256.hex(utf8.encode(receipt.identity.headTree)),
        'stage:plan': receipt.identity.planSha256,
      };
      final actualInputs = {
        for (final input in source.inputs) input.name: input.sha256,
      };
      if (!_sameMap(expectedInputs, actualInputs)) {
        _structure(
          issues,
          'source-snapshot is not bound to commit, tree, and plan',
        );
      }
      if (source.outputs.isEmpty ||
          source.outputs.any(
            (output) =>
                output.type != 'source' || !output.path.startsWith('source/'),
          )) {
        _structure(
          issues,
          'source-snapshot must record its source files',
        );
      }
      if (source.evidence['commit'] != receipt.identity.headCommit ||
          source.evidence['tree'] != receipt.identity.headTree) {
        _structure(
          issues,
          'source-snapshot evidence disagrees with the stage identity',
        );
      }
    }

    // Progress is reusable only if semantic producer evidence validates too;
    // otherwise a crash after a bad archive was receipted would turn that
    // false claim into a trusted input on the next run.
    for (final step in receipt.steps) {
      if (step.name.startsWith('build:macos-')) {
        _inspectSignature(step, issues);
      }
      if (step.name.startsWith('archive:')) {
        for (final output in step.outputs.where(
          (artifact) => artifact.type == 'archive',
        )) {
          _inspectArchive(stage, output.path, step, issues);
        }
      }
    }

    if (!receipt.complete) {
      if (completeIndexes.isNotEmpty) {
        _structure(
          issues,
          'an incomplete receipt cannot contain complete-stage',
        );
      }
      return;
    }
    if (completeIndexes.length != 1 ||
        completeIndexes.singleOrNull != receipt.steps.length - 1) {
      _structure(
        issues,
        'a complete receipt must end with exactly one complete-stage',
      );
      return;
    }

    final complete = receipt.steps.last;
    if (complete.outputs.length != 1 ||
        complete.outputs.single.path != 'release-manifest.json' ||
        complete.outputs.single.type != 'manifest') {
      _structure(
        issues,
        'complete-stage must produce only release-manifest.json',
      );
      return;
    }
    _inspectManifest(stage, receipt, complete, issues);
  }

  static String? _inputDigest(
    StageIdentity identity,
    String name,
    Map<String, StageStep> priorSteps,
    Map<String, StageArtifact> priorArtifacts,
  ) {
    switch (name) {
      case 'stage:commit':
        return Sha256.hex(utf8.encode(identity.headCommit));
      case 'stage:tree':
        return Sha256.hex(utf8.encode(identity.headTree));
      case 'stage:plan':
        return identity.planSha256;
    }
    if (name.startsWith('step:')) {
      return priorSteps[name.substring('step:'.length)]?.outputSha256;
    }
    return priorArtifacts[name]?.sha256;
  }

  static void _inspectManifest(
    StageDirectory stage,
    StageReceipt receipt,
    StageStep complete,
    List<StageIssue> issues,
  ) {
    final ReleaseManifest manifest;
    try {
      manifest = ReleaseManifest.parse(
        File(stage.resolve('release-manifest.json')).readAsStringSync(),
      );
    } on Object catch (error) {
      issues.add(StageIssue(
        StageIssueKind.invalidManifest,
        'release manifest is invalid: $error',
        path: 'release-manifest.json',
      ));
      return;
    }
    if (manifest.identity.id != receipt.identity.id) {
      issues.add(const StageIssue(
        StageIssueKind.invalidManifest,
        'release manifest belongs to another stage',
        path: 'release-manifest.json',
      ));
    }

    final beforeComplete = <String, StageArtifact>{};
    final producers = <String, StageStep>{};
    for (final step in receipt.steps.take(receipt.steps.length - 1)) {
      for (final output in step.outputs) {
        beforeComplete[output.path] = output;
        producers[output.path] = step;
      }
    }
    final manifestNames = manifest.artifacts.map((item) => item.name).toSet();
    final completeInputs = {
      for (final input in complete.inputs) input.name: input.sha256,
    };
    if (completeInputs.keys.toSet().difference(manifestNames).isNotEmpty ||
        manifestNames.difference(completeInputs.keys.toSet()).isNotEmpty) {
      issues.add(const StageIssue(
        StageIssueKind.invalidManifest,
        'complete-stage inputs do not exactly name the public inventory',
        path: 'release-manifest.json',
      ));
    }

    for (final item in manifest.artifacts) {
      final local = beforeComplete[item.name];
      if (local == null ||
          local.type != item.type ||
          local.size != item.size ||
          local.sha256 != item.sha256 ||
          completeInputs[item.name] != item.sha256) {
        issues.add(StageIssue(
          StageIssueKind.invalidManifest,
          'manifest metadata does not match the producer receipt',
          path: item.name,
        ));
        continue;
      }
    }
    _inspectChecksums(stage, manifest, beforeComplete, issues);
  }

  static void _inspectArchive(
    StageDirectory stage,
    String path,
    StageStep? producer,
    List<StageIssue> issues,
  ) {
    try {
      final actual = StageArchiveInventory.parse(
        File(stage.resolve(path)).readAsBytesSync(),
      );
      if (producer == null || !producer.name.startsWith('archive:')) {
        throw const FormatException(
          'archive has no archive producer in the receipt',
        );
      }
      final expected = StageArchiveInventory.parseEvidence(
        producer.evidence['inventory'],
      );
      StageArchiveInventory.requireSame(expected, actual);
    } on Object catch (error) {
      issues.add(StageIssue(
        StageIssueKind.invalidArchive,
        'archive evidence is invalid: $error',
        path: path,
      ));
    }
  }

  static void _inspectSignature(
    StageStep producer,
    List<StageIssue> issues,
  ) {
    final signature = producer.evidence['signature'];
    final binary = producer.outputs.length == 1 &&
            producer.outputs.single.type == 'executable'
        ? producer.outputs.single
        : null;
    String? problem;
    if (binary == null) {
      problem = 'signed build does not produce exactly one executable';
    } else if (producer.inputs.length != 1 ||
        producer.inputs.single.name != 'step:source-snapshot') {
      problem = 'signed build is not bound to the staged source snapshot';
    } else if (signature is! Map) {
      problem = 'signed build has no signature evidence';
    } else {
      final certificate = signature['certificate'];
      final fingerprint = signature['certificate_sha256'];
      final firstIdentity = signature['first_identity'];
      final hasPublishedRequirement =
          signature.containsKey('published_requirement');
      final publishedRequirement = signature['published_requirement'];
      final codeId = signature['code_id'];
      final unsigned = signature['unsigned_sha256'];
      final signed = signature['signed_sha256'];
      if (certificate is! String || certificate.trim().isEmpty) {
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
      } else if (unsigned is! String || !_sha256.hasMatch(unsigned)) {
        problem = 'signature evidence has no unsigned input digest';
      } else if (signed != binary.sha256) {
        problem = 'signature evidence is not bound to the signed bytes';
      }
    }
    if (problem != null) {
      issues.add(StageIssue(
        StageIssueKind.invalidStructure,
        problem,
        path: 'stage.json',
      ));
    }
  }

  static void _inspectChecksums(
    StageDirectory stage,
    ReleaseManifest manifest,
    Map<String, StageArtifact> artifacts,
    List<StageIssue> issues,
  ) {
    final checksumItems =
        manifest.artifacts.where((item) => item.type == 'checksums').toList();
    if (checksumItems.isEmpty) return;
    if (checksumItems.length != 1 ||
        checksumItems.single.name != 'SHA256SUMS') {
      issues.add(const StageIssue(
        StageIssueKind.invalidChecksums,
        'the manifest must carry one SHA256SUMS checksums file',
        path: 'SHA256SUMS',
      ));
      return;
    }
    try {
      final lines = File(stage.resolve('SHA256SUMS')).readAsLinesSync();
      final found = <String, String>{};
      for (final line in lines) {
        if (line.isEmpty) continue;
        final match =
            RegExp(r'^([0-9a-f]{64})  ([^/\\\u0000]+)$').firstMatch(line);
        if (match == null ||
            found.putIfAbsent(match.group(2)!, () => match.group(1)!) !=
                match.group(1)) {
          throw const FormatException('SHA256SUMS has a malformed line');
        }
      }
      final archives = {
        for (final item in manifest.artifacts.where(
          (item) => item.type == 'archive',
        ))
          item.name: item.sha256,
      };
      if (!_sameMap(found, archives)) {
        throw const FormatException(
          'SHA256SUMS does not exactly cover the release archives',
        );
      }
      for (final entry in found.entries) {
        if (artifacts[entry.key]?.sha256 != entry.value) {
          throw FormatException(
            'SHA256SUMS digest disagrees for ${entry.key}',
          );
        }
      }
    } on Object catch (error) {
      issues.add(StageIssue(
        StageIssueKind.invalidChecksums,
        'checksum evidence is invalid: $error',
        path: 'SHA256SUMS',
      ));
    }
  }

  static void _inspectInventory(
    StageDirectory stage,
    StageReceipt? receipt,
    List<StageIssue> issues,
  ) {
    final expectedFiles = <String>{
      'stage.json',
      if (receipt != null)
        ...receipt.artifacts.map((artifact) => artifact.path),
    };
    final expectedDirectories = <String>{};
    for (final path in expectedFiles) {
      final parts = path.split('/');
      for (var i = 1; i < parts.length; i++) {
        expectedDirectories.add(parts.take(i).join('/'));
      }
    }

    void walk(Directory directory) {
      final entities = directory.listSync(followLinks: false)
        ..sort((left, right) => left.path.compareTo(right.path));
      for (final entity in entities) {
        final relative = _relative(stage.path, entity.path);
        final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
        if (type == FileSystemEntityType.link) {
          issues.add(StageIssue(
            StageIssueKind.symlink,
            'symlinks are not permitted in a stage',
            path: relative,
          ));
          if (!expectedFiles.contains(relative) &&
              !expectedDirectories.contains(relative)) {
            issues.add(StageIssue(
              StageIssueKind.extraArtifact,
              'path is not named by the receipt',
              path: relative,
            ));
          }
        } else if (type == FileSystemEntityType.directory) {
          if (!expectedDirectories.contains(relative)) {
            issues.add(StageIssue(
              StageIssueKind.extraArtifact,
              'directory is not needed by a receipt artifact',
              path: relative,
            ));
          }
          walk(Directory(entity.path));
        } else if (type == FileSystemEntityType.file) {
          if (!expectedFiles.contains(relative)) {
            issues.add(StageIssue(
              StageIssueKind.extraArtifact,
              'file is not named by the receipt',
              path: relative,
            ));
          }
        } else {
          issues.add(StageIssue(
            StageIssueKind.wrongType,
            'unsupported filesystem entity in stage',
            path: relative,
          ));
        }
      }
    }

    try {
      walk(Directory(stage.path));
    } on FileSystemException catch (error) {
      issues.add(StageIssue(
        StageIssueKind.unreadable,
        'stage inventory could not be read: ${error.message}',
      ));
    }
  }
}

void _structure(List<StageIssue> issues, String message) {
  issues.add(StageIssue(
    StageIssueKind.invalidStructure,
    message,
    path: 'stage.json',
  ));
}

bool _sameMap(Map<String, String> left, Map<String, String> right) {
  if (left.length != right.length) return false;
  for (final entry in left.entries) {
    if (right[entry.key] != entry.value) return false;
  }
  return true;
}

String _relative(String root, String path) {
  final prefix = root.endsWith(Platform.pathSeparator)
      ? root
      : '$root${Platform.pathSeparator}';
  if (!path.startsWith(prefix)) {
    throw FileSystemException('inventory path escaped the stage', path);
  }
  return path.substring(prefix.length).split(Platform.pathSeparator).join('/');
}

String _mode(int mode) => (mode & 0xfff).toRadixString(8).padLeft(4, '0');

List<StageIssue> _deduplicate(List<StageIssue> issues) {
  final keys = <String>{};
  return [
    for (final issue in issues)
      if (keys
          .add('${issue.kind.index}\u0000${issue.path}\u0000${issue.message}'))
        issue,
  ];
}
