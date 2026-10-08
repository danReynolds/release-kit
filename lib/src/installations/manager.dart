import 'dart:io';
import 'dart:async';

import 'model.dart';
import '../engine/version.dart';
import 'metadata.dart';
import 'provider.dart';
import 'store.dart';

class InstallationCancellation {
  bool requested = false;
  void cancel() => requested = true;
  void check() {
    if (requested) {
      throw const InstallationFailure(
        'Selection cancelled.',
        'Any completed installation was kept; the previous selection was not changed.',
      );
    }
  }
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
  bool _busy = false;

  Future<ProjectInstallations> inspect(ExecutableProject project) async {
    final states = <InstallationSource, SourceInspection>{};
    for (final source in project.sources) {
      final provider = providers[source];
      if (provider == null) {
        states[source] = const SourceInspection(
          problem: 'Provider unavailable in this build.',
        );
        continue;
      }
      try {
        states[source] = await _providerCall(() => provider.inspect(project));
      } on InstallationFailure catch (error) {
        states[source] = SourceInspection(problem: error.message);
      }
    }
    final selected = store.selected(project)?.source;
    final paths = {
      for (final command in project.commands)
        command: findExecutable(command, environment),
    };
    final current = <String, InstallationSource?>{};
    for (final entry in paths.entries) {
      current[entry.key] = entry.value == '${store.bin}/${entry.key}'
          ? selected
          : states.entries
                .where(
                  (s) =>
                      entry.value != null &&
                      (s.value.installation?.exportedPaths.any(
                            (p) => _sameFile(p, entry.value!),
                          ) ??
                          false),
                )
                .firstOrNull
                ?.key;
    }
    return ProjectInstallations(
      project,
      states,
      selected: selected,
      resolvedCommands: paths,
      currentSources: current,
      routing: store.routingProblems(project, environment),
    );
  }

  Future<AvailableInstallation> latest(
    ExecutableProject project,
    InstallationSource source, {
    InstallationCheck? check,
  }) async {
    final provider = providers[source];
    if (!project.sources.contains(source) || provider is! InstallationUpdates) {
      throw const InstallationFailure(
        'This source does not provide remote updates.',
      );
    }
    return _providerCall(
      () => (provider as InstallationUpdates).latest(project, check: check),
    );
  }

  Future<String> download(
    ExecutableProject project,
    AvailableInstallation release, {
    required void Function(String) progress,
    InstallationCancellation? cancellation,
  }) async {
    release.validate(project, release.source);
    final provider = providers[release.source];
    if (!project.sources.contains(release.source) ||
        provider is! InstallationUpdates) {
      throw const InstallationFailure(
        'This source does not provide downloads.',
      );
    }
    if (_busy) {
      throw const InstallationFailure(
        'An installation operation is already running.',
      );
    }
    final lock = store.lock();
    _busy = true;
    try {
      cancellation?.check();
      final current = store.selected(project)?.source;
      final inspected = await _providerCall(() => provider!.inspect(project));
      if (inspected.problem != null) {
        throw InstallationFailure(inspected.problem!);
      }
      final previousVersion = inspected.installation?.version;
      final previous = previousVersion == null
          ? null
          : Version.tryParse(previousVersion);
      final next = Version.tryParse(release.version);
      if (previousVersion == release.version) {
        return '${project.name} · ${release.source.label} ${release.version} is already installed. Source selection unchanged.';
      }
      if (previous != null && next != null && previous.compareTo(next) > 0) {
        throw const InstallationFailure(
          'A newer version is already installed.',
          'Refresh the table before downloading.',
        );
      }
      cancellation?.check();
      if (current == release.source) store.checkOwnership(project);
      final installed = await _providerCall(
        () => (provider as InstallationUpdates).download(
          project,
          release,
          progress,
        ),
      );
      if (installed.source != release.source ||
          installed.version != release.version) {
        throw const InstallationFailure(
          'The installed version differs from the checked release.',
          'Check the provider before retrying.',
        );
      }
      // A package manager may already have committed its update. Finish the
      // routing even when cancellation arrived meanwhile. Updating the selected
      // source advances that source, never selects another.
      if (current == release.source) await store.activate(project, installed);
      return '${project.name} · ${release.source.label} ${installed.version} installed. '
          '${current == release.source ? 'Using it on the next command.' : 'Source selection unchanged.'}';
    } finally {
      lock.unlockSync();
      lock.closeSync();
      _busy = false;
    }
  }

