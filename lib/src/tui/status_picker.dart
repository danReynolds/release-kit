import 'dart:async';

import 'package:fleury/fleury.dart';

import '../commands/status.dart';
import '../engine/checklist.dart';
import '../engine/diagnostic.dart';
import '../engine/publish_target.dart';
import '../engine/resolve.dart';
import '../engine/targets.dart';
import '../engine/verdict.dart';
import '../output/output.dart' show terminalSafeText;
import 'matrix.dart';
import 'terminal.dart';

/// A refresh owns its readers. Closing the view cancels their HTTP/process work.
class StatusReadSession {
  StatusReadSession(this.command, this._close);
  final StatusCommand command;
  final void Function() _close;
  bool _closed = false;
  void close() {
    if (_closed) return;
    _closed = true;
    _close();
  }
}

class StatusLoadFailure implements Exception {
  StatusLoadFailure(this.message, this.code);
  final String message;
  final int code;
}

typedef StatusCellKey = (String unit, String column);

class StatusRow {
  StatusRow(this.unit, this.plans, this.hasStage);
  final ResolvedUnit unit;
  final List<TargetPlan> plans;
  final bool hasStage;
  final targets = <String, TargetObservation>{};
  Inspection? stage;
  StatusUnitSnapshot? complete;
}

/// UI state contains presentation progress only. Release conclusions come from
/// StatusCommand.collect, shared with the finite report and JSON output.
class StatusPicker extends Notifier {
  StatusPicker({required this.load, required this.close, this.only});
  final Future<StatusReadSession> Function() load;
  final void Function() close;
  final String? only;
  List<StatusRow> rows = [];
  StatusSnapshot? snapshot;
  DateTime? checkedAt;
  StatusReadSession? lastCompleted;
  StatusReadSession? _reading;
  bool checking = false, _disposed = false;
  int _generation = 0;
  String? error;
  int errorCode = 0;
  StatusCellKey? detail;

  Future<void> refresh() async {
    if (_disposed || checking) return;
    checking = true;
    error = null;
    errorCode = 0;
    final generation = ++_generation;
    notify();
    bool current() => !_disposed && generation == _generation;
    StatusReadSession? session;
    try {
      session = await load();
      if (!current()) return;
      _reading = session;
      final command = session.command;
      final units = command.resolution.units
          .where((u) => only == null || u.name == only)
          .toList();
      if (units.isEmpty) {
        throw StatusLoadFailure(
          'No release unit named "$only". Available: ${command.resolution.units.map((u) => u.name).join(', ')}.',
          2,
        );
      }
      rows = [for (final unit in units) _plan(command, unit)];
      snapshot = null;
      detail = null;
      notify();
      final result = await command.collect(
        only: only,
        onStage: (unit, state) {
          if (current()) {
            _row(unit).stage = state;
            notify();
          }
        },
        onTarget: (unit, target) {
          if (current()) {
            _row(unit).targets[target.expectation.step.id] = target;
            notify();
          }
        },
        onUnit: (unit) {
          if (current()) {
            final row = _row(unit.unit.name);
            row.complete = unit;
            row.stage = unit.stageState;
            row.targets
              ..clear()
              ..addEntries(
                unit.targets.map((t) => MapEntry(t.expectation.step.id, t)),
              );
            notify();
          }
        },
      );
      if (!current()) return;
      snapshot = result;
      checkedAt = DateTime.now();
      lastCompleted = session;
    } on Object catch (failure) {
      if (!current()) return;
      error = failure is StatusLoadFailure
          ? failure.message
          : 'Could not refresh release status: $failure';
      errorCode = failure is StatusLoadFailure ? failure.code : 1;
      if (errorCode == 0) {
        close(); // No configuration: retain the ordinary setup hint.
      }
    } finally {
      session?.close();
      if (current()) {
        _reading = null;
        checking = false;
        notify();
      }
    }
  }

