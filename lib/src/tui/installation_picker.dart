import 'dart:async';
import 'package:fleury/fleury.dart';

import '../installations/model.dart';
import '../installations/manager.dart';
import 'matrix.dart';
import 'terminal.dart';

typedef InstallationOperation =
    Future<String> Function(
      ExecutableProject,
      InstallationSource,
      void Function(String),
      InstallationCancellation,
    );

class InstallationPicker extends Notifier {
  InstallationPicker({
    required this.action,
    required this.states,
    required this.refresh,
    required this.operate,
    required this.close,
  });
  final InstallationAction action;
  List<ProjectInstallations> states;
  final Future<List<ProjectInstallations>> Function() refresh;
  final InstallationOperation operate;
  final void Function() close;
  final List<String> outcomes = [];
  String message = '';
  bool busy = false, failed = false, closing = false;
  (ExecutableProject, InstallationSource)? removal;
  ({String title, String body, bool failed})? details;
  InstallationCancellation? _cancellation;
  (String, InstallationSource)? pending;

  void interrupt() {
    removal = null;
    details = null;
    exit();
  }

  void exit() {
    if (details != null) {
      details = null;
      notify();
      return;
    }
    if (removal != null) {
      removal = null;
      notify();
      return;
    }
    if (busy) {
      closing = true;
      _cancellation?.cancel();
      message = 'Finishing the current operation safely before closing.';
      notify();
      return;
    }
    close();
  }

  bool get isRemoval => action == InstallationAction.uninstall;

  Future<void> choose(
    ProjectInstallations state,
    InstallationSource source,
  ) async {
    if (busy) return;
    final inspection = state.sources[source]!;
    if (inspection.problem != null &&
        !(isRemoval && inspection.installation != null)) {
      details = (
        title: '${state.project.label} · ${source.label}',
        body: inspection.problem!,
        failed: false,
      );
      notify();
      return;
    }
    if (action == InstallationAction.uninstall) {
      if (inspection.installation == null) return;
      if (state.selected == source ||
          state.currentSources.values.contains(source)) {
        details = (
          title: '${source.label} is currently selected',
          body:
              'Choose another source with rk use before removing ${source.label}.',
          failed: false,
        );
        notify();
        return;
      }
      removal = (state.project, source);
      notify();
      return;
    }
    await apply(state.project, source);
  }

  Future<void> apply(
    ExecutableProject project,
    InstallationSource source,
  ) async {
    if (busy) return;
    removal = null;
    details = null;
    busy = true;
    pending = (project.name, source);
    failed = false;
    _cancellation = InstallationCancellation();
    message = 'Preparing ${project.name}…';
    notify();
    var failureTitle = 'Could not complete ${action.name}';
    try {
      message = await operate(project, source, (value) {
        if (!closing) message = value;
        notify();
      }, _cancellation!);
      outcomes.add(message);
    } on InstallationFailure catch (error) {
      failed = true;
      message = '${error.message} ${error.remedy}'.trim();
    } on Object catch (error) {
      failed = true;
      message = 'Installation failed unexpectedly: $error';
    } finally {
      try {
        states = await refresh();
      } on InstallationFailure catch (error) {
        failureTitle = 'Could not refresh installations';
        message =
            '$message\n\n'
                    '${error.message} ${error.remedy}'
                .trim();
        failed = true;
      } on Object catch (error) {
        failureTitle = 'Could not refresh installations';
        message =
            '$message\n\n'
            'Could not refresh installations: $error';
        failed = true;
      }
      busy = false;
      pending = null;
      if (failed && !closing) {
        details = (title: failureTitle, body: message, failed: true);
      }
      notify();
      if (closing || (!failed && states.length == 1)) close();
    }
  }
}

class InstallationPickerResult {
  InstallationPickerResult(this.failed, this.message, this.exitCode);
  final bool failed;
  final String message;
  final int exitCode;
}

Future<InstallationPickerResult> runInstallationPicker({
  required InstallationAction action,
  required List<ProjectInstallations> states,
  required Future<List<ProjectInstallations>> Function() refresh,
  required InstallationOperation operate,
}) async {
  final model = InstallationPicker(
    action: action,
    states: states,
    refresh: refresh,
    operate: operate,
    close: exitApp,
  );
  try {
    final code = await runMatrixScreen(
      InstallationScreen(model),
      interrupt: model.interrupt,
    );
    return InstallationPickerResult(model.failed, model.message, code);
  } finally {
    model.dispose();
  }
}

class InstallationScreen extends StatefulWidget {
  const InstallationScreen(this.model, {super.key});
  final InstallationPicker model;
  @override
  State<InstallationScreen> createState() => _InstallationScreenState();
}

class _InstallationScreenState extends State<InstallationScreen> {
  InstallationPicker get model => widget.model;
  final _scroll = ScrollController();
  final _cells = <(String, InstallationSource), FocusNode>{};
  FocusNode? _origin;
  bool _overlay = false;

