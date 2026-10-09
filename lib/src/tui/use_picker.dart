import 'dart:async';

import 'package:fleury/fleury.dart';

import '../engine/version.dart';
import '../installations/manager.dart';
import '../installations/model.dart';
import '../installations/provider.dart';
import '../output/output.dart' show terminalSafeText;
import 'matrix.dart';
import 'terminal.dart';

typedef SourceKey = (String, InstallationSource);

class AvailableState {
  bool checking = false;
  AvailableInstallation? release;
  String? error;
  InstallationCancellation? request;
}

/// Local inspection, remote checks, and mutations have independent lifetimes.
/// Checks never block selection and cannot replace installed state on failure.
/// The picker runs one operation at a time, matching the manager's lock;
/// checks and navigation stay live while one runs.
class UsePicker extends Notifier {
  UsePicker({
    required this.states,
    required this.refresh,
    required Future<AvailableInstallation> Function(
      ExecutableProject,
      InstallationSource,
      InstallationCancellation,
    )
    check,
    required this.perform,
    required this.close,
    this.command = 'rk use',
  }) : _check = check;
  List<ProjectInstallations> states;
  final Future<List<ProjectInstallations>> Function() refresh;
  final Future<AvailableInstallation> Function(
    ExecutableProject,
    InstallationSource,
    InstallationCancellation,
  )
  _check;
  final Future<String> Function(Operation, void Function(String)) perform;

  /// The command that opened the table: bare install and uninstall open it too.
  final String command;
  (ProjectInstallations, InstallationSource)? removal;
  final void Function() close;
  final available = <SourceKey, AvailableState>{};
  final _queue = <SourceKey, (Operation, Completer<void>)>{};
  Operation? _active;
  bool get busy => _queue.isNotEmpty;
  bool failed = false, closing = false, _disposed = false;
  String message = '';
  ({String title, String body})? details;
  final outcomes = <String>[];

  bool isPending(ProjectInstallations state, InstallationSource source) =>
      _queue.containsKey((state.project.name, source));

  String? operationLabel(
    ProjectInstallations state,
    InstallationSource source,
  ) {
    final queued = _queue[(state.project.name, source)];
    if (queued == null) return null;
    return queued.$1 == _active ? _wording(queued.$1).status : 'Queued';
  }

  /// What an operation is called on its row and in the footer while it runs,
  /// and when it fails.
  ({String status, String footer, String failure}) _wording(
    Operation operation,
  ) {
    final source = operation.source.label;
    final verb =
        states
                .where((s) => s.project.name == operation.project.name)
                .firstOrNull
                ?.sources[operation.source]
                ?.installation ==
            null
        ? 'Installing'
        : 'Updating';
    return switch (operation.action) {
      InstallationAction.use => (
        status: 'Switching…',
        footer: 'Switching to $source…',
        failure: 'Could not switch source',
      ),
      InstallationAction.install => (
        status: '$verb…',
        footer: '$verb $source ${operation.release!.version}…',
        failure: 'Could not complete installation',
      ),
      InstallationAction.uninstall => (
        status: 'Removing…',
        footer: 'Removing $source…',
        failure: 'Could not remove installation',
      ),
    };
  }

  bool canChoose(ProjectInstallations state, InstallationSource source) =>
      !closing && !_disposed && !isPending(state, source);

  AvailableState availability(
    ProjectInstallations state,
    InstallationSource source,
  ) => available.putIfAbsent((state.project.name, source), AvailableState.new);

  void checkAll() {
    if (closing || _disposed) return;
    for (final state in states) {
      for (final source in state.sources.keys.where(
        (s) => s != InstallationSource.local,
      )) {
        unawaited(check(state, source));
      }
    }
  }

