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
  InstallationCancellation? _cancellation;
  (String, InstallationSource)? pending;

  void interrupt() {
    removal = null;
    exit();
  }

  void exit() {
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
      message = inspection.problem!;
      failed = true;
      notify();
      return;
    }
    if (action == InstallationAction.uninstall) {
      if (inspection.installation == null) return;
      if (state.selected == source ||
          state.currentSources.values.contains(source)) {
        message = 'Choose another source before removing ${source.label}.';
        failed = true;
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
    busy = true;
    pending = (project.name, source);
    failed = false;
    _cancellation = InstallationCancellation();
    message = 'Preparing ${project.name}…';
    notify();
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
        failed = true;
        message = error.message;
      } on Object catch (error) {
        failed = true;
        message = 'Could not refresh installations: $error';
      }
      busy = false;
      pending = null;
      notify();
      if (closing) close();
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

class InstallationScreen extends StatelessWidget {
  const InstallationScreen(this.model, {super.key});
  final InstallationPicker model;
  @override
  Widget build(BuildContext context) {
    context.listen(model);
    if (model.removal case final request?) {
      final (project, source) = request;
      final installed = model.states
          .singleWhere((s) => s.project == project)
          .sources[source]!
          .installation!;
      return MatrixShell(
        key: const ValueKey('removal'),
        command: 'rk uninstall',
        subtitle: 'Remove ${project.label} from ${source.label}?',
        onEscape: model.exit,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Version: ${installed.version}'),
            Text('Location: ${installed.location}'),
            const SizedBox(height: 1),
            Text(
              source == InstallationSource.local
                  ? 'Only the local registration is removed. Your checkout stays.'
                  : 'This removes the installation provided by ${source.label}.',
            ),
          ],
        ),
        actions: [
          Button(text: 'Cancel', autofocus: true, onPressed: model.exit),
          Button(
            text: 'Remove installation',
            variant: ButtonVariant.error,
            onPressed: () => unawaited(model.apply(project, source)),
          ),
        ],
      );
    }
    final sources = InstallationSource.values
        .where((s) => model.states.any((p) => p.sources.containsKey(s)))
        .toList();
    return MatrixShell(
      key: const ValueKey('sources'),
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
          : model.states.expand((s) => s.routing).join('\n'),
      failed: model.failed,
      child: ChoiceMatrix(
        columns: sources.map((s) => s.label).toList(),
        rows: [
          for (final state in model.states)
            MatrixRow(state.project.name, state.project.label, [
              for (final source in sources)
                if (!state.sources.containsKey(source))
                  null
                else
                  _cell(
                    state,
                    source,
                    model.states.first == state && sources.first == source,
                  ),
            ]),
        ],
      ),
      actions: [
        const Text('↑↓←→ move · Enter choose', style: mutedText),
        Button(
          text: model.busy ? 'Esc Cancel' : 'Esc Done',
          appearance: ButtonAppearance.plain,
          onPressed: model.exit,
        ),
      ],
    );
  }

  Widget _cell(
    ProjectInstallations state,
    InstallationSource source,
    bool autofocus,
  ) {
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
      title: title,
      detail: source == InstallationSource.local
          ? installed != null && installed.location != state.project.directory
                ? 'Other checkout'
                : 'This checkout'
          : installed?.version ??
                (inspection.problem != null ? 'View reason' : 'Latest release'),
      semanticLabel: '${state.project.label}, ${source.label}: $title',
      selected: selected || state.currentSource == source,
      autofocus: autofocus,
      onPressed: model.busy
          ? null
          : () => unawaited(model.choose(state, source)),
    );
  }
}
