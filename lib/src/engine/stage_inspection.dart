import 'dart:io';

import '../transforms/digest.dart';
import 'stage.dart';
import 'stage_receipt.dart';
import 'timings.dart';
import 'verdict.dart';

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
  unreadable,
  invalidStructure,
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

  /// Whether this receipt describes work that stopped before completion. Its
  /// recorded steps may be reused, but it is never a completed stage.
  bool get incomplete => receipt?.complete == false;

  /// Whether the receipt claims the completion barrier was reached.
  bool get claimsCompletion =>
      receipt?.complete == true ||
      receipt?.steps.any((step) => step.name == 'complete-stage') == true;

  /// Whether an interrupted stage can be resumed: every recorded output is
  /// intact, and only completion remains.
  bool get validProgress =>
      receipt?.complete == false &&
      receipt!.steps.isNotEmpty &&
      issues.isNotEmpty &&
      issues.every((issue) => issue.kind == StageIssueKind.incompleteReceipt);

  /// Whether only the plan was recorded: nothing produced yet.
  bool get planRecorded =>
      receipt?.plan != null &&
      receipt!.steps.isEmpty &&
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

/// What gets published from a stage. Intermediates — executables, notary
/// submissions and their logs — reach the public only inside an archive
/// whose own bytes are checked, so a completed stage checks only these.
const publishedArtifactTypes = {
  'archive',
  'asset',
  'formula',
  'manifest',
  'notes',
  'pub-archive',
};

/// Reads a stage's receipt and checks the files it records, without
/// executing anything, contacting a service, or changing the filesystem.
///
/// A completed stage is checked for what it publishes; an interrupted one
/// for everything it recorded, since producers resume from those files.
/// Files the receipt does not name are not the stage's: nothing reads them.
class StageInspector {
  const StageInspector();

  StageInspection inspect(StageDirectory stage) =>
      Timings.spanSync('verify stage files', () => _inspect(stage));

  StageInspection _inspect(StageDirectory stage) {
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

    final StageReceipt? receipt;
    try {
      receipt = StageReceiptStore(stage).read();
    } on Object catch (error) {
      return StageInspection(
        receipt: null,
        issues: [
          StageIssue(
            StageIssueKind.invalidReceipt,
            'stage receipt is invalid: $error',
            path: 'stage.json',
          ),
        ],
      );
    }
    if (receipt == null) {
      return StageInspection(
        receipt: null,
        issues: const [
          StageIssue(
            StageIssueKind.missingReceipt,
            'files without a stage receipt are not reusable',
            path: 'stage.json',
          ),
        ],
      );
    }

    final issues = <StageIssue>[];
    if (receipt.identity.id != stage.identity.id) {
      issues.add(
        const StageIssue(
          StageIssueKind.wrongStage,
          'receipt identity does not name this stage',
          path: 'stage.json',
        ),
      );
    }
    if (!receipt.complete) {
      issues.add(
        const StageIssue(
          StageIssueKind.incompleteReceipt,
          'receipt records an incomplete stage',
          path: 'stage.json',
        ),
      );
    }
    for (final artifact in receipt.artifacts) {
      if (receipt.complete && !publishedArtifactTypes.contains(artifact.type)) {
        continue;
      }
      _inspectArtifact(stage, artifact, issues);
    }
    return StageInspection(receipt: receipt, issues: issues);
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
        issues.add(
          StageIssue(
            StageIssueKind.symlink,
            'symlinks are never staged artifacts',
            path: partial,
          ),
        );
        return;
      }
      final wanted = i == parts.length - 1
          ? FileSystemEntityType.file
          : FileSystemEntityType.directory;
      if (type == FileSystemEntityType.notFound) {
        issues.add(
          StageIssue(
            StageIssueKind.missingArtifact,
            'receipt artifact is missing',
            path: expected.path,
          ),
        );
        return;
      }
      if (type != wanted) {
        issues.add(
          StageIssue(
            StageIssueKind.wrongType,
            'receipt path is not a regular file beneath regular directories',
            path: partial,
          ),
        );
        return;
      }
    }

    try {
      // Within one run rk trusts its own writes: a file this process hashed
      // to the recorded digest, and that has not moved since, is not read
      // again. A later run reads and hashes it once.
      if (stage.digestStillStands(expected.path, expected.sha256)) return;
      final file = File(stage.resolve(expected.path));
      final stat = file.statSync();
      final bytes = file.readAsBytesSync();
      final sha256 = Sha256.hex(bytes);
      final differences = <String>[];
      if (_mode(stat.mode) != expected.mode) differences.add('mode');
      if (bytes.length != expected.size) differences.add('size');
      if (sha256 != expected.sha256) differences.add('sha256');
      if (differences.isEmpty) {
        stage.noteDigested(expected.path, stat, sha256);
      } else {
        issues.add(
          StageIssue(
            StageIssueKind.changedArtifact,
            'artifact ${differences.join(', ')} differs from the receipt',
            path: expected.path,
          ),
        );
      }
    } on FileSystemException catch (error) {
      issues.add(
        StageIssue(
          StageIssueKind.unreadable,
          'artifact could not be read: ${error.message}',
          path: expected.path,
        ),
      );
    }
  }
}

String _mode(int mode) => (mode & 0xfff).toRadixString(8).padLeft(4, '0');
