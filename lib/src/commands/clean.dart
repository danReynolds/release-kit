import 'dart:io';

import '../engine/diagnostic.dart';
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
Usage
  rk clean                         preview and confirm local stage cleanup
  rk clean --yes                  remove local stages without prompting
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
        note: '$found ${found == 1 ? 'stage' : 'stages'} · '
            '.rk/work/stages',
        depth: 1,
        labelWidth: 10,
        role: VisualRole.localWork,
        noteRole: VisualRole.secondary,
      );
      output.line(
        'keep',
        note: 'diagnoses · .rk/diagnosis',
        depth: 1,
        labelWidth: 10,
        role: VisualRole.secondary,
        noteRole: VisualRole.secondary,
      );
      output.blank();
      output.warning(const Diagnostic(
        code: 'RK-CLEAN-005',
        message: 'a partially completed release may need these exact staged '
            'bytes to resume',
      ));

      if (!yes) {
        final ask = confirm;
        if (ask == null) {
          output.blank();
          output.problem(const Diagnostic(
            code: 'RK-CLEAN-004',
            message: 'nobody is here to authorize cleanup',
            remedy: 'review the staged work above, then run rk clean --yes',
          ));
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

      final current = store.inventory();
      if (!_sameEntries(inventory, current)) {
        output.blank();
        output.problem(const Diagnostic(
          code: 'RK-CLEAN-003',
          message: 'staged work changed while cleanup was being reviewed',
          remedy: 'nothing was removed; run rk clean again to review the '
              'current staged work',
        ));
        return ExitCodes.refused;
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
        output.problem(Diagnostic(
          code: 'RK-CLEAN-003',
          message: 'staged work changed while cleanup was running',
          remedy: '$removed ${removed == 1 ? 'stage was' : 'stages were'} '
              'removed; the changed entries were left alone. Run rk clean '
              'again to review what remains.',
        ));
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
      output.problem(const Diagnostic(
        code: 'RK-CLEAN-002',
        message: 'another rk command is using staged work',
        remedy: 'let that command finish, then run rk clean again',
      ));
      return ExitCodes.refused;
    } on StageStoreUnsafe catch (error) {
      output.problem(Diagnostic(
        code: 'RK-CLEAN-001',
        message: 'the local stage path is not safe to clean',
        remedy: '$error\nRK did not follow or remove the unexpected path.',
      ));
      return ExitCodes.refused;
    } on FileSystemException catch (error) {
      output.problem(Diagnostic(
        code: 'RK-CLEAN-003',
        message: 'local staged work could not be completely removed',
        remedy: '$error\nReview .rk/work/stages, then run rk clean again.',
      ));
      return ExitCodes.refused;
    } finally {
      lock?.close();
    }
  }

  void _heading() {
    final separator = Platform.pathSeparator;
    final parts = store.repositoryRoot.split(separator);
    output.heading(parts.lastWhere((part) => part.isNotEmpty,
        orElse: () => store.repositoryRoot));
  }

  static bool _sameEntries(List<StageEntry> left, List<StageEntry> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index].name != right[index].name ||
          left[index].type != right[index].type) {
        return false;
      }
    }
    return true;
  }
}
