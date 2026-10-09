import 'dart:async';
import 'dart:io';

import '../engine/assets.dart';
import '../engine/resolve.dart';
import '../engine/publish_target.dart';

enum InstallationSource {
  local('Local'),
  homebrew('Homebrew'),
  pub('Pub'),
  github('GitHub');

  const InstallationSource(this.label);
  final String label;
  static InstallationSource? named(String name) =>
      values.where((source) => source.name == name).firstOrNull;
}

enum InstallationAction { install, use, uninstall }

/// One complete executable package, never an independently switched dependency.
class ExecutableProject {
  ExecutableProject({
    required this.root,
    required this.unit,
    required this.project,
    required this.entrypoints,
    this.repository,
  });
  final String root;
  final ResolvedUnit unit;
  final ResolvedProject project;
  final String? repository;
  final Map<String, String> entrypoints;
  String get name => project.name;
  String get version => project.version.canonical;
  String get directory => project.directoryIn(root);
  List<String> get commands => entrypoints.keys.toList();
  String get label => commands.join(', ');
  Set<InstallationSource> get sources => {
    InstallationSource.local,
    if (project.publish.contains(PublishTarget.homebrew))
      InstallationSource.homebrew,
    if (project.publish.contains(PublishTarget.pubDev)) InstallationSource.pub,
    if (project.config.wantsBinaries &&
        unit.publish.contains(PublishTarget.githubRelease))
      InstallationSource.github,
  };
  String get formula {
    if (repository == null) {
      throw InstallationFailure(
        'The Homebrew source needs a GitHub repository.',
        'Check this repository’s origin remote.',
      );
    }
    final tap = unit
        .tapFor(repository!)
        .toLowerCase()
        .replaceFirst('/homebrew-', '/');
    return '$tap/${ReleaseAssets.formulaToken(commands.single)}';
  }
}

class LaunchCommand {
  const LaunchCommand(
    this.executable, {
    this.arguments = const [],
    this.environment = const {},
    this.requiredFiles = const [],
    this.workingDirectory,
  });
  final String executable;
  final List<String> arguments;
  final Map<String, String> environment;
  final List<String> requiredFiles;

  /// Bootstrap cwd; its first argument receives the original caller cwd.
  /// Only local Dart hook bootstraps use this; other launchers are unchanged.
  final String? workingDirectory;
  Map<String, Object?> toJson() => {
    'executable': executable,
    'arguments': arguments,
    'environment': environment,
    'required_files': requiredFiles,
    if (workingDirectory != null) 'working_directory': workingDirectory,
  };
}

class Installation {
  const Installation({
    required this.source,
    required this.version,
    required this.commands,
    required this.location,
    this.exportedPaths = const [],
  });
  final InstallationSource source;
  final String version, location;
  final Map<String, LaunchCommand> commands;

  /// Native package-manager entrypoints, used to detect active external installs.
  final List<String> exportedPaths;
  Map<String, Object?> toJson() => {
    'source': source.name,
    'version': version,
    'location': location,
    // Whether rk owns the installed bytes: a GitHub download under rk's data
    // directory, which rk replaces on update and removes on uninstall.
    'managed': source == InstallationSource.github,
    'exported_paths': exportedPaths,
    'commands': {
      for (final entry in commands.entries) entry.key: entry.value.toJson(),
    },
  };
}

class SourceInspection {
  const SourceInspection({this.installation, this.problem});
  final Installation? installation;

  /// Unknown/unusable is different from an absent installation.
  final String? problem;
}

class ProjectInstallations {
  ProjectInstallations(
    this.project,
    this.sources, {
    this.selected,
    this.routing = const [],
    this.resolvedCommands = const {},
    this.currentSources = const {},
  });
  final ExecutableProject project;
  final Map<InstallationSource, SourceInspection> sources;
  final InstallationSource? selected;
  final List<String> routing;
  final Map<String, String?> resolvedCommands;
  final Map<String, InstallationSource?> currentSources;
  InstallationSource? get currentSource =>
      currentSources.length == project.commands.length &&
          currentSources.values.toSet().length == 1
      ? currentSources.values.first
      : null;
  Map<String, Object?> toJson() => {
    'project': project.name,
    'commands': project.commands,
    'selected': selected?.name,
    'routing_problems': routing,
    'resolved_commands': resolvedCommands,
    'current_sources': {
      for (final e in currentSources.entries) e.key: e.value?.name,
    },
    'sources': {
      for (final e in sources.entries)
        e.key.name: {
          'installed': e.value.installation != null,
          'problem': e.value.problem,
          if (e.value.installation case final installation?)
            ...installation.toJson(),
        },
    },
  };
}

class InstallationFailure implements Exception {
  const InstallationFailure(this.message, [this.remedy = '']);
  final String message, remedy;
  @override
  String toString() => message;
}

/// What [error], from a source, the network or the file system, means for
/// an installation: one table for the source problems inspection records,
/// the CLI's RK-USE-001 and the picker's failures.
InstallationFailure installationFailure(Exception error) => switch (error) {
  InstallationFailure() => error,
  FileSystemException() => InstallationFailure(
    'Installation files could not be accessed.',
    '$error',
  ),
  SocketException() => InstallationFailure(
    'The installation service could not be reached.',
    '$error',
  ),
  HttpException() => InstallationFailure(
    'The installation download failed.',
    '$error',
  ),
  TimeoutException() => const InstallationFailure(
    'The installation operation timed out.',
    'Check the provider and retry; selection has not changed.',
  ),
  FormatException() => InstallationFailure(
    'The installation metadata is invalid.',
    '$error',
  ),
  ProcessException(:final executable) => InstallationFailure(
    '$executable could not start.',
    '$error',
  ),
  _ => InstallationFailure('$error'),
};

bool safeCommandName(String value) =>
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(value);

String shellQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";

List<ExecutableProject> executableProjects(
  Resolution resolution,
  String root, {
  String? repository,
}) {
  final found = <ExecutableProject>[];
  for (final unit in resolution.units) {
    for (final project in unit.projects) {
      final commands = project.pubspec.executableScripts;
      if (commands.isEmpty) continue;
      // A launcher names its project in a line of shell.
      if (!RegExp(r'^\w+$').hasMatch(project.name)) {
        throw InstallationFailure(
          'Unsupported package name in ${project.directoryIn(root)}/pubspec.yaml.',
          'A Dart package name has only letters, digits and underscores.',
        );
      }
      for (final entry in commands.entries) {
        if (!safeCommandName(entry.key) || !safeCommandName(entry.value)) {
          throw InstallationFailure(
            'Unsupported executable declaration in ${project.name}.',
            'Command and bin script names must be plain filenames without directory traversal.',
          );
        }
        final script = File(
          '${project.directoryIn(root)}/bin/${entry.value}.dart',
        );
        if (!script.existsSync()) {
          throw InstallationFailure(
            '${project.name} declares ${entry.key}, but bin/${entry.value}.dart is missing.',
          );
        }
      }
      found.add(
        ExecutableProject(
          root: root,
          unit: unit,
          project: project,
          repository: repository,
          entrypoints: Map.unmodifiable(commands),
        ),
      );
    }
  }
  return List.unmodifiable(found);
}