  Future<String> act(
    ExecutableProject project,
    InstallationSource source,
    InstallationAction action, {
    required void Function(String) progress,
    InstallationCancellation? cancellation,
  }) async {
    if (_busy) {
      throw const InstallationFailure(
        'An installation operation is already running.',
      );
    }
    if (!project.sources.contains(source)) {
      throw InstallationFailure(
        '${project.name} does not support ${source.label}.',
        'Available sources: ${project.sources.map((s) => s.name).join(', ')}.',
      );
    }
    final provider = providers[source];
    if (provider == null) {
      throw InstallationFailure(
        '${source.label} is unavailable in this build.',
      );
    }
    final lock = store.lock();
    _busy = true;
    try {
      cancellation?.check();
      if (action == InstallationAction.use) store.checkOwnership(project);
      if (action == InstallationAction.uninstall &&
          store.selected(project)?.source == source) {
        throw InstallationFailure(
          '${source.label} is selected for ${project.name}.',
          'Run rk use with another source first.',
        );
      }
      final inspected = await _providerCall(() => provider.inspect(project));
      if (inspected.problem != null &&
          !(action == InstallationAction.uninstall &&
              inspected.installation != null)) {
        throw InstallationFailure(inspected.problem!);
      }
      if (action == InstallationAction.uninstall) {
        final installation = inspected.installation;
        if (installation == null) {
          return '${project.name} is not installed from ${source.label}.';
        }
        for (final command in project.commands) {
          final effective = findExecutable(command, environment);
          if (effective != null &&
              installation.exportedPaths.any(
                (path) => _sameFile(path, effective),
              )) {
            throw InstallationFailure(
              '${source.label} currently provides $command on PATH.',
              'Select another source with rk use and update PATH before removing it.',
            );
          }
        }
        cancellation?.check();
        progress('Removing ${project.name} from ${source.label}…');
        await _providerCall(() => provider.uninstall(project, installation));
        return '${project.name} removed from ${source.label}.${source == InstallationSource.local ? ' Checkout kept.' : ''}';
      }
      // Local preparation rebinds this exact checkout and refreshes its native
      // dependency graph. Other installed providers are reused, never upgraded.
      final installation =
          source == InstallationSource.local || inspected.installation == null
          ? await _providerCall(() => provider.install(project, progress))
          : inspected.installation!;
      cancellation?.check();
      if (action == InstallationAction.install) {
        return '${project.name} installed from ${source.label}. Selection unchanged.';
      }
      await store.activate(
        project,
        installation,
        beforeCommit: cancellation?.check,
      );
      return '${project.name} → ${source.label} · ${installation.version}';
    } finally {
      lock.unlockSync();
      lock.closeSync();
      _busy = false;
    }
  }
}

bool _sameFile(String a, String b) {
  try {
    return File(a).resolveSymbolicLinksSync() ==
        File(b).resolveSymbolicLinksSync();
  } on FileSystemException {
    return false;
  }
}

Future<T> _providerCall<T>(Future<T> Function() operation) async {
  try {
    return await operation();
  } on FileSystemException catch (e) {
    throw InstallationFailure(
      'Installation files could not be accessed.',
      '$e',
    );
  } on SocketException catch (e) {
    throw InstallationFailure(
      'The installation service could not be reached.',
      '$e',
    );
  } on HttpException catch (e) {
    throw InstallationFailure('The installation download failed.', '$e');
  } on TimeoutException {
    throw const InstallationFailure(
      'The installation operation timed out.',
      'Check the provider and retry; selection has not changed.',
    );
  } on FormatException catch (e) {
    throw InstallationFailure('The installation metadata is invalid.', '$e');
  } on ProcessException catch (e) {
    throw InstallationFailure('The package manager could not start.', '$e');
  }
}
