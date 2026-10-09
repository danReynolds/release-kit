import 'dart:convert';
import 'dart:io';

import '../engine/tools.dart';
import '../transforms/digest.dart';
import 'model.dart';
import 'provider.dart';

/// A launcher rk wrote, read back: the project it names, the source it runs
/// and where that source is installed. [project] is null for a launcher an
/// older rk wrote, which named the project by a hash of its origin.
typedef Launcher = ({
  String? project,
  InstallationSource source,
  String location,
});

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

  /// `# rk-managed:<project>:<source>`, naming the project by its package.
  /// Older launchers name it by a [_hash] of its origin: rk 0.1.14's carry no
  /// source, and later development builds' do.
  static final _header = RegExp(
    r'^# rk-managed:([^:\s]+)(?::(\w+))?$',
    multiLine: true,
  );
  static final _location = RegExp(r'^# rk-location:(.+)$', multiLine: true);
  static final _hash = RegExp(r'^[0-9a-f]{64}$');

  /// The launcher rk wrote for [command], or null when there is none or it
  /// cannot be read.
  Launcher? launcher(String command) {
    final file = File('$bin/$command');
    if (!file.existsSync()) return null;
    final text = file.readAsStringSync();
    final header = _header.firstMatch(text);
    final source = InstallationSource.named(header?[2] ?? '');
    final location = _location.firstMatch(text)?[1];
    if (header == null || source == null || location == null) return null;
    final owner = header[1]!;
    return (
      project: _hash.hasMatch(owner) ? null : owner,
      source: source,
      location: location,
    );
  }

  /// What [project]'s commands run: each command whose launcher rk wrote for
  /// this project, or before launchers named their project.
  Map<String, Launcher> launchers(ExecutableProject project) => {
    for (final command in project.commands)
      if (launcher(command) case final launcher?
          when (launcher.project ?? project.name) == project.name)
        command: launcher,
  };

  /// The selected source and its location, read from the project's first
  /// launcher.
  Launcher? selected(ExecutableProject project) =>
      launchers(project).values.firstOrNull;

  /// A launcher rk wrote for this project may be replaced, and so may one
  /// that names no project. A command rk did not write, or selected for
  /// another project, is not this project's.
  void checkOwnership(ExecutableProject project) {
    for (final command in project.commands) {
      final file = File('$bin/$command');
      if (!file.existsSync()) continue;
      final owner = _header.firstMatch(file.readAsStringSync())?[1];
      if (owner == null) {
        throw InstallationFailure(
          '$command is already owned by another installation.',
          'rk will not replace ${file.path}. Resolve the command collision first.',
        );
      }
      if (owner != project.name && !_hash.hasMatch(owner)) {
        throw InstallationFailure(
          '$command is selected for $owner.',
          'rk will not replace ${file.path} for ${project.name}. Resolve the command collision first.',
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
      ..writeln('# rk-managed:${project.name}:${installation.source.name}')
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
    final launchers = this.launchers(project);
    final selected = launchers.values.firstOrNull;
    if (selected == null) return const [];
    return [
      for (final command in project.commands)
        if (launcher(command)?.project case final owner?
            when owner != project.name)
          '$command is selected for $owner, not ${project.name}.'
        else if (launchers[command]?.source != selected.source)
          '$command is not switched to ${selected.source.label}; run rk use ${selected.source.name} again.'
        else if (findExecutable(command, environment) != '$bin/$command')
          '$command resolves to ${findExecutable(command, environment) ?? 'nothing'}; put $bin first in PATH.',
    ];
  }

  /// Once [kept] is installed and routed, removes what it replaced: rk's own
  /// earlier downloads, and any an interrupted run left half unpacked. The
  /// download the current launchers run is never removed.
  void retire(ExecutableProject project, Installation kept) {
    if (!kept.managed) return;
    final parent = Directory(kept.location).parent;
    if (!parent.path.startsWith('${projectRoot(project)}/')) return;
    final inUse = selected(project)?.location;
    for (final entry in parent.listSync(followLinks: false)) {
      if (entry.path != kept.location && entry.path != inUse) {
        entry.deleteSync(recursive: true);
      }
    }
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
