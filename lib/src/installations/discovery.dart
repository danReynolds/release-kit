import 'dart:io';

import '../engine/resolve.dart';
import 'model.dart';

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
        final directory = Directory(
          project.directoryIn(root),
        ).resolveSymbolicLinksSync();
        if (!script.resolveSymbolicLinksSync().startsWith('$directory/')) {
          throw InstallationFailure(
            '${entry.key} resolves outside its package.',
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
