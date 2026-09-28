import 'dart:async';

import 'package:fleury/fleury.dart';

import '../engine/version.dart';
import '../installations/manager.dart';
import '../installations/metadata.dart';
import '../installations/model.dart';
import '../installations/provider.dart';
import '../output/output.dart' show terminalSafeText;
import 'installation_picker.dart'
    show InstallationOperation, InstallationPickerResult, RemovalConfirmation;
import 'matrix.dart';
import 'terminal.dart';

typedef SourceKey = (String, InstallationSource);
typedef CheckAvailable =
    Future<AvailableInstallation> Function(
      ExecutableProject,
      InstallationSource,
      InstallationCheck,
    );
typedef DownloadAvailable =
    Future<String> Function(
      ExecutableProject,
      AvailableInstallation,
      void Function(String),
      InstallationCancellation,
    );

class AvailableState {
  bool checking = false;
  AvailableInstallation? release;
  String? error;
  InstallationCheck? request;
}

/// Local inspection, remote checks, and mutations have independent lifetimes.
/// Checks never block selection and cannot replace installed state on failure.
class UsePicker extends Notifier {
  UsePicker({
    required this.states,
    required this.refresh,
    required this.checkAvailable,
    required this.downloadAvailable,
    required this.use,
    required this.close,
    this.uninstall,
    this.sessionNote,
  });
  List<ProjectInstallations> states;
  final Future<List<ProjectInstallations>> Function() refresh;
  final CheckAvailable checkAvailable;
  final DownloadAvailable downloadAvailable;
  final InstallationOperation use;
  final InstallationOperation? uninstall;
  final String? sessionNote;
  (ProjectInstallations, InstallationSource)? removal;
  final void Function() close;
  final available = <SourceKey, AvailableState>{};
  // Keep the completed action in place until this picker closes. Repeated Enter
  // must never move from downloading an update to selecting its source.
  final downloaded = <SourceKey, String>{};
  SourceKey? pending;
  bool removing = false,
      downloading = false,
      busy = false,
      failed = false,
      closing = false,
      _disposed = false;
  String message = '';
  ({String title, String body})? details;
  InstallationCancellation? _cancel;
  final outcomes = <String>[];

  AvailableState availability(
    ProjectInstallations state,
    InstallationSource source,
  ) => available.putIfAbsent((state.project.name, source), AvailableState.new);