  StatusRow _plan(StatusCommand command, ResolvedUnit unit) {
    final checklist = Checklist.derive(unit, command.resolution, Diagnostics());
    return StatusRow(
      unit,
      command.inspector.targets.derive(
        unit,
        checklist,
        repository: command.git.originUrl,
      ),
      checklist.steps.any((s) => s.phase == StepPhase.stage),
    );
  }

  StatusRow _row(String name) => rows.singleWhere((r) => r.unit.name == name);
  String get repository =>
      (_reading ?? lastCompleted)?.command.tree.description.split('/').last ??
      '';
  List<String> get columns => [
    if (rows.any((r) => r.hasStage)) 'stage',
    for (final target in PublishTarget.values)
      if (rows.any((r) => r.plans.any((p) => p.target == target)))
        target.wireName,
  ];
  List<StatusIssue> get issues =>
      snapshot?.issues ?? [for (final r in rows) ...?r.complete?.issues];
  void inspect(StatusCellKey key) {
    detail = key;
    notify();
  }

  void back() {
    detail = null;
    notify();
  }

  void exit() {
    if (detail != null) {
      back();
    } else {
      interrupt();
    }
  }

  void interrupt() {
    _generation++;
    _reading?.close();
    _reading = null;
    close();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _reading?.close();
    super.dispose();
  }
}

Future<int> runStatusPicker(StatusPicker model) =>
    runMatrixScreen(StatusScreen(model), interrupt: model.interrupt);

Future<
  ({
    int code,
    int errorCode,
    String? error,
    StatusSnapshot? snapshot,
    StatusCommand? command,
  })
>
runStatusInteraction({
  required Future<StatusReadSession> Function() load,
  String? only,
}) async {
  final model = StatusPicker(load: load, close: exitApp, only: only);
  try {
    final code = await runStatusPicker(model);
    return (
      code: code,
      errorCode: model.errorCode,
      error: model.error,
      snapshot: model.checking ? null : model.snapshot,
      command: model.lastCompleted?.command,
    );
  } finally {
    model.dispose();
  }
}

class StatusScreen extends StatefulWidget {
  const StatusScreen(this.model, {super.key});
  final StatusPicker model;
  @override
  State<StatusScreen> createState() => _StatusScreenState();
}

class _StatusScreenState extends State<StatusScreen> {
  StatusPicker get model => widget.model;
  final _nodes = <StatusCellKey, FocusNode>{};
  final _done = FocusNode();
  final _scroll = ScrollController();
  StatusCellKey? _focused;
  bool _showingDetail = false;
  @override
  void initState() {
    super.initState();
    TuiBinding.of(context).addPostFrameCallback((_) {
      if (mounted) unawaited(model.refresh());
    });
  }