  Future<void> check(
    ProjectInstallations state,
    InstallationSource source,
  ) async {
    if (_disposed || closing) return;
    final result = availability(state, source);
    result.request?.cancel();
    final request = result.request = InstallationCancellation();
    result.checking = true;
    result.error = null;
    notify();
    try {
      final release = await _check(state.project, source, request);
      if (!_disposed && !request.cancelled) result.release = release;
    } on Object catch (error) {
      if (!_disposed && !request.cancelled) result.error = _describe(error);
    } finally {
      if (!_disposed && !request.cancelled) {
        result.checking = false;
        notify();
      }
    }
  }

  bool canDownload(ProjectInstallations state, InstallationSource source) {
    final result = availability(state, source);
    if (!canChoose(state, source) ||
        result.checking ||
        result.error != null ||
        result.release == null ||
        state.sources[source]?.problem != null) {
      return false;
    }
    final installed = state.sources[source]?.installation;
    if (installed == null) return true;
    final current = Version.tryParse(installed.version);
    final next = Version.tryParse(result.release!.version);
    return current != null && next != null && next.compareTo(current) > 0;
  }

  /// Whether the project's commands already run [source]: for Local, from
  /// this checkout.
  bool isDefault(ProjectInstallations state, InstallationSource source) =>
      state.currentSource == source &&
      (source != InstallationSource.local ||
          (state.sources[source]!.installation?.checkout ??
                  state.sources[source]!.installation?.location) ==
              state.project.directory);

  bool canUse(ProjectInstallations state, InstallationSource source) =>
      canChoose(state, source) &&
      (source == InstallationSource.local || !isDefault(state, source)) &&
      state.sources[source]!.problem == null &&
      (source == InstallationSource.local ||
          state.sources[source]!.installation != null);

  Future<void> choose(
    ProjectInstallations state,
    InstallationSource source,
  ) async {
    if (canUse(state, source)) {
      await _run(Operation(state.project, source, InstallationAction.use));
    }
  }

  Future<void> download(
    ProjectInstallations state,
    InstallationSource source,
  ) async {
    if (!canDownload(state, source)) return;
    await _run(
      Operation(
        state.project,
        source,
        InstallationAction.install,
        release: availability(state, source).release,
      ),
    );
  }

  bool canUninstall(ProjectInstallations state, InstallationSource source) =>
      canChoose(state, source) &&
      state.sources[source]?.installation != null &&
      state.selected != source &&
      !state.currentSources.values.contains(source);

  void requestRemoval(ProjectInstallations state, InstallationSource source) {
    if (!canUninstall(state, source)) return;
    removal = (state, source);
    notify();
  }

  Future<void> confirmRemoval() async {
    final request = removal;
    if (request == null || !canUninstall(request.$1, request.$2)) return;
    removal = null;
    await _run(
      Operation(request.$1.project, request.$2, InstallationAction.uninstall),
    );
  }

  Future<void> _run(Operation operation) {
    final done = Completer<void>();
    _queue[(operation.project.name, operation.source)] = (operation, done);
    notify();
    if (_active == null) unawaited(_drain());
    return done.future;
  }

  Future<void> _drain() async {
    var switched = false;
    while (_queue.isNotEmpty && !closing && !_disposed) {
      final (operation, done) = _queue.values.first;
      _active = operation;
      final succeeded = await _perform(operation);
      // Only a switch closes a one-project picker.
      switched |= succeeded && operation.action == InstallationAction.use;
      _queue.remove((operation.project.name, operation.source));
      _active = null;
      done.complete();
      if (!_disposed) notify();
    }
    if (!_disposed &&
        (closing || (switched && !failed && states.length == 1))) {
      close();
    }
  }

