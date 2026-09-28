import 'dart:async';

import 'package:fleury/fleury.dart';

import '../engine/version.dart';
import '../installations/manager.dart';
import '../installations/metadata.dart';
import '../installations/model.dart';
import '../installations/provider.dart';
import '../output/output.dart' show terminalSafeText;
import 'installation_picker.dart'
    show InstallationOperation, InstallationPickerResult;
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
  });
  List<ProjectInstallations> states;
  final Future<List<ProjectInstallations>> Function() refresh;
  final CheckAvailable checkAvailable;
  final DownloadAvailable downloadAvailable;
  final InstallationOperation use;
  final void Function() close;
  final available = <SourceKey, AvailableState>{};
  SourceKey? pending;
  bool downloading = false,
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
      message = 'Download ${source.label} before choosing Use.';
      notify();
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

  Future<void> _run(
    ProjectInstallations state,
    InstallationSource source,
    AvailableInstallation? release,
  ) async {
    busy = true;
    failed = false;
    downloading = release != null;
    pending = (state.project.name, source);
    _cancel = InstallationCancellation();
    message = release == null
        ? 'Switching to ${source.label}…'
        : 'Downloading ${source.label} ${release.version}…';
    notify();
    void progress(String value) {
      if (!closing) message = value;
      if (!_disposed) notify();
    }

    try {
      message = release == null
          ? await use(state.project, source, progress, _cancel!)
          : await downloadAvailable(state.project, release, progress, _cancel!);
      outcomes.add(message);
    } on Object catch (error) {
      failed = true;
      message = _describe(error);
    }
    // Once a single-project switch succeeds there is no table left to refresh.
    // In particular, never hold terminal restoration behind another brew scan.
    if (closing || (!failed && release == null && states.length == 1)) {
      busy = false;
      pending = null;
      if (!_disposed) notify();
      close();
      return;
    }
    try {
      states = await refresh();
    } on Object catch (error) {
      failed = true;
      message += '\nCould not refresh installations: ${_describe(error)}';
    }
    busy = false;
    pending = null;
    if (failed && !closing) {
      details = (
        title: release == null
            ? 'Could not switch source'
            : 'Could not complete download',
        body: message,
      );
    }
    if (!_disposed) notify();
    if (closing || (!failed && release == null && states.length == 1)) close();
  }

  void exit() {
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
}) async {
  final model = UsePicker(
    states: states,
    refresh: refresh,
    checkAvailable: checkAvailable,
    downloadAvailable: downloadAvailable,
    use: use,
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

class _UseScreenState extends State<UseScreen> {
  UsePicker get model => widget.model;
  final _rows = <SourceKey, FocusNode>{};
  final _scroll = ScrollController();
  SourceKey? _focused, _activeRow;
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
    for (final node in _rows.values) {
      node.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  void _move(int direction) {
    if (model.busy) return;
    final keys = [
      for (final state in model.states)
        for (final source in state.sources.keys) (state.project.name, source),
    ];
    final index = keys.indexOf(_focused ?? ('', InstallationSource.local));
    final next = index < 0
        ? (direction > 0 ? 0 : keys.length - 1)
        : (index + direction).clamp(0, keys.length - 1);
    _rows[keys[next]]?.requestFocus();
  }

  List<KeyBinding> _navigation() => [
    KeyBinding(KeySequence.down, onTrigger: (_) => _move(1)),
    KeyBinding(KeySequence.up, onTrigger: (_) => _move(-1)),
    KeyBinding(KeySequence.r, onTrigger: (_) => model.checkAll()),
    KeyBinding(
      KeySequence.enter,
      onTrigger: (event) {
        final row = _rows.entries
            .where((entry) => entry.value.hasFocus)
            .firstOrNull;
        if (row == null) {
          event.bubble();
          return;
        }
        final state = model.states.singleWhere(
          (s) => s.project.name == row.key.$1,
        );
        unawaited(model.choose(state, row.key.$2));
      },
    ),
  ];

  @override
  Widget build(BuildContext context) {
    context.listen(model);
    if (_overlay && model.details == null) {
      TuiBinding.of(context).addPostFrameCallback((_) {
        if (mounted) _rows[_focused]?.requestFocus();
      });
    }
    _overlay = model.details != null;
    if (model.details case final details?) {
      return MatrixDetails(
        command: 'rk use',
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
        count: model.states.length == 1
            ? model.states.single.project.name
            : '${model.states.length} projects',
        subtitle:
            'Use switches source. Download installs the available version.',
        onEscape: model.exit,
        scrollController: _scroll,
        message: model.message.isNotEmpty
            ? model.message
            : _focused == null
            ? ''
            : model.available[_focused]?.error ?? '',
        failed: model.failed,
        positive: model.outcomes.isNotEmpty && !model.failed && !model.busy,
        hint: '↑↓ rows · Tab actions · Enter choose',
        actions: [
          MatrixButton(
            text: 'r Refresh',
            appearance: ButtonAppearance.plain,
            onPressed: model.busy ? null : model.checkAll,
          ),
          MatrixButton(
            text: model.busy ? 'Esc Cancel' : 'Esc Done',
            appearance: ButtonAppearance.plain,
            onPressed: model.exit,
          ),
        ],
        // The table owns Up/Down before the enclosing viewport's spatial
        // traversal can skip rows whose Use action is disabled.
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
                    _TableRule(),
                    for (final source in state.sources.keys) ...[
                      _row(state, source, wide),
                      _TableRule(),
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
    final node = _rows.putIfAbsent(key, () => FocusNode(skipTraversal: true));
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
        : inspection.installation?.version ?? 'Not installed';
    final useText = pending && !model.downloading
        ? 'Switching…'
        : active
        ? '✓ Using'
        : selected
        ? '✓ Selected'
        : inspection.problem != null
        ? 'Why?'
        : 'Use';
    final availableText = local
        ? '—'
        : result.checking
        ? 'Checking…'
        : result.error != null
        ? 'Check failed'
        : result.release?.version ?? 'Checking…';
    final canDownload = model.canDownload(state, source);
    Widget downloadButton() => MatrixButton(
      text: pending && model.downloading
          ? (model.message.startsWith('Installing')
                ? 'Installing…'
                : 'Downloading…')
          : result.error != null
          ? 'Retry'
          : canDownload
          ? '↓ Download'
          : inspection.installation?.version == result.release?.version &&
                result.release != null
          ? '✓ Current'
          : '↓ Download',
      unavailable: !canDownload && result.error == null,
      onPressed: model.busy
          ? null
          : result.error != null
          ? () => unawaited(model.check(state, source))
          : canDownload
          ? () => unawaited(model.download(state, source))
          : null,
    );
    Widget useButton() => SizedBox(
      width: 15,
      child: MatrixButton(
        text: useText,
        selected: selected || active,
        onPressed:
            model.busy ||
                (!local &&
                    inspection.installation == null &&
                    inspection.problem == null)
            ? null
            : () => unawaited(model.choose(state, source)),
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
        if (!local) SizedBox(width: 17, child: downloadButton()),
      ],
    );
    return FocusDetector(
      key: ValueKey(key),
      onFocusChange: (focused) {
        setState(() {
          if (focused) {
            _focused = key;
            _activeRow = key;
          } else if (_activeRow == key) {
            _activeRow = null;
          }
        });
      },
      child: Focus(
        focusNode: node,
        skipTraversal: true,
        child: KeyBindings(
          bindings: [
            KeyBinding(
              KeySequence.enter,
              onTrigger: (_) {
                if (node.hasFocus) {
                  unawaited(model.choose(state, source));
                }
              },
            ),
          ],
          child: LayoutBuilder(
            builder: (context, _) {
              return MouseRegion(
                onEnter: model.busy ? null : node.requestFocus,
                child: GestureDetector(
                  onTap: model.busy ? null : node.requestFocus,
                  child: DefaultTextStyle(
                    style:
                        _activeRow == key &&
                            MediaQuery.colorModeOf(context) == ColorMode.none
                        ? const CellStyle(inverse: true)
                        : selected || active
                        ? selectedStyle
                        : const CellStyle(),
                    child: Container(
                      color: _activeRow == key
                          ? const RgbColor(42, 76, 108)
                          : selected || active
                          ? const RgbColor(24, 55, 41)
                          : null,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 0),
                        child: wide
                            ? Row(
                                children: [
                                  SizedBox(
                                    width: 13,
                                    child: Text(
                                      source.label,
                                      style: const CellStyle(bold: true),
                                    ),
                                  ),
                                  SizedBox(
                                    width: 21,
                                    child: Text(
                                      terminalSafeText(installed),
                                      maxLines: 1,
                                    ),
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
                                      Expanded(
                                        child: Text(
                                          source.label,
                                          style: const CellStyle(bold: true),
                                        ),
                                      ),
                                      useButton(),
                                    ],
                                  ),
                                  Text(
                                    'Installed  ${terminalSafeText(installed)}',
                                    style: mutedText,
                                  ),
                                  Row(
                                    children: [
                                      const Text(
                                        'Available  ',
                                        style: mutedText,
                                      ),
                                      Expanded(child: availability()),
                                    ],
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _TableRule extends StatelessWidget {
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (_, bounds) =>
        Text('─' * (bounds.maxCols ?? 80), style: mutedText, softWrap: false),
  );
}
