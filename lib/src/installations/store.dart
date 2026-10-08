import 'dart:convert';
import 'dart:io';

import '../engine/tools.dart';
import '../transforms/digest.dart';
import 'model.dart';
import 'provider.dart';

/// The launchers rk writes into one directory on PATH. Each launcher names its
/// project and source in a header, so the selection is read back from the
/// launchers themselves; provider packages and checkouts stay where they are.
class InstallationStore {
  InstallationStore(String root, this.tools)
    : root = Directory(root).absolute.path;
  final String root;
  final Tools tools;
  String get bin => '$root/bin';
  String id(ExecutableProject project) => Sha256.hex(
    utf8.encode('${project.repository ?? project.root}\u0000${project.name}'),
  );
  String projectRoot(ExecutableProject project) =>
      '$root/projects/${id(project)}';

  static String defaultRoot(Map<String, String> environment) {
    final data = environment['XDG_DATA_HOME'];
    final home = environment['HOME'];
    if (data != null && data.startsWith('/')) return '$data/rk';
    if (home == null || !home.startsWith('/')) {
      throw const InstallationFailure(
        'No home directory is available for installations.',
      );
    }
    return '$home/.local/share/rk';
  }

  RandomAccessFile lock() {
    Directory(root).createSync(recursive: true);
    final lock = File('$root/install.lock').openSync(mode: FileMode.append);
    try {
      lock.lockSync(FileLock.exclusive);
    } on FileSystemException {
      lock.closeSync();
      throw const InstallationFailure(
        'Another rk installation operation is running.',
        'Wait for it to finish, then retry.',
      );
    }
    return lock;
  }

  String _owner(ExecutableProject project) => '# rk-managed:${id(project)}:';

  /// The selected source and its location, read from the first launcher.
  ({InstallationSource source, String location})? selected(
    ExecutableProject project,
  ) {
    final file = File('$bin/${project.commands.first}');
    if (!file.existsSync()) return null;
    final lines = file.readAsLinesSync();
    final owner = _owner(project);
    final header = lines.where((line) => line.startsWith(owner)).firstOrNull;
    final location = lines
        .where((line) => line.startsWith('# rk-location:'))
        .firstOrNull;
    final source = header == null
        ? null
        : InstallationSource.named(header.substring(owner.length));
    if (source == null || location == null) return null;
    return (source: source, location: location.substring(14));
  }

  /// Any launcher rk wrote may be replaced; anything else is someone's command.
  void checkOwnership(ExecutableProject project) {
    for (final command in project.commands) {
      final file = File('$bin/$command');
      if (file.existsSync() &&
          !file.readAsStringSync().contains('# rk-managed:')) {
        throw InstallationFailure(
          '$command is already owned by another installation.',
          'rk will not replace ${file.path}. Resolve the command collision first.',
        );
      }
    }
  }

  /// Write every command's launcher; each replaces its predecessor atomically.
  Future<void> activate(
    ExecutableProject project,
    Installation installation, {
    void Function()? beforeCommit,
  }) async {
    if (!installation.commands.keys.toSet().containsAll(project.commands) ||
        installation.commands.length != project.commands.length) {
      throw InstallationFailure(
        '${installation.source.label} exports different commands for ${project.name}.',
        'Use a version whose complete executable set matches this project.',
      );
    }
    checkOwnership(project);
    Directory(bin).createSync(recursive: true);
    final scripts = {
      for (final entry in installation.commands.entries)
        entry.key: _launcher(project, installation, entry.value),
    };
    beforeCommit?.call();
    for (final entry in scripts.entries) {
      // Made executable beside the launcher, then renamed over it: a command
      // started meanwhile runs the old launcher or the new one, never neither.
      final temporary = File('$bin/.${entry.key}.$pid.tmp');
      try {
        temporary.writeAsStringSync(entry.value, flush: true);
        await checked(tools, '/bin/chmod', ['700', temporary.path]);
        temporary.renameSync('$bin/${entry.key}');
      } finally {
        if (temporary.existsSync()) temporary.deleteSync();
      }
    }
  }

  String _launcher(
    ExecutableProject project,
    Installation installation,
    LaunchCommand command,
  ) {
    final script = StringBuffer('#!/bin/sh\n')
      ..writeln('${_owner(project)}${installation.source.name}')
      ..writeln('# rk-location:${installation.location}');
    for (final file in [command.executable, ...command.requiredFiles]) {
      script.writeln('if [ ! -f ${shellQuote(file)} ]; then');
      script.writeln(
        '  printf "%s\\n" ${shellQuote('rk: ${project.name} ${installation.source.label} is no longer available. Run rk use in its checkout to repair the selection.')} >&2',
      );
      script.writeln('  exit 127\nfi');
    }
    final bootstrap = command.workingDirectory;
    if (bootstrap != null) {
      script.writeln('rk_caller_directory="\$PWD"');
      script.writeln('cd -- ${shellQuote(bootstrap)} || exit 127');
    }
    script.writeln(
      'exec ${[if (command.environment.isNotEmpty) '/usr/bin/env', for (final entry in command.environment.entries) '${entry.key}=${entry.value}', command.executable, ...command.arguments].map(shellQuote).join(' ')} ${bootstrap == null ? '' : '"\$rk_caller_directory" '}"\$@"',
    );
    return '$script';
  }

  List<String> routingProblems(
    ExecutableProject project,
    Map<String, String> environment,
  ) {
    if (selected(project) == null) return const [];
    return [
      for (final command in project.commands)
        if (findExecutable(command, environment) != '$bin/$command')
          '$command resolves to ${findExecutable(command, environment) ?? 'nothing'}; put $bin first in PATH.',
    ];
  }

  String managedDirectory(ExecutableProject project, String name) {
    final directory = '${projectRoot(project)}/$name';
    Directory(directory).createSync(recursive: true);
    return directory;
  }
}

String? findExecutable(String name, Map<String, String> environment) {
  for (final directory in (environment['PATH'] ?? '').split(':')) {
    if (directory.isEmpty) continue;
    final path = '$directory/$name';
    final stat = File(path).statSync();
    if (stat.type == FileSystemEntityType.file && stat.mode & 0x49 != 0) {
      return File(path).absolute.path;
    }
  }
  return null;
}
