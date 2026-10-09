import 'model.dart';
import '../engine/version.dart';
import 'provider.dart';
import 'store.dart';

/// One change to a project's installations: what `rk use`, `rk install` and
/// `rk uninstall` ask for, and what the picker queues.
final class Operation {
  Operation(this.project, this.source, this.action, {this.release})
    : assert(release == null || action == InstallationAction.install);
  final ExecutableProject project;
  final InstallationSource source;
  final InstallationAction action;

  /// The checked version Install, Update and `--latest` install.
  final AvailableInstallation? release;
  final cancellation = InstallationCancellation();
}

class InstallationManager {
  InstallationManager({
    required this.store,
    required this.providers,
    required this.environment,
  });
  final InstallationStore store;
  final Map<InstallationSource, InstallationProvider> providers;
  final Map<String, String> environment;

  Future<ProjectInstallations> inspect(ExecutableProject project) async {
    final states = <InstallationSource, SourceInspection>{};
    for (final source in project.sources) {
      try {
        states[source] = await _provider(project, source).inspect(project);
      } on Exception catch (error) {
        states[source] = SourceInspection(
          problem: installationFailure(error).message,
        );
      }
    }
    // Each command runs what its own launcher names: another project's
    // launcher, or one left from an earlier selection, is not this selection.
    final launchers = store.launchers(project);
    final paths = {
      for (final command in project.commands)
        command: findExecutable(command, environment),
    };
    final current = <String, InstallationSource?>{};
    for (final entry in paths.entries) {
      current[entry.key] = store.routes(entry.key, environment)
          ? launchers[entry.key]?.source
          : states.entries
                .where(
                  (s) =>
                      entry.value != null &&
                      (s.value.installation?.exportedPaths.any(
                            (p) => sameFile(p, entry.value!),
                          ) ??
                          false),
                )
                .firstOrNull
                ?.key;
    }
    return ProjectInstallations(
      project,
      states,
      selected: launchers.values.firstOrNull?.source,
      resolvedCommands: paths,
      currentSources: current,
      routing: store.routingProblems(project, environment),
    );
  }

  Future<AvailableInstallation> latest(
    ExecutableProject project,
    InstallationSource source, {
    InstallationCancellation? check,
  }) async => _provider(project, source).latest(project, check: check);

  /// Performs [operation]. Callers run one at a time: the CLI runs one, and
  /// the picker queues them. install.lock keeps other processes out.
  Future<String> apply(
    Operation operation, {
    required void Function(String) progress,
  }) async {
    final Operation(:project, :source, :action, :release, :cancellation) =
        operation;
    final provider = _provider(project, source);
    final lock = store.lock();
    try {
      cancellation.check();
      final launchers = store.launchers(project).values;
      // Use selects the source; updating the selected source advances it,
      // and never selects another.
      final routes =
          action == InstallationAction.use ||
          (release != null && launchers.firstOrNull?.source == source);
      // Any of the project's commands may run it, not only the first.
      if (action == InstallationAction.uninstall &&
          launchers.any((l) => l.source == source)) {
        throw InstallationFailure(
          '${source.label} is selected for ${project.name}.',
          'Run rk use with another source first.',
        );
      }
      if (routes) store.checkOwnership(project);
      final inspected = await provider.inspect(project);
      var installation = inspected.installation;
      if (inspected.problem != null &&
          !(action == InstallationAction.uninstall && installation != null)) {
        throw InstallationFailure(inspected.problem!);
      }
      if (action == InstallationAction.uninstall) {
        if (installation == null) {
          return '${project.name} is not installed from ${source.label}.';
        }
        for (final command in project.commands) {
          final effective = findExecutable(command, environment);
          if (effective != null &&
              installation.exportedPaths.any(
                (path) => sameFile(path, effective),
              )) {
            throw InstallationFailure(
              '${source.label} currently provides $command on PATH.',
              'Select another source with rk use and update PATH before removing it.',
            );
          }
        }
        cancellation.check();
        progress('Removing ${project.name} from ${source.label}…');
        await provider.uninstall(project);
        return '${project.name} removed from ${source.label}.${source == InstallationSource.local ? ' Checkout kept.' : ''}';
      }
      if (release != null && installation != null) {
        if (installation.version == release.version && !routes) {
          return '${project.name} · ${source.label} ${release.version} is already installed. Source selection unchanged.';
        }
        final previous = Version.tryParse(installation.version);
        final next = Version.tryParse(release.version);
        if (previous != null && next != null && previous.compareTo(next) > 0) {
          throw const InstallationFailure(
            'A newer version is already installed.',
            'Refresh the table before downloading.',
          );
        }
      }
      // Local preparation rebinds this exact checkout and refreshes its native
      // dependency graph. Other installed providers are reused, never
      // upgraded. A checked release installs unless that version is there: an
      // update of the selected source that stopped before routing finishes.
      if (installation == null ||
          source == InstallationSource.local ||
          (release != null && installation.version != release.version)) {
        cancellation.check();
        installation = await provider.install(project, release, progress);
      }
      if (action == InstallationAction.install && release == null) {
        store.retire(project, installation);
        return source == InstallationSource.local &&
                installation.checkout == null
            ? '${project.name} prepared in this checkout. Selection unchanged.'
            : '${project.name} installed from ${source.label}. Selection unchanged.';
      }
      // A switch can be cancelled until its launchers are written. A package
      // manager may already have committed an update: its routing finishes
      // even when cancellation arrived meanwhile.
      if (routes) {
        await store.activate(
          project,
          installation,
          beforeCommit: release == null ? cancellation.check : null,
        );
      }
      store.retire(project, installation);
      if (release != null) {
        return '${project.name} · ${source.label} ${installation.version} installed. '
            '${routes ? 'Using it on the next command.' : 'Source selection unchanged.'}';
      }
      final path = await store.putFirstOnPath(project, environment);
      return [
        '${project.name} → ${source.label} · ${installation.version}${source == InstallationSource.local ? (installation.checkout == null ? ' · live source' : ' · compiled') : ''}',
        if (installation.checkout != null)
          'After source edits, run rk use local again to rebuild.',
        ?path,
      ].join('\n');
    } finally {
      lock.unlockSync();
      lock.closeSync();
    }
  }

  InstallationProvider _provider(
    ExecutableProject project,
    InstallationSource source,
  ) =>
      (project.sources.contains(source) ? providers[source] : null) ??
      (throw InstallationFailure(
        '${project.name} does not support ${source.label}.',
        'Available sources: ${project.sources.map((s) => s.name).join(', ')}.',
      ));
}
