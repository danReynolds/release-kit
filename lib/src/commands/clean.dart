import 'dart:io';

import '../engine/diagnostic.dart';
import '../engine/stage_receipt.dart';
import '../engine/stage_store.dart';
import '../output/output.dart';

/// Explicitly removes repository-local private release stages.
///
/// Cleanup does not inspect public targets and therefore makes no claim that a
/// completed stage is disposable. The disclosure and authorization are the
/// safety boundary: an operator may intentionally discard the same directory
/// by hand, but rk makes the recovery consequence hard to miss.
final class CleanCommand {
  const CleanCommand({
    required this.store,
    required this.output,
    required this.yes,
    this.confirm,
  });

  static const usage = '''
rk clean [--yes] [--json]

Remove this repository's staged release work, after listing it and asking.
Diagnoses in .rk/diagnosis are kept. A partly published release may need
its exact stage to finish, so remove one only when it is no longer needed.

-y, --yes remove the listed stages without the prompt
--json    report what is there; removes only with --yes

Example: rk clean
''';

  final StageStore store;
  final Output output;
  final bool yes;
  final Future<String?> Function(String prompt)? confirm;

  Future<int> run() async {
    StageStoreLock? lock;
    try {
      // Preserve the empty no-op: merely inspecting a repository must not
      // create .rk/work just to hold a lock for work that does not exist.
      final observed = store.inventory();
      if (observed.isNotEmpty) {
        // The inventory shown for authorization is read under the same lock
        // release holds while it can make a stage recovery-critical.
        lock = store.acquireForMutation();
      }
      final inventory = lock == null ? observed : store.inventory();
      final found = inventory.length;
      output.report.cleanup(
        root: store.repositoryRoot,
        path: '.rk/work/stages',
        found: found,
        removed: 0,
      );
      _heading();

      if (found == 0) {
        output.blank();
        output.line(
          'no staged release work',
          mark: Mark.satisfied,
          state: RuntimeState.satisfied,
        );
        return ExitCodes.ok;
      }

      output.blank();
      output.line(
        'remove',
        note:
            '$found ${found == 1 ? 'stage' : 'stages'} · '
            '.rk/work/stages',
        depth: 1,
        labelWidth: 10,
        role: VisualRole.localWork,
        noteRole: VisualRole.secondary,
      );
      for (final entry in inventory) {
        output.line(
          RegExp(r'^[0-9a-f]{64}$').hasMatch(entry.name)
              ? entry.name.substring(0, 12)
              : entry.name,
          note: _describeEntry(entry),
          depth: 2,
          labelWidth: 16,
          role: VisualRole.secondary,
          noteRole: VisualRole.secondary,
        );
      }
      output.line(
        'keep',
        note: 'diagnoses · .rk/diagnosis',
        depth: 1,
        labelWidth: 10,
        role: VisualRole.secondary,
        noteRole: VisualRole.secondary,
      );
      output.blank();
      output.warning(
        const Diagnostic(
          code: 'RK-CLEAN-005',
          message:
              'a partially completed release may need these exact staged '
              'bytes to resume',
        ),
      );

      if (!yes) {
        final ask = confirm;
        if (ask == null) {
          output.blank();
          output.problem(
            const Diagnostic(
              code: 'RK-AUTH-001',
              message: 'nobody is here to authorize cleanup',
              remedy: 'review the staged work above, then run rk clean --yes',
            ),
          );
          output.report.next('rk clean --yes');
          return ExitCodes.refused;
        }
        final answer = await ask('Remove staged release work? [y/N] ');
        final accepted = switch (answer?.trim().toLowerCase()) {
          'y' || 'yes' => true,
          _ => false,
        };
        if (!accepted) {
          output.say('nothing removed.');
          return ExitCodes.refused;
        }
      }

      output.report.acted = true;
      var removed = 0;
      for (final entry in inventory) {
        if (!store.deleteEntry(entry)) continue;
        removed++;
        output.report.cleanup(
          root: store.repositoryRoot,
          path: '.rk/work/stages',
          found: found,
          removed: removed,
        );
      }
      if (removed != found) {
        output.blank();
        output.problem(
          Diagnostic(
            code: 'RK-CLEAN-003',
            message: 'staged work changed while cleanup was running',
            remedy:
                '$removed ${removed == 1 ? 'stage was' : 'stages were'} '
                'removed; the changed entries were left alone. Run rk clean '
                'again to review what remains.',
          ),
        );
        return ExitCodes.refused;
      }

      output.blank();
      output.line(
        'removed $removed ${removed == 1 ? 'stage' : 'stages'}',
        mark: Mark.done,
        state: RuntimeState.success,
      );
      return ExitCodes.ok;
    } on StageStoreBusy {
      output.problem(
        const Diagnostic(
          code: 'RK-STAGE-006',
          message: 'another rk command is using staged work',
          remedy: 'let that command finish, then run rk clean again',
        ),
      );
      return ExitCodes.refused;
    } on StageStoreUnsafe catch (error) {
      output.problem(
        Diagnostic(
          code: 'RK-STAGE-006',
          message: 'the local stage path is not safe to clean',
          remedy: '$error\nRK did not follow or remove the unexpected path.',
        ),
      );
      return ExitCodes.refused;
    } on FileSystemException catch (error) {
      output.problem(
        Diagnostic(
          code: 'RK-CLEAN-003',
          message: 'local staged work could not be completely removed',
          remedy: '$error\nReview .rk/work/stages, then run rk clean again.',
        ),
      );
      return ExitCodes.refused;
    } finally {
      lock?.close();
    }
  }

  /// Receipt metadata helps identify the bytes being discarded. It does not
  /// verify artifacts or establish whether a public release still needs them.
  String _describeEntry(StageEntry entry) {
    if (entry.type == FileSystemEntityType.link) {
      return 'symbolic link · not followed';
    }
    if (entry.type != FileSystemEntityType.directory) {
      return 'not a stage directory';
    }
    try {
      final directory = '${store.path}/${entry.name}';
      if (FileSystemEntity.typeSync(directory, followLinks: false) !=
          FileSystemEntityType.directory) {
        return 'stage directory changed';
      }
      final file = File('$directory/stage.json');
      final type = FileSystemEntity.typeSync(file.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) return 'no stage receipt';
      if (type != FileSystemEntityType.file) {
        return 'stage receipt is not a regular file · not read';
      }
      if (file.lengthSync() > 4 * 1024 * 1024) {
        return 'stage receipt too large to inspect';
      }
      final receipt = StageReceipt.parse(file.readAsStringSync());
      if (receipt.identity.id != entry.name) {
        return 'stage receipt belongs to another stage';
      }
      final unit = receipt.plan?['unit'];
      final commit = receipt.identity.headCommit;
      return [
        if (unit is Map && unit['name'] is String && unit['version'] is String)
          '${unit['name']} ${unit['version']}',
        'commit ${commit.substring(0, 7)}',
        receipt.complete ? 'completion recorded' : 'incomplete stage',
      ].join(' · ');
    } on Object {
      // A broken or obsolete receipt must remain cleanable. Cleanup neither
      // follows its artifact paths nor treats missing metadata as approval.
      return 'unreadable stage receipt';
    }
  }

  void _heading() {
    final separator = Platform.pathSeparator;
    final parts = store.repositoryRoot.split(separator);
    output.heading(
      parts.lastWhere(
        (part) => part.isNotEmpty,
        orElse: () => store.repositoryRoot,
      ),
    );
  }
}