  Future<bool> _perform(Operation operation) async {
    final wording = _wording(operation);
    failed = false;
    message = wording.footer;
    notify();
    void progress(String value) {
      if (!closing) message = value;
      if (!_disposed) notify();
    }

    try {
      message = await perform(operation, progress);
      outcomes.add(message);
    } on Object catch (error) {
      failed = true;
      message = _describe(error);
    }
    // A final single-project switch needs no further scan before restoring the
    // terminal. Queued operations must still drain before a successful close.
    if (closing ||
        _disposed ||
        (!failed &&
            operation.action == InstallationAction.use &&
            states.length == 1 &&
            _queue.length == 1)) {
      return !failed;
    }
    var failureTitle = wording.failure;
    try {
      states = await refresh();
    } on Object catch (error) {
      failed = true;
      failureTitle = 'Could not refresh installations';
      message += '\nCould not refresh installations: ${_describe(error)}';
    }
    if (failed && !closing) {
      if (_queue.length > 1) message += '\nQueued actions cancelled.';
      removal = null;
      details = (title: failureTitle, body: message);
      // Resolve a failure before starting another queued mutation.
      _cancelQueued();
    }
    if (!_disposed) notify();
    return !failed;
  }

  void _cancelQueued() {
    for (final (operation, done) in _queue.values.toList()) {
      if (operation == _active) continue;
      operation.cancellation.cancel();
      _queue.remove((operation.project.name, operation.source));
      done.complete();
    }
  }

  void exit() {
    if (removal != null) {
      removal = null;
      notify();
      return;
    }
    if (details != null) {
      details = null;
      notify();
      return;
    }
    if (busy) {
      closing = true;
      _cancelQueued();
      _active?.cancellation.cancel();
      message = 'Finishing the current operation safely before closing.';
      notify();
    } else {
      close();
    }
  }

  void interrupt() {
    removal = null;
    details = null;
    exit();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelQueued();
    _active?.cancellation.cancel();
    for (final entry in available.values) {
      entry.request?.cancel();
    }
    super.dispose();
  }
}

String _describe(Object error) {
  if (error is! Exception) return '$error';
  final failure = installationFailure(error);
  return '${failure.message} ${failure.remedy}'.trim();
}

/// Runs the picker until it closes. [failure] is the last operation's error
/// when it closed on one.
Future<({int exitCode, String? failure})> runUsePicker({
  required List<ProjectInstallations> states,
  required Future<List<ProjectInstallations>> Function() refresh,
  required Future<AvailableInstallation> Function(
    ExecutableProject,
    InstallationSource,
    InstallationCancellation,
  )
  check,
  required Future<String> Function(Operation, void Function(String)) perform,
  String command = 'rk use',
}) async {
  final model = UsePicker(
    command: command,
    states: states,
    refresh: refresh,
    check: check,
    perform: perform,
    close: exitApp,
  );
  try {
    final code = await runMatrixScreen(
      UseScreen(model),
      interrupt: model.interrupt,
      mouse: true,
    );
    return (exitCode: code, failure: model.failed ? model.message : null);
  } finally {
    model.dispose();
  }
}

class UseScreen extends StatefulWidget {
  const UseScreen(this.model, {super.key});
  final UsePicker model;
  @override
  State<UseScreen> createState() => _UseScreenState();
}

enum _SourceAction { download, use, remove }

typedef _ActionKey = (SourceKey, _SourceAction);

/// What one source's row shows and offers, worked out once for focus order,
/// rendering and taps. [status] is a queued or running operation, shown in
/// place of Use. An action without a callback shows disabled, and navigation
/// skips it.
typedef _Row = ({
  String installed,
  String available,
  bool newer,
  String? status,
  Map<_SourceAction, (String, void Function()?)> actions,
});

class _UseScreenState extends State<UseScreen> {
  UsePicker get model => widget.model;
  final _actions = <_ActionKey, FocusNode>{};
  final _scroll = ScrollController();
  final _doneFocus = FocusNode();
  _ActionKey? _focused;
  bool _overlay = false;
  @override
  void initState() {
    super.initState();
    TuiBinding.of(context).addPostFrameCallback((_) {
      if (mounted) model.checkAll();
    });
  }

  @override
  void dispose() {
    for (final node in _actions.values) {
      node.dispose();
    }
    _scroll.dispose();
    _doneFocus.dispose();
    super.dispose();
  }

