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

  @override
  Future<SourceInspection> inspect(ExecutableProject project) async {
    if (dartExecutable == null || !File(dartExecutable!).existsSync()) {
      return SourceInspection(
        installation: store.recorded(project, source),
        problem: 'Dart is not available on PATH.',
      );
    }
    return SourceInspection(installation: store.recorded(project, source));
  }

  @override
  Future<Installation> install(
    ExecutableProject project,
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

  @override
  Future<void> uninstall(
    ExecutableProject project,
    Installation installation,
  ) async {
    // Only the routing receipt is removed by the coordinator. Never delete a checkout.
  }
}