  void checkAll() {
    if (busy || _disposed) return;
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
    if (_disposed || busy) return;
    final result = availability(state, source);
    result.request?.cancel();
    final request = result.request = InstallationCheck();
    result.checking = true;
    result.error = null;
    notify();
    try {
      final release = await checkAvailable(state.project, source, request);
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
    if (busy ||
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

  Future<void> choose(
    ProjectInstallations state,
    InstallationSource source,
  ) async {
    if (busy) return;
    final inspection = state.sources[source]!;
    if (inspection.problem != null) {
      details = (
        title: '${state.project.label} · ${source.label}',
        body: inspection.problem!,
      );
      notify();
      return;
    }
    if (inspection.installation == null && source != InstallationSource.local) {
      message = 'Install ${source.label} before choosing Use.';
      notify();
      return;
    }
    if (state.currentSource == source &&
        (source != InstallationSource.local ||
            inspection.installation?.location == state.project.directory)) {
      // Already effective: keep its launcher intact. Done is a separate action.
      return;
    }
    await _run(state, source, null);
  }

  Future<void> download(
    ProjectInstallations state,
    InstallationSource source,
  ) async {
    if (!canDownload(state, source)) return;
    await _run(state, source, availability(state, source).release!);
  }

  bool canUninstall(ProjectInstallations state, InstallationSource source) =>
      !busy &&
      uninstall != null &&
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
    await _run(request.$1, request.$2, null, remove: true);
  }

  Future<void> _run(
    ProjectInstallations state,
    InstallationSource source,
    AvailableInstallation? release, {
    bool remove = false,
  }) async {
    busy = true;
    failed = false;
    downloading = release != null;
    removing = remove;
    pending = (state.project.name, source);
    _cancel = InstallationCancellation();
    message = remove
        ? 'Removing ${source.label}…'
        : release == null
        ? 'Switching to ${source.label}…'
        : '${state.sources[source]?.installation == null ? 'Installing' : 'Updating'} ${source.label} ${release.version}…';
    notify();
    void progress(String value) {
      if (!closing) message = value;
      if (!_disposed) notify();
    }

    try {
      message = remove
          ? await uninstall!(state.project, source, progress, _cancel!)
          : release == null
          ? await use(state.project, source, progress, _cancel!)
          : await downloadAvailable(state.project, release, progress, _cancel!);
      outcomes.add(message);
    } on Object catch (error) {
      failed = true;
      message = _describe(error);
    }
    // Once a single-project switch succeeds there is no table left to refresh.
    // In particular, never hold terminal restoration behind another brew scan.
    if (closing ||
        (!failed && !remove && release == null && states.length == 1)) {
      busy = false;
      pending = null;
      if (!_disposed) notify();
      close();
      return;
    }
    var failureTitle = remove
        ? 'Could not remove installation'
        : release == null
        ? 'Could not switch source'
        : 'Could not complete installation';
    try {
      states = await refresh();
    } on Object catch (error) {
      failed = true;
      failureTitle = 'Could not refresh installations';
      message += '\nCould not refresh installations: ${_describe(error)}';
    }
    if (!failed && release != null) {
      downloaded[(state.project.name, source)] = release.version;
    }
    if (!failed && remove) {
      downloaded.remove((state.project.name, source));
    }
    busy = false;
    pending = null;
    if (failed && !closing) {
      details = (title: failureTitle, body: message);
    }
    if (!_disposed) notify();
    if (closing ||
        (!failed && !remove && release == null && states.length == 1)) {
      close();
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
      _cancel?.cancel();
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
    for (final entry in available.values) {
      entry.request?.cancel();
    }
    super.dispose();
  }
}

String _describe(Object error) => error is InstallationFailure
    ? '${error.message} ${error.remedy}'.trim()
    : '$error';

Future<InstallationPickerResult> runUsePicker({
  required List<ProjectInstallations> states,
  required Future<List<ProjectInstallations>> Function() refresh,
  required CheckAvailable checkAvailable,
  required DownloadAvailable downloadAvailable,
  required InstallationOperation use,
  required InstallationOperation uninstall,
  String? sessionNote,
}) async {
  final model = UsePicker(
    states: states,
    refresh: refresh,
    checkAvailable: checkAvailable,
    downloadAvailable: downloadAvailable,
    use: use,
    uninstall: uninstall,
    sessionNote: sessionNote,
    close: exitApp,
  );
  try {
    final code = await runMatrixScreen(
      UseScreen(model),
      interrupt: model.interrupt,
    );
    return InstallationPickerResult(model.failed, model.message, code);
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

  bool _canUse(ProjectInstallations state, InstallationSource source) =>
      !model.busy &&
      !_isDefault(state, source) &&
      state.sources[source]!.problem == null &&
      (source == InstallationSource.local ||
          state.sources[source]!.installation != null);

  bool _isDefault(ProjectInstallations state, InstallationSource source) =>
      state.currentSource == source &&
      (source != InstallationSource.local ||
          state.sources[source]!.installation?.location ==
              state.project.directory);

  void _removeFocused() {
    final key = _focused?.$1;
    if (key == null) return;
    final state = model.states
        .where((s) => s.project.name == key.$1)
        .firstOrNull;
    if (state != null) model.requestRemoval(state, key.$2);
  }

  bool _downloaded(ProjectInstallations state, InstallationSource source) {
    final version = model.downloaded[(state.project.name, source)];
    return version != null &&
        state.sources[source]!.installation?.version == version &&
        model.availability(state, source).release?.version == version;
  }

  bool _canFocusDownload(
    ProjectInstallations state,
    InstallationSource source,
  ) =>
      !model.busy &&
      source != InstallationSource.local &&
      state.sources[source]!.problem == null &&
      (model.availability(state, source).error != null ||
          model.canDownload(state, source) ||
          _downloaded(state, source));

  List<_ActionKey> _choices(
    ProjectInstallations state,
    InstallationSource source,
  ) => [
    if (_canFocusDownload(state, source))
      ((state.project.name, source), _SourceAction.download),
    if (_canUse(state, source))
      ((state.project.name, source), _SourceAction.use),
    if (state.sources[source]!.problem != null &&
        model.canUninstall(state, source))
      ((state.project.name, source), _SourceAction.remove),
  ];

  _ActionKey? get _current =>
      _actions.entries.where((entry) => entry.value.hasFocus).firstOrNull?.key;

  void _moveSource(int direction) {
    if (model.busy) return;
    final rows = [
      for (final state in model.states)
        for (final source in state.sources.keys)
          if (_choices(state, source).isNotEmpty) _choices(state, source),
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
    if (model.busy) return;
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

  Widget _action(
    SourceKey source,
    _SourceAction action,
    Widget Function(FocusNode) builder,
  ) {
    final key = (source, action);
    return FocusDetector(
      key: ValueKey(key),
      onFocusChange: (focused) {
        if (focused) setState(() => _focused = key);
      },
      child: builder(_actions.putIfAbsent(key, FocusNode.new)),
    );
  }

  @override
  Widget build(BuildContext context) {
    context.listen(model);
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
    if (model.removal case final request?) {
      return RemovalConfirmation(
        project: request.$1.project,
        source: request.$2,
        installed: request.$1.sources[request.$2]!.installation!,
        command: 'rk use',
        maxWidth: commandTableWidth,
        onCancel: model.exit,
        onConfirm: () => unawaited(model.confirmRemoval()),
      );
    }
    if (model.details case final details?) {
      return MatrixDetails(
        command: 'rk use',
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
        command: 'rk use',
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
            onPressed: model.busy ? null : model.checkAll,
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
                  if (model.sessionNote case final note?)
                    Text(note, style: mutedText),
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
                      _row(state, source, wide),
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

  Widget _row(
    ProjectInstallations state,
    InstallationSource source,
    bool wide,
  ) {
    final key = (state.project.name, source);
    final inspection = state.sources[source]!;
    final result = model.availability(state, source);
    final local = source == InstallationSource.local;
    final active = state.currentSource == source;
    final selected = state.selected == source;
    final pending = model.pending == key;
    final installed = local
        ? (inspection.installation != null &&
                  inspection.installation!.location != state.project.directory
              ? 'Other checkout'
              : 'This checkout')
        : inspection.installation?.version ??
              (inspection.problem == null ? 'Not installed' : 'Unavailable');
    final useText = pending && !model.downloading
        ? (model.removing ? 'Removing…' : 'Switching…')
        : 'Use';
    final recoveryRemoval =
        inspection.problem != null &&
        (model.canUninstall(state, source) || (pending && model.removing));
    final availableText = local
        ? '—'
        : result.checking
        ? 'Checking…'
        : result.error != null
        ? 'Check failed'
        : result.release?.version ?? 'Checking…';
    final canDownload = model.canDownload(state, source);
    Widget downloadButton() => _action(
      key,
      _SourceAction.download,
      (node) => MatrixButton(
        focusNode: node,
        text: pending && model.downloading
            ? (inspection.installation == null ? 'Installing…' : 'Updating…')
            : result.error != null
            ? 'Retry'
            : _downloaded(state, source)
            ? '✓ Installed'
            : canDownload
            ? (inspection.installation == null ? 'Install' : 'Update')
            : inspection.installation?.version == result.release?.version &&
                  result.release != null
            ? '✓ Current'
            : (inspection.installation == null ? 'Install' : 'Update'),
        unavailable: !_canFocusDownload(state, source),
        onPressed: model.busy
            ? null
            : result.error != null
            ? () => unawaited(model.check(state, source))
            : _canFocusDownload(state, source)
            ? () => unawaited(model.download(state, source))
            : null,
      ),
    );
    Widget useButton() => SizedBox(
      width: 15,
      child: _isDefault(state, source)
          ? const Text(
              '✓ Default',
              textAlign: TextAlign.center,
              style: selectedStyle,
            )
          : _action(
              key,
              recoveryRemoval ? _SourceAction.remove : _SourceAction.use,
              (node) => MatrixButton(
                focusNode: node,
                text: recoveryRemoval
                    ? (pending ? 'Removing…' : 'Remove')
                    : useText,
                selected: false,
                onPressed: recoveryRemoval
                    ? (model.busy
                          ? null
                          : () => model.requestRemoval(state, source))
                    : _canUse(state, source)
                    ? () => unawaited(model.choose(state, source))
                    : null,
              ),
            ),
    );
    Widget availability() => Row(
      children: [
        Expanded(
          child: Text(
            terminalSafeText(availableText),
            style: canDownload && inspection.installation != null
                ? const CellStyle(foreground: warning)
                : mutedText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (!local && inspection.problem == null)
          SizedBox(width: 17, child: downloadButton()),
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
    return GestureDetector(
      // Blank row space previews Use without running it. Only buttons own focus.
      onTap: _canUse(state, source)
          ? () => _actions[(key, _SourceAction.use)]?.requestFocus()
          : null,
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
                      child: Text(terminalSafeText(installed), maxLines: 1),
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
                      'Installed  ${terminalSafeText(installed)}',
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