  _Row _row(ProjectInstallations state, InstallationSource source) {
    final inspection = state.sources[source]!;
    final installation = inspection.installation;
    final result = model.availability(state, source);
    final local = source == InstallationSource.local;
    final status = model.operationLabel(state, source);
    return (
      installed: local
          ? (installation != null &&
                    (installation.checkout ?? installation.location) !=
                        state.project.directory
                ? 'Other checkout'
                : installation?.checkout != null
                ? '${installation!.version} compiled'
                : 'This checkout')
          : installation?.version ??
                (inspection.problem == null ? 'Not installed' : 'Unavailable'),
      available: local
          ? '—'
          : result.checking
          ? 'Checking…'
          : result.error != null
          ? 'Check failed'
          : result.release?.version ?? 'Checking…',
      newer: model.canDownload(state, source) && installation != null,
      status: status,
      actions: {
        if (model.canChoose(state, source) &&
            !local &&
            inspection.problem == null &&
            (result.error != null || model.canDownload(state, source)))
          _SourceAction.download: result.error != null
              ? ('Retry', () => unawaited(model.check(state, source)))
              : (
                  installation == null ? 'Install' : 'Update',
                  () => unawaited(model.download(state, source)),
                ),
        // A problem that blocks Use offers Remove in its place.
        if (status == null && (local || !model.isDefault(state, source)))
          if (inspection.problem != null && model.canUninstall(state, source))
            _SourceAction.remove: (
              'Remove',
              () => model.requestRemoval(state, source),
            )
          else
            _SourceAction.use: (
              local && model.isDefault(state, source) ? 'Rebuild' : 'Use',
              model.canUse(state, source)
                  ? () => unawaited(model.choose(state, source))
                  : null,
            ),
      },
    );
  }

  /// The row's actions that do something, in focus order.
  List<_ActionKey> _choices(
    ProjectInstallations state,
    InstallationSource source,
  ) => [
    for (final MapEntry(key: action, value: (_, onPressed)) in _row(
      state,
      source,
    ).actions.entries)
      if (onPressed != null) ((state.project.name, source), action),
  ];

  void _removeFocused() {
    final key = _focused?.$1;
    if (key == null) return;
    final state = model.states
        .where((s) => s.project.name == key.$1)
        .firstOrNull;
    if (state != null) model.requestRemoval(state, key.$2);
  }

  _ActionKey? get _current =>
      _actions.entries.where((entry) => entry.value.hasFocus).firstOrNull?.key;

  void _moveSource(int direction) {
    if (model.closing) return;
    final rows = [
      for (final state in model.states)
        for (final source in state.sources.keys)
          if (_choices(state, source) case final choices
              when choices.isNotEmpty)
            choices,
    ];
    if (rows.isEmpty) return;
    final current = _current;
    final index = rows.indexWhere((row) => row.first.$1 == current?.$1);
    final next = index < 0
        ? (direction > 0 ? 0 : rows.length - 1)
        : (index + direction).clamp(0, rows.length - 1);
    final choices = rows[next];
    // Prefer Use on entry, retain the same action when moving between sources.
    final target =
        choices.where((key) => key.$2 == current?.$2).firstOrNull ??
        choices.last;
    _actions[target]?.requestFocus();
  }

  void _moveAction(int direction) {
    if (model.closing) return;
    final current = _current;
    if (current == null) return;
    final state = model.states.singleWhere(
      (s) => s.project.name == current.$1.$1,
    );
    final choices = _choices(state, current.$1.$2);
    if (choices.isEmpty) return;
    final index = choices.indexOf(current);
    final next = (index + direction).clamp(0, choices.length - 1);
    _actions[choices[next]]?.requestFocus();
  }

  List<KeyBinding> _navigation() => [
    KeyBinding(KeySequence.down, onTrigger: (_) => _moveSource(1)),
    KeyBinding(KeySequence.up, onTrigger: (_) => _moveSource(-1)),
    KeyBinding(KeySequence.left, onTrigger: (_) => _moveAction(-1)),
    KeyBinding(KeySequence.right, onTrigger: (_) => _moveAction(1)),
    KeyBinding(KeySequence.u, onTrigger: (_) => _removeFocused()),
    KeyBinding(KeySequence.r, onTrigger: (_) => model.checkAll()),
  ];

