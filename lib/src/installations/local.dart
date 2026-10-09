import 'dart:io';

import '../engine/tools.dart';
import 'model.dart';
import 'local_bootstrap.dart';
import 'provider.dart';
import 'store.dart';

class LocalInstallationProvider implements InstallationProvider {
  LocalInstallationProvider(this.tools, this.dartExecutable, this.store);
  final Tools tools;
  final String? dartExecutable;
  final InstallationStore store;
  @override
  InstallationSource get source => InstallationSource.local;

  Installation _installation(ExecutableProject project) => Installation(
    source: source,
    version: project.version,
    location: project.directory,
    commands: {
      for (final entry in project.entrypoints.entries)
        entry.key: _command(project, entry.key, entry.value),
    },
  );

  LaunchCommand _command(
    ExecutableProject project,
    String command,
    String name,
  ) {
    final entry = '${project.directory}/bin/$name.dart';
    final bootstrap = localBootstrap(project, command, entry);
    return LaunchCommand(
      dartExecutable!,
      arguments: [
        '--suppress-analytics',
        'run',
        for (final define in project.project.dartDefines.entries)
          '-D${define.key}=${define.value}',
        bootstrap ?? entry,
      ],
      workingDirectory: bootstrap == null ? null : project.directory,
      requiredFiles: [
        '${project.directory}/pubspec.yaml',
        entry,
        if (bootstrap != null) bootstrap,
      ],
    );
  }

  /// Local is the checkout itself: selected, it is the checkout it was bound to.
  @override
  Future<SourceInspection> inspect(ExecutableProject project) async {
    final selected = store.selected(project);
    final installation = selected?.source == source
        ? Installation(
            source: source,
            version: project.version,
            location: selected!.location,
            commands: const {},
          )
        : null;
    if (dartExecutable == null || !File(dartExecutable!).existsSync()) {
      return SourceInspection(
        installation: installation,
        problem: 'Dart is not available on PATH.',
      );
    }
    return SourceInspection(installation: installation);
  }

  @override
  Future<AvailableInstallation> latest(
    ExecutableProject project, {
    InstallationCancellation? check,
  }) async => throw const InstallationFailure(followsCheckout);

  @override
  Future<Installation> install(
    ExecutableProject project,
    AvailableInstallation? release,
    void Function(String) progress,
  ) async {
    if (dartExecutable == null) {
      throw const InstallationFailure('Dart is required for the local source.');
    }
    progress('Preparing ${project.name} from this checkout…');
    await checked(tools, dartExecutable!, [
      '--suppress-analytics',
      'pub',
      'get',
    ], directory: project.directory);
    return _installation(project);
  }

  /// Only the launchers are rk's to remove; a checkout is never deleted.
  @override
  Future<void> uninstall(ExecutableProject project) async {}
}

/// Why Local has no newer version to check or install.
const followsCheckout =
    'Local follows this checkout; it has no remote version to update.';