  @override
  void dispose() {
    _scroll.dispose();
    for (final node in _cells.values) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    context.listen(model);
    final overlay = model.removal != null || model.details != null;
    if (_overlay && !overlay) {
      TuiBinding.of(context).addPostFrameCallback((_) {
        if (mounted &&
            model.removal == null &&
            model.details == null &&
            !model.busy) {
          _origin?.requestFocus();
        }
      });
    }
    _overlay = overlay;
    if (model.details case final details?) {
      return MatrixDetails(
        key: const ValueKey('details'),
        command: 'rk ${model.action.name}',
        title: details.title,
        body: details.body,
        failed: details.failed,
        onBack: model.exit,
      );
    }
    if (model.removal case final request?) {
      final (project, source) = request;
      final installed = model.states
          .singleWhere((s) => s.project == project)
          .sources[source]!
          .installation!;
      return RemovalConfirmation(
        project: project,
        source: source,
        installed: installed,
        onCancel: model.exit,
        onConfirm: () => unawaited(model.apply(project, source)),
      );
    }
    final sources = InstallationSource.values
        .where((s) => model.states.any((p) => p.sources.containsKey(s)))
        .toList();
    return MatrixShell(
      key: const ValueKey('sources'),
      scrollController: _scroll,
      command: 'rk ${model.action.name}',
      count:
          '${model.states.length} ${model.states.length == 1 ? 'project' : 'projects'}',
      onEscape: model.exit,
      subtitle: switch (model.action) {
        InstallationAction.use => 'Choose where your commands come from.',
        InstallationAction.install =>
          'Install a source. Keep your current selection.',
        InstallationAction.uninstall => 'Remove a source you no longer use.',
      },
      message: model.message.isNotEmpty
          ? model.message
          : model.states.any((s) => s.routing.isNotEmpty)
          ? model.action == InstallationAction.use
                ? 'Selection is not active on PATH. Choose a source to set it up.'
                : 'Selection is not active on PATH. Run rk use to set it up.'
          : '',
      failed:
          model.failed ||
          (model.message.isEmpty &&
              model.states.any((s) => s.routing.isNotEmpty)),
      positive:
          !model.busy &&
          !model.failed &&
          model.outcomes.isNotEmpty &&
          model.message == model.outcomes.last,
      hint: '↑↓←→ move · Enter choose',
      child: ChoiceMatrix(
        columns: sources.map((s) => s.label).toList(),
        rows: [
          for (final state in model.states)
            MatrixRow(
              state.project.name,
              state.project.label == state.project.name
                  ? ''
                  : 'Commands: ${state.project.label}',
              [
                for (final source in sources)
                  if (!state.sources.containsKey(source))
                    null
                  else
                    _cell(state, source),
              ],
            ),
        ],
      ),
      actions: [
        MatrixButton(
          text:
              model.busy || (model.states.length == 1 && model.outcomes.isEmpty)
              ? 'Esc Cancel'
              : 'Esc Done',
          appearance: ButtonAppearance.plain,
          onPressed: model.exit,
        ),
      ],
    );
  }

  Widget _cell(ProjectInstallations state, InstallationSource source) {
    final inspection = state.sources[source]!;
    final installed = inspection.installation;
    final selected = state.selected == source;
    final title = model.pending == (state.project.name, source)
        ? (model.action == InstallationAction.uninstall
              ? 'Removing…'
              : 'Preparing…')
        : inspection.problem != null && !(model.isRemoval && installed != null)
        ? 'Unavailable'
        : switch (model.action) {
            InstallationAction.use =>
              state.currentSource == source
                  ? '✓ Using'
                  : selected
                  ? '✓ Selected'
                  : installed == null
                  ? 'Install & use'
                  : 'Use',
            InstallationAction.install =>
              installed == null ? 'Install' : '✓ Installed',
            InstallationAction.uninstall =>
              selected
                  ? 'Selected'
                  : installed == null
                  ? 'Not installed'
                  : 'Remove',
          };
    return MatrixCell(
      focusNode: _cells.putIfAbsent((
        state.project.name,
        source,
      ), FocusNode.new),
      title: title,
      detail:
          inspection.problem != null && !(model.isRemoval && installed != null)
          ? 'View reason'
          : source == InstallationSource.local
          ? installed != null && installed.location != state.project.directory
                ? 'Other checkout'
                : 'This checkout'
          : installed?.version ??
                (inspection.problem != null ? 'View reason' : 'Latest release'),
      semanticLabel: '${state.project.label}, ${source.label}: $title',
      selected: model.action == InstallationAction.install
          ? installed != null
          : selected || state.currentSource == source,
      unavailable:
          inspection.problem != null || (model.isRemoval && installed == null),
      onPressed:
          model.busy ||
              (model.isRemoval &&
                  installed == null &&
                  inspection.problem == null)
          ? null
          : () {
              _origin = _cells[(state.project.name, source)];
              unawaited(model.choose(state, source));
            },
    );
  }
}

/// The same scoped confirmation is used from use and uninstall.
class RemovalConfirmation extends StatelessWidget {
  const RemovalConfirmation({
    super.key,
    required this.project,
    required this.source,
    required this.installed,
    required this.onCancel,
    required this.onConfirm,
    this.command = 'rk uninstall',
    this.maxWidth = 128,
  });
  final ExecutableProject project;
  final InstallationSource source;
  final Installation installed;
  final void Function() onCancel, onConfirm;
  final String command;
  final int maxWidth;
  @override
  Widget build(BuildContext context) => MatrixShell(
    command: command,
    maxWidth: maxWidth,
    subtitle: 'Remove ${project.label} from ${source.label}?',
    scrollFromActions: true,
    onEscape: onCancel,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Version: ${installed.version}'),
        Text('Location: ${installed.location}'),
        Text('Commands: ${project.commands.join(', ')}'),
        const SizedBox(height: 1),
        Text(
          source == InstallationSource.local
              ? 'Only the local registration is removed. Your checkout stays.'
              : 'This removes the ${source.label} installation, including its use outside this repository.',
        ),
      ],
    ),
    actions: [
      MatrixButton(text: 'Cancel', autofocus: true, onPressed: onCancel),
      MatrixButton(
        text: 'Remove installation',
        variant: ButtonVariant.error,
        onPressed: onConfirm,
      ),
    ],
  );
}
