import '../engine/stage_board.dart';
import '../engine/stage_receipt.dart';
import '../engine/targets.dart';
import '../engine/tools.dart';
import '../engine/verdict.dart';
import '../output/output.dart';
import '../output/progress.dart';
import '../targets/target_module.dart';

/// Public-target rows rendered through RK's shared progress model.
final class TargetReleaseProgress {
  TargetReleaseProgress(
    Output output, {
    required String title,
    required Iterable<TargetPlan> targets,
    Duration delay = const Duration(milliseconds: 80),
  })  : _output = output,
        live = output.progressBoard(
          title,
          delay: delay,
          emitSlowToNonTerminal: true,
        ) {
    for (final target in targets) {
      _controllers[target.step.id] = live.addRow(
        id: target.step.id,
        label: target.kindLabel,
        coordinate: target.coordinate,
      );
    }
  }

  final Output _output;
  final LiveProgress live;
  final Map<String, ProgressRowController> _controllers = {};

  ProgressRowController _row(TargetPlan target) =>
      _controllers[target.step.id]!;

  ProgressHandle handle(TargetPlan target) => _row(target).handle;

  ProgressHandle combined(Iterable<TargetPlan> targets) =>
      ProgressHandle.combine(targets.map(handle));

  void begin(TargetPlan target, ProgressActivity activity, {String? detail}) {
    final row = _row(target);
    if (row.state == ProgressRowState.complete) return;
    row.handle.begin(activity, detail: detail);
  }

  void complete(
    TargetPlan target, {
    required String note,
    bool satisfied = false,
    bool restore = false,
  }) {
    final row = _row(target);
    if (row.state == ProgressRowState.complete) return;
    final mark = satisfied ? ProgressRowMark.satisfied : ProgressRowMark.done;
    if (restore || row.state == ProgressRowState.pending) {
      row.restoreComplete(note: note, mark: mark);
    } else {
      row.complete(note: note, mark: mark);
    }
  }

  void observe(TargetPlan target, Inspection inspection) {
    final row = _row(target);
    if (row.state != ProgressRowState.active) return;
    if (inspection.isExact) {
      row.complete(
        note: 'already published',
        mark: ProgressRowMark.satisfied,
      );
    } else if (inspection.isAbsent) {
      row.complete(
        note: 'not published',
        mark: ProgressRowMark.none,
      );
    } else {
      row.complete(
        note:
            inspection.verdict == Verdict.conflict ? 'conflict' : 'unreadable',
        mark: ProgressRowMark.none,
        emphasis: ProgressRowEmphasis.attention,
      );
    }
  }

  void fail(
    TargetPlan target, {
    ProgressActivity? activity,
    String? note,
  }) {
    final row = _row(target);
    if (row.state == ProgressRowState.active) {
      row.fail(activity: activity, note: note);
    }
  }

  void failAll(
    Iterable<TargetPlan> targets, {
    required ProgressActivity activity,
  }) {
    for (final target in targets) {
      fail(target, activity: activity);
    }
  }

  void notAttemptedPending() {
    for (final row in _controllers.values.where(
      (row) => row.state == ProgressRowState.pending,
    )) {
      row.notAttempted();
    }
  }

  ProgressInteractiveRunner interactive(Tools tools) {
    return (
      String executable,
      List<String> arguments, {
      String? workingDirectory,
    }) async {
      live.suspend();
      try {
        return await tools.runInteractive(
          executable,
          arguments,
          workingDirectory: workingDirectory,
        );
      } finally {
        live.resume(afterNativeOutput: _output.isTerminal);
      }
    };
  }

  void discard() => live.discard();

  void settle({bool released = false}) => live.settle(
        title: released
            ? live.model.title.replaceFirst(' · releasing', ' · released')
            : null,
      );
}

/// Receipt-backed stage rows rendered through the shared progress model.
final class StageReleaseProgress {
  StageReleaseProgress(
    Output output, {
    required String title,
    required this.board,
  }) : live = output.progressBoard(
          title,
          emitSlowToNonTerminal: true,
        ) {
    for (final group in board.groups) {
      for (final row in group.rows) {
        _controllers[row] = live.addRow(
          id: row.id,
          label: row.name,
          group: group.label,
        );
      }
    }
  }

  final StageBoard board;
  final LiveProgress live;
  final Map<StageBoardRow, ProgressRowController> _controllers = {};
  final Map<String, StageStep> _recorded = {};

  ProgressHandle? handleFor(String producer) {
    final rows = board.rowsFor(producer);
    if (rows.isEmpty) return null;
    return ProgressHandle.combine(
      rows.map((row) => _controllers[row]!.handle),
    );
  }

  Map<String, ProgressHandle> handlesFor(TargetStage stage) => {
        for (final view in stage.progress)
          view.id: _controllers[
                  board.progressRow(stage.contract.step.name, view.id)!]!
              .handle,
      };

  void begin(String producer, ProgressActivity activity) {
    for (final row in board.rowsFor(producer)) {
      final controller = _controllers[row]!;
      if (controller.state == ProgressRowState.complete) continue;
      controller.handle.begin(activity);
    }
  }

  void record(StageStep step) => restore([step]);

  void restore(Iterable<StageStep> steps) {
    for (final step in steps) {
      _recorded[step.name] = step;
    }
    for (final group in board.groups) {
      for (final row in group.rows) {
        final expected = board.producersFor(row);
        if (expected.isEmpty || !expected.every(_recorded.containsKey)) {
          continue;
        }
        final controller = _controllers[row]!;
        final note = _noteFor(expected);
        switch (controller.state) {
          case ProgressRowState.pending:
            controller.restoreComplete(note: note);
          case ProgressRowState.active:
            controller.complete(note: note);
          case ProgressRowState.complete:
          case ProgressRowState.failed:
          case ProgressRowState.notAttempted:
            break;
        }
      }
    }
  }

  String _noteFor(Set<String> producers) {
    final facts = <String>['staged'];
    for (final producer in producers) {
      final step = _recorded[producer]!;
      final signature = step.evidence['signature'];
      final notary = step.evidence['notary'];
      if (signature is Map && signature['certificate'] is String) {
        facts.add('signed');
      }
      if (notary is Map && notary['status'] == 'Accepted') {
        facts.add('notarized');
      }
    }
    return facts.toSet().join(' · ');
  }

  void fail(String producer) {
    for (final row in board.rowsFor(producer)) {
      final controller = _controllers[row]!;
      if (controller.state == ProgressRowState.active) {
        controller.fail();
      }
    }
  }

  void conclude() => live.conclude();

  void discard() => live.discard();

  void concludeStopped() {
    for (final group in board.groups) {
      for (final row in group.rows) {
        final controller = _controllers[row]!;
        if (controller.state == ProgressRowState.active) {
          controller.notAttempted();
        }
      }
    }
    live.conclude();
  }

  void settle({String? title}) => live.settle(title: title);
}
