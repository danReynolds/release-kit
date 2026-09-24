import 'dart:convert';
import 'dart:io';

import '../engine/atomic_file.dart';
import '../engine/tools.dart';
import '../transforms/digest.dart';
import 'model.dart';
import 'provider.dart';

/// Owned launchers and one atomic selection pointer per executable project.
/// Provider packages and the user's checkout remain outside this routing layer.
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
    _directory(root);
    final path = '$root/install.lock';
    _regularOrAbsent(path);
    final lock = File(path).openSync(mode: FileMode.append);
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

  Installation? selected(ExecutableProject project) {
    final path = '${projectRoot(project)}/current';
    _parents(path);
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.link) {
      throw const InstallationFailure(
        'The selection pointer is not an rk link.',
      );
    }
    final target = Link(path).targetSync();
    if (!RegExp(r'^generations/[a-z0-9-]+$').hasMatch(target)) {
      throw const InstallationFailure(
        'The selection pointer leaves its project.',
      );
    }
    return _read('${projectRoot(project)}/$target/installation.json');
  }

  Installation? recorded(ExecutableProject project, InstallationSource source) {
    final installation = _read('${projectRoot(project)}/${source.name}.json');
    if (installation != null && installation.source != source) {
      throw const InstallationFailure(
        'An installation receipt names a different source.',
      );
    }
    return installation;
  }

  Installation? _read(String path) {
    _regularOrAbsent(path);
    if (!File(path).existsSync()) return null;
    try {
      return Installation.fromJson(
        jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>,
      );
    } on Object {
      throw InstallationFailure(
        'Installation receipt could not be read: $path',
        'Keep this file for diagnosis; rk has not changed the selection.',
      );
    }
  }

  /// Prepare launchers separately; a later failure cannot damage current/bin.
  Future<String> record(
    ExecutableProject project,
    Installation installation,
  ) async {
    if (!installation.commands.keys.toSet().containsAll(project.commands) ||
        installation.commands.length != project.commands.length) {
      throw InstallationFailure(
        '${installation.source.label} exports different commands for ${project.name}.',
        'Use a version whose complete executable set matches this project.',
      );
    }
    final directory = projectRoot(project);
    _directory('$root/projects');
    _directory(directory);
    _directory('$directory/generations');
    final generation =
        '${installation.source.name}-$pid-${DateTime.now().microsecondsSinceEpoch}';
    final target = '$directory/generations/$generation';
    _directory(target);
    _directory('$target/bin');
    try {
      for (final entry in installation.commands.entries) {
        if (!safeCommandName(entry.key)) {
          throw const InstallationFailure('Invalid exported command name.');
        }
        final command = entry.value;
        if (!command.executable.startsWith('/') ||
            command.environment.keys.any(
              (name) => !RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name),
            )) {
          throw const InstallationFailure(
            'A provider returned an invalid launcher.',
          );
        }
        final script = StringBuffer('#!/bin/sh\n');
        for (final file in [command.executable, ...command.requiredFiles]) {
          script.writeln('if [ ! -f ${shellQuote(file)} ]; then');
          script.writeln(
            '  printf "%s\\n" ${shellQuote('rk: ${project.name} ${installation.source.label} is no longer available. Run rk use in its checkout to repair the selection.')} >&2',
          );
          script.writeln('  exit 127\nfi');
        }
        script.writeln(
          'exec ${[if (command.environment.isNotEmpty) '/usr/bin/env', for (final entry in command.environment.entries) '${entry.key}=${entry.value}', command.executable, ...command.arguments].map(shellQuote).join(' ')} "\$@"',
        );
        final path = '$target/bin/${entry.key}';
        File(path).writeAsStringSync(script.toString(), flush: true);
        await checked(tools, '/bin/chmod', ['700', path]);
      }
      File(
        '$target/installation.json',
      ).writeAsStringSync(jsonEncode(installation.toJson()), flush: true);
      _regularOrAbsent('$directory/${installation.source.name}.json');
      AtomicFile.write(
        '$directory/${installation.source.name}.json',
        utf8.encode(jsonEncode(installation.toJson())),
      );
      return 'generations/$generation';
    } on Object {
      Directory(target).deleteSync(recursive: true);
      rethrow;
    }
  }

  void checkOwnership(ExecutableProject project) {
    for (final command in project.commands) {
      final path = '$bin/$command';
      _regularOrAbsent(path);
      final expected = _shim(project, command);
      if (File(path).existsSync() &&
          (File(path).lengthSync() != utf8.encode(expected).length ||
              utf8.decode(File(path).readAsBytesSync(), allowMalformed: true) !=
                  expected)) {
        throw InstallationFailure(
          '$command is already owned by another installation.',
          'rk will not replace $path. Resolve the command collision first.',
        );
      }
    }
  }

  Future<void> activate(
    ExecutableProject project,
    String generation, {
    void Function()? beforeCommit,
  }) async {
    if (!RegExp(r'^generations/[a-z0-9-]+$').hasMatch(generation) ||
        _read('${projectRoot(project)}/$generation/installation.json') ==
            null) {
      throw const InstallationFailure('Invalid prepared installation.');
    }
    checkOwnership(project);
    _directory(bin);
    final created = <File>[];
    final pointer = '${projectRoot(project)}/current';
    final temporary = Link('$pointer.next');
    if (FileSystemEntity.typeSync(temporary.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const InstallationFailure(
        'A previous selection update left a temporary pointer.',
      );
    }
    try {
      for (final command in project.commands) {
        final file = File('$bin/$command');
        if (!file.existsSync()) {
          file.createSync(exclusive: true);
          created.add(file);
          file.writeAsStringSync(_shim(project, command), flush: true);
          await checked(tools, '/bin/chmod', ['700', file.path]);
        }
      }
      // Validate an existing pointer before atomically replacing it.
      selected(project);
      beforeCommit?.call();
      temporary.createSync(generation);
      temporary.renameSync(pointer);
    } on Object {
      for (final file in created) {
        if (file.existsSync()) file.deleteSync();
      }
      rethrow;
    } finally {
      if (FileSystemEntity.typeSync(temporary.path, followLinks: false) ==
          FileSystemEntityType.link) {
        temporary.deleteSync();
      }
    }
  }

  String _shim(ExecutableProject project, String command) =>
      '''#!/bin/sh
# rk-managed:${id(project)}
if [ ! -x ${shellQuote('${projectRoot(project)}/current/bin/$command')} ]; then
  printf '%s\\n' ${shellQuote('rk: $command has no usable selection. Run rk use from its configured repository.')} >&2
  exit 127
fi
exec ${shellQuote('${projectRoot(project)}/current/bin/$command')} "\$@"
''';

  void forget(ExecutableProject project, InstallationSource source) {
    if (selected(project)?.source == source) {
      throw InstallationFailure(
        '${source.label} is selected for ${project.name}.',
        'Choose another source with rk use first.',
      );
    }
    final directory = projectRoot(project);
    final receipt = File('$directory/${source.name}.json');
    _regularOrAbsent(receipt.path);
    if (receipt.existsSync()) receipt.deleteSync();
    final generations = Directory('$directory/generations');
    if (!generations.existsSync()) return;
    for (final entry in generations.listSync(followLinks: false)) {
      if (entry is! Directory ||
          !RegExp(
            r'^[a-z]+-[0-9]+-[0-9]+$',
          ).hasMatch(entry.uri.pathSegments.where((s) => s.isNotEmpty).last)) {
        continue;
      }
      final installation = _read('${entry.path}/installation.json');
      if (installation?.source == source) entry.deleteSync(recursive: true);
    }
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

  /// Validate every owned parent, including reads, before touching state.
  /// Ancestors of the configured store (for example /tmp) may be symlinks.
  void _parents(String path) {
    if (path != root && !path.startsWith('$root/')) {
      throw const InstallationFailure(
        'Installation path leaves the managed store.',
      );
    }
    final suffix = path == root ? '' : path.substring(root.length + 1);
    if (suffix.split('/').any((part) => part == '..' || part == '.')) {
      throw const InstallationFailure('Invalid installation path.');
    }
    var current = root;
    final parents = suffix.split('/');
    for (var i = 0; i < parents.length; i++) {
      final type = FileSystemEntity.typeSync(current, followLinks: false);
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.directory) {
        throw InstallationFailure(
          'Installation parent is not a real directory: $current',
        );
      }
      current = '$current/${parents[i]}';
    }
  }

  String managedDirectory(ExecutableProject project, String name) {
    if (!safeCommandName(name)) {
      throw const InstallationFailure('Invalid installation directory name.');
    }
    final directory = '${projectRoot(project)}/$name';
    _directory(root);
    _directory(directory);
    return directory;
  }

  void validateManagedDirectory(String path) {
    _parents('$path/entry');
  }

  void _directory(String path) {
    _parents(path);
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      Directory(path).createSync(recursive: true);
      return;
    }
    if (type != FileSystemEntityType.directory) {
      throw InstallationFailure(
        'Installation directory is not a real directory: $path',
      );
    }
  }

  void _regularOrAbsent(String path) {
    _parents(path);
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw InstallationFailure(
        'Refusing to replace an unowned filesystem entry: $path',
      );
    }
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