  @override
  void dispose() {
    for (final n in _nodes.values) {
      n.dispose();
    }
    _done.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<StatusCellKey> _choices(StatusRow row) => [
    (row.unit.name, 'unit'),
    for (final column in model.columns)
      if (column == 'stage'
          ? row.hasStage
          : row.plans.any((p) => p.kind == column))
        (row.unit.name, column),
  ];
  void _move(int delta, {bool horizontal = false}) {
    final rows = model.rows.map(_choices).toList();
    if (rows.isEmpty) return;
    final current = _nodes.entries
        .where((e) => e.value.hasFocus)
        .firstOrNull
        ?.key;
    final rowIndex = rows.indexWhere((r) => r.any((key) => key == current));
    StatusCellKey next;
    if (rowIndex < 0) {
      next = delta > 0 ? rows.first.first : rows.last.first;
    } else if (horizontal) {
      final row = rows[rowIndex];
      next = row[(row.indexOf(current!) + delta).clamp(0, row.length - 1)];
    } else {
      final row = rows[(rowIndex + delta).clamp(0, rows.length - 1)];
      next = row.where((k) => k.$2 == current!.$2).firstOrNull ?? row.first;
    }
    _nodes[next]?.requestFocus();
  }

  List<KeyBinding> get _keys => [
    KeyBinding(KeySequence.down, onTrigger: (_) => _move(1)),
    KeyBinding(KeySequence.up, onTrigger: (_) => _move(-1)),
    KeyBinding(KeySequence.right, onTrigger: (_) => _move(1, horizontal: true)),
    KeyBinding(KeySequence.left, onTrigger: (_) => _move(-1, horizontal: true)),
    KeyBinding(KeySequence.r, onTrigger: (_) => unawaited(model.refresh())),
  ];
  @override
  Widget build(BuildContext context) {
    context.listen(model);
    if (_showingDetail && model.detail == null) {
      TuiBinding.of(context).addPostFrameCallback((_) {
        if (!mounted) return;
        final node = _nodes[_focused];
        final stillVisible = model.rows.any(
          (row) => _choices(row).contains(_focused),
        );
        if (stillVisible && node != null && node.canRequestFocus) {
          node.requestFocus();
        } else {
          _done.requestFocus();
        }
      });
    }
    _showingDetail = model.detail != null;
    if (model.detail case final key?) {
      final row = model.rows.where((r) => r.unit.name == key.$1).firstOrNull;
      return MatrixDetails(
        command: 'rk status',
        maxWidth: commandTableWidth,
        title: row == null
            ? key.$2 == 'error'
                  ? 'Status check failed'
                  : 'Release issues'
            : '${row.unit.name} · ${key.$2 == 'unit' ? row.unit.version.canonical : statusColumnLabel(key.$2)}',
        body: row == null
            ? key.$2 == 'error'
                  ? model.error ?? ''
                  : _issuesText(
                      model.issues,
                      warning: model.snapshot?.warning?.message,
                    )
            : statusDetails(row, key.$2, model.snapshot),
        onBack: model.back,
      );
    }
    final issues = model.issues;
    final subtitle = model.error != null
        ? (model.snapshot == null
              ? 'Could not read release status.'
              : 'Previous results · refresh failed.')
        : model.checking || model.snapshot == null
        ? 'Checking release destinations and staged artifacts…'
        : 'Release destinations and staged artifacts · checked at ${model.checkedAt!.toLocal().toIso8601String().substring(11, 19)}';
    final keys = _keys;
    return KeyBindings(
      bindings: keys,
      child: MatrixShell(
        command: 'rk status',
        count: model.repository,
        maxWidth: commandTableWidth,
        subtitle: subtitle,
        onEscape: model.exit,
        scrollController: _scroll,
        failed: model.error != null || issues.isNotEmpty,
        message: model.error != null
            ? 'Read failed. Open error details for the cause and next step.'
            : model.checking
            ? ''
            : model.snapshot?.nextCommand != null
            ? 'Next: ${model.snapshot!.nextCommand}'
            : issues.isNotEmpty
            ? issues.first.diagnostic.message
            : '',
        hint: '↑↓ unit · ←→ destination · Tab move · Enter inspect',
        actions: [
          if (model.error != null)
            MatrixButton(
              text: 'Error details',
              appearance: ButtonAppearance.plain,
              baseStyle: attentionText,
              onPressed: () => model.inspect(('', 'error')),
            ),
          if (issues.isNotEmpty || model.snapshot?.warning != null)
            MatrixButton(
              text:
                  '${issues.length} ${issues.length == 1 ? 'issue' : 'issues'}${model.snapshot?.warning != null ? ' · warning' : ''}',
              appearance: ButtonAppearance.plain,
              baseStyle: attentionText,
              onPressed: () => model.inspect(('', 'issues')),
            ),
          MatrixButton(
            text: 'r Refresh',
            appearance: ButtonAppearance.plain,
            onPressed: model.checking ? null : () => unawaited(model.refresh()),
          ),
          MatrixButton(
            text: 'Esc Done',
            focusNode: _done,
            appearance: ButtonAppearance.plain,
            onPressed: model.exit,
          ),
        ],
        child: KeyBindings(
          bindings: keys,
          child: LayoutBuilder(
            builder: (_, bounds) {
              final columns = model.columns;
              final width = bounds.maxCols ?? 100;
              final unitWidth = 23;
              final cellWidth = columns.isEmpty
                  ? 15
                  : (width - unitWidth) ~/ columns.length;
              final wide = width >= 70 && cellWidth >= 14;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (model.rows.isEmpty)
                    Text(
                      model.error == null
                          ? 'Reading release.toml…'
                          : 'Refresh to try again.',
                      style: mutedText,
                    ),
                  if (wide && model.rows.isNotEmpty)
                    Row(
                      children: [
                        const SizedBox(
                          width: 23,
                          child: Text('Release unit', style: mutedText),
                        ),
                        for (final c in columns)
                          SizedBox(
                            width: cellWidth,
                            child: Text(statusColumnLabel(c), style: mutedText),
                          ),
                      ],
                    ),
                  if (model.rows.isNotEmpty) const MatrixRule(),
                  for (final row in model.rows) ...[
                    if (wide)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(width: unitWidth, child: _cell(row, 'unit')),
                          for (final c in columns)
                            SizedBox(width: cellWidth, child: _cell(row, c)),
                        ],
                      )
                    else ...[
                      _cell(row, 'unit'),
                      for (final c in columns)
                        if (_choices(row).contains((row.unit.name, c)))
                          Row(
                            children: [
                              SizedBox(
                                width: width < 40 ? 10 : 13,
                                child: Text(
                                  statusColumnLabel(c),
                                  style: mutedText,
                                ),
                              ),
                              Expanded(child: _cell(row, c)),
                            ],
                          ),
                    ],
                    const MatrixRule(),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _cell(StatusRow row, String column) {
    final key = (row.unit.name, column);
    if (!_choices(row).contains(key)) return const Text('—', style: mutedText);
    final value = statusCell(row, column);
    return FocusDetector(
      key: ValueKey(key),
      onFocusChange: (focused) {
        if (focused) _focused = key;
      },
      child: MatrixButton(
        focusNode: _nodes.putIfAbsent(key, FocusNode.new),
        appearance: ButtonAppearance.plain,
        baseStyle: value.$3,
        semanticLabel:
            '${row.unit.name} ${statusColumnLabel(column)} ${value.$1} ${value.$2}',
        onPressed: () => model.inspect(key),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              terminalSafeText(value.$1),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (value.$2.isNotEmpty)
              Text(
                terminalSafeText(value.$2),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
      ),
    );
  }
}

String statusColumnLabel(String column) => switch (column) {
  'stage' => 'Stage',
  'unit' => 'Release unit',
  'gitTag' => 'Git tag',
  'pubDev' => 'pub.dev',
  'githubRelease' => 'GitHub',
  'homebrew' => 'Homebrew',
  _ => column,
};

(String, String, CellStyle) statusCell(StatusRow row, String column) {
  if (column == 'unit') {
    return (
      row.unit.name,
      '${row.unit.version.canonical}${row.complete?.sourceVersionAlreadyReleased == true
          ? ' · changed'
          : row.complete?.issues.isNotEmpty == true
          ? ' · !'
          : ''}',
      CellStyle(
        bold: true,
        foreground: row.complete?.issues.isNotEmpty == true ? warning : null,
      ),
    );
  }
  if (column == 'stage') {
    final stage = row.stage;
    if (stage == null) return ('Checking…', '', mutedText);
    final label = switch (stage.verdict) {
      Verdict.exact => '✓ Staged',
      Verdict.absent =>
        row.complete?.stage?.incomplete == true ? 'Incomplete' : 'Not staged',
      Verdict.conflict => '! Invalid',
      Verdict.unknown => '! Unreadable',
    };
    return (
      label,
      '',
      stage.isExact
          ? positiveText
          : stage.isAbsent
          ? mutedText
          : attentionText,
    );
  }
  final plans = row.plans.where((p) => p.kind == column).toList();
  final read = plans.map((p) => row.targets[p.step.id]).nonNulls.toList();
  if (plans.isEmpty) return ('—', '', mutedText);
  if (read.length < plans.length) {
    return (
      'Checking…',
      plans.length > 1 ? '${read.length}/${plans.length} checked' : '',
      mutedText,
    );
  }
  final exact = read.where((t) => t.inspection.isExact).length;
  final unread = read.any(
    (t) => t.inspection.verdict == Verdict.unknown || !t.currentKnown,
  );
  final conflict = read.any((t) => t.inspection.verdict == Verdict.conflict);
  final label = conflict
      ? '! Differs'
      : unread
      ? '! Check failed'
      : exact == plans.length
      ? '✓ Published'
      : exact > 0
      ? '$exact/${plans.length} published'
      : 'Not published';
  final version = read.length == 1
      ? read.single.currentKnown
            ? (read.single.currentVersion == null
                  ? 'No release'
                  : 'Latest ${read.single.currentVersion}')
            : 'Version unknown'
      : '${read.length} packages';
  return (
    label,
    version,
    conflict || unread
        ? attentionText
        : exact == plans.length
        ? positiveText
        : mutedText,
  );
}

String _issuesText(Iterable<StatusIssue> issues, {String? warning}) => [
  if (warning != null) 'Warning: $warning\n',
  for (final issue in issues)
    [
      '${issue.unit == null ? '' : '${issue.unit} · '}${issue.diagnostic.message}',
      for (final e in issue.evidence.entries) '${e.key}: ${e.value}',
      if (issue.diagnostic.evidence != null) issue.diagnostic.evidence!,
      if (issue.diagnostic.remedy != null) 'Fix: ${issue.diagnostic.remedy}',
    ].join('\n'),
].join('\n\n');

String statusDetails(StatusRow row, String column, StatusSnapshot? snapshot) {
  final targets = column == 'unit'
      ? row.plans
      : row.plans.where((p) => p.kind == column);
  final issues =
      snapshot?.issues.where(
        (i) => i.unit == null || i.unit == row.unit.name,
      ) ??
      row.complete?.issues ??
      [];
  final relevant = column == 'unit'
      ? issues
      : issues.where(
          (i) => column == 'stage'
              ? i.target == null
              : targets.any((p) => p.step.id == i.target),
        );
  return [
    'Candidate: ${row.unit.version.canonical}',
    if (column == 'unit')
      'Packages: ${row.unit.projects.map((p) => p.name).join(', ')}',
    if (column == 'unit' || column == 'stage') ...[
      'Stage: ${row.stage?.detail ?? 'Checking…'}',
      if (row.complete?.stage?.receipt case final receipt?)
        'Stage ID: ${receipt.identity.id}',
      for (final target in row.complete?.targets ?? <TargetObservation>[])
        for (final artifact in target.artifacts)
          '${artifact.name} · ${artifact.status.name}${artifact.problem == null ? '' : '\n${artifact.problem}'}',
      if (row.complete?.stage?.receipt case final receipt?)
        for (final step in receipt.steps)
          for (final artifact in step.outputs)
            if (row.plans.isEmpty) artifact.path,
    ],
    for (final plan in targets) ...[
      '',
      '${plan.kindLabel} · ${plan.coordinate}',
      'Candidate: ${plan.targetVersion}',
      if (row.targets[plan.step.id] case final observed?) ...[
        'Published: ${observed.currentKnown ? observed.currentVersion ?? 'None' : 'Unknown'}',
        'Result: ${observed.inspection.verdict.name}',
        if (observed.inspection.detail != null) observed.inspection.detail!,
        if (observed.currentDetail != null &&
            observed.currentDetail != observed.inspection.detail)
          observed.currentDetail!,
        for (final e in observed.inspection.evidence.entries)
          '${e.key}: ${e.value}',
        if (column != 'unit')
          for (final artifact in observed.artifacts)
            '${artifact.name} · ${artifact.status.name}${artifact.problem == null ? '' : '\n${artifact.problem}'}',
      ] else
        'Checking this destination…',
    ],
    if (relevant.isNotEmpty) '\n${_issuesText(relevant)}',
    if (column == 'unit' && snapshot?.warning != null)
      '\nWarning: ${snapshot!.warning!.message}',
    if (column == 'unit' &&
        snapshot?.nextUnit == row.unit.name &&
        snapshot?.nextCommand != null)
      '\nNext: ${snapshot!.nextCommand}\nRelease rechecks prerequisites before publishing.',
  ].join('\n');
}