  /// A row's action button. Focus is keyed by the kind of action: when Use
  /// turns into Remove, focus drops instead of moving Enter to Remove.
  Widget? _action(
    ProjectInstallations state,
    InstallationSource source,
    _Row row,
    _SourceAction action,
  ) {
    final (text, onPressed) = row.actions[action] ?? (null, null);
    if (text == null) return null;
    final key = ((state.project.name, source), action);
    return FocusDetector(
      key: ValueKey(key),
      onFocusChange: (focused) {
        if (focused) setState(() => _focused = key);
      },
      child: MatrixButton(
        focusNode: _actions.putIfAbsent(key, FocusNode.new),
        text: text,
        onPressed: onPressed,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    context.listen(model);
    final current = _current;
    if (current != null) {
      final state = model.states
          .where((s) => s.project.name == current.$1.$1)
          .firstOrNull;
      if (state == null || !_choices(state, current.$1.$2).contains(current)) {
        _actions[current]?.unfocus();
      }
    }
    if (_overlay && model.details == null && model.removal == null) {
      TuiBinding.of(context).addPostFrameCallback((_) {
        if (!mounted) return;
        final node = _actions[_focused];
        if (node != null && node.canRequestFocus) {
          node.requestFocus();
        } else {
          _doneFocus.requestFocus();
        }
      });
    }
    _overlay = model.details != null || model.removal != null;
    if (model.removal case (final state, final source)) {
      final installed = state.sources[source]!.installation!;
      return MatrixDetails(
        command: model.command,
        maxWidth: commandTableWidth,
        title: 'Remove ${state.project.label} from ${source.label}?',
        body: [
          'Version: ${installed.version}',
          'Location: ${installed.location}',
          'Commands: ${state.project.commands.join(', ')}',
          '',
          source == InstallationSource.local
              ? 'Compiled local copies are removed. Your checkout stays.'
              : 'This removes the ${source.label} installation, including its use outside this repository.',
        ].join('\n'),
        onBack: model.exit,
        actions: [
          MatrixButton(text: 'Cancel', autofocus: true, onPressed: model.exit),
          MatrixButton(
            text: 'Remove installation',
            variant: ButtonVariant.error,
            onPressed: () => unawaited(model.confirmRemoval()),
          ),
        ],
      );
    }
    if (model.details case final details?) {
      return MatrixDetails(
        command: model.command,
        maxWidth: commandTableWidth,
        title: details.title,
        body: details.body,
        failed: model.failed,
        onBack: model.exit,
      );
    }
    return KeyBindings(
      bindings: _navigation(),
      child: MatrixShell(
        command: model.command,
        maxWidth: commandTableWidth,
        count: model.states.length == 1
            ? model.states.single.project.name
            : '${model.states.length} projects',
        subtitle:
            'Choose what runs locally. Install or update without switching.',
        onEscape: model.exit,
        scrollController: _scroll,
        message: model.message.isNotEmpty
            ? model.message
            : _focused == null
            ? ''
            : model.available[_focused?.$1]?.error ?? '',
        failed: model.failed,
        positive: model.outcomes.isNotEmpty && !model.failed && !model.busy,
        hint: '↑↓ source · ←→ action · Tab move · Enter activate',
        actions: [
          for (final state in model.states)
            if (_focused?.$1.$1 == state.project.name &&
                model.canUninstall(state, _focused!.$1.$2))
              MatrixButton(
                text:
                    'u Uninstall ${model.states.length > 1 ? '${state.project.name} · ' : ''}${_focused!.$1.$2.label}',
                appearance: ButtonAppearance.plain,
                onPressed: _removeFocused,
              ),
          MatrixButton(
            text: 'r Refresh',
            appearance: ButtonAppearance.plain,
            onPressed: model.closing ? null : model.checkAll,
          ),
          MatrixButton(
            focusNode: _doneFocus,
            text: model.busy ? 'Esc Cancel' : 'Esc Done',
            appearance: ButtonAppearance.plain,
            onPressed: model.exit,
          ),
        ],
        // Action navigation must run before the viewport's spatial traversal.
        child: KeyBindings(
          bindings: _navigation(),
          child: LayoutBuilder(
            builder: (_, constraints) {
              final wide = (constraints.maxCols ?? 100) >= 76;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final state in model.states) ...[
                    if (model.states.length > 1)
                      Text(
                        terminalSafeText(state.project.label),
                        style: const CellStyle(bold: true),
                      ),
                    if (wide)
                      const Row(
                        children: [
                          SizedBox(
                            width: 13,
                            child: Text('Source', style: mutedText),
                          ),
                          SizedBox(
                            width: 21,
                            child: Text('Installed', style: mutedText),
                          ),
                          Expanded(child: Text('Available', style: mutedText)),
                          SizedBox(width: 15),
                        ],
                      ),
                    const MatrixRule(),
                    for (final source in state.sources.keys) ...[
                      _layout(state, source, wide),
                      if (state.sources[source]?.problem case final problem?)
                        Padding(
                          padding: const EdgeInsets.only(left: 2),
                          child: Text(
                            problem
                                .split('\n')
                                .map(terminalSafeText)
                                .join('\n'),
                            style: mutedText,
                          ),
                        ),
                      const MatrixRule(),
                    ],
                    for (final issue in state.routing)
                      Text(
                        terminalSafeText(issue),
                        style: const CellStyle(foreground: warning),
                      ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// Lays out a row: Source, Installed, Available with its download action,
  /// and Use, Remove, the operation's status or ✓ Default.
  Widget _layout(
    ProjectInstallations state,
    InstallationSource source,
    bool wide,
  ) {
    final row = _row(state, source);
    final active = state.currentSource == source;
    final selected = state.selected == source;
    Widget useButton() => SizedBox(
      width: 15,
      child: row.status != null
          ? Text(row.status!, textAlign: TextAlign.center, style: mutedText)
          : model.isDefault(state, source)
          ? const Text(
              '✓ Default',
              textAlign: TextAlign.center,
              style: selectedStyle,
            )
          : _action(state, source, row, _SourceAction.use) ??
                _action(state, source, row, _SourceAction.remove),
    );
    Widget availability() => Row(
      children: [
        Expanded(
          child: Text(
            terminalSafeText(row.available),
            style: row.newer ? const CellStyle(foreground: warning) : mutedText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        SizedBox(
          width: 17,
          child: _action(
            state,
            source,
            row,
            source == InstallationSource.local && model.isDefault(state, source)
                ? _SourceAction.use
                : _SourceAction.download,
          ),
        ),
      ],
    );
    Widget sourceLabel() => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(source.label, style: const CellStyle(bold: true)),
        if (selected && !active)
          const Text('Selected', style: CellStyle(foreground: warning)),
      ],
    );
    final use = ((state.project.name, source), _SourceAction.use);
    return GestureDetector(
      // Blank row space previews Use without running it. Only buttons own focus.
      onTap: row.actions[_SourceAction.use]?.$2 == null
          ? null
          : () => _actions[use]?.requestFocus(),
      child: DefaultTextStyle(
        style: active ? selectedStyle : const CellStyle(),
        child: Container(
          color: active ? const RgbColor(24, 55, 41) : null,
          child: wide
              ? Row(
                  children: [
                    SizedBox(width: 13, child: sourceLabel()),
                    SizedBox(
                      width: 21,
                      child: Text(terminalSafeText(row.installed), maxLines: 1),
                    ),
                    Expanded(child: availability()),
                    const SizedBox(width: 1),
                    useButton(),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(child: sourceLabel()),
                        useButton(),
                      ],
                    ),
                    Text(
                      'Installed  ${terminalSafeText(row.installed)}',
                      style: mutedText,
                    ),
                    Row(
                      children: [
                        const Text('Available  ', style: mutedText),
                        Expanded(child: availability()),
                      ],
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
