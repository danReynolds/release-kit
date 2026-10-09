import 'dart:convert';
import 'dart:io';

import '../engine/tools.dart';
import 'model.dart';
import 'provider.dart';
import 'store.dart';

class LocalInstallationProvider implements InstallationProvider {
  LocalInstallationProvider(
    this.tools,
    this.dartExecutable,
    this.store, {
    this.live = false,
  });
  final Tools tools;
  final String? dartExecutable;
  final InstallationStore store;
  final bool live;
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
    final bootstrap = _localBootstrap(project, command, entry);
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

  /// Prefer the selected build; otherwise show the newest completed build.
  @override
  Future<SourceInspection> inspect(ExecutableProject project) async {
    final selected = store.selected(project);
    Installation? installation;
    final builds = Directory(store.localBuilds(project));
    if (selected?.source == source) {
      installation = Directory(selected!.location).parent.path == builds.path
          ? _readBuild(selected.location)
          : Installation(
              source: source,
              version: project.version,
              location: selected.location,
              commands: const {},
            );
    } else if (builds.existsSync()) {
      final entries = builds.listSync(followLinks: false)
        ..sort((a, b) => b.path.compareTo(a.path));
      for (final entry in entries.whereType<Directory>()) {
        installation = _readBuild(entry.path);
        if (installation != null) break;
      }
    }
    if (dartExecutable == null || !File(dartExecutable!).existsSync()) {
      return SourceInspection(
        installation: installation,
        problem: 'Dart is not available on PATH.',
      );
    }
    return SourceInspection(installation: installation);
  }

  Installation? _readBuild(String location) {
    final file = File('$location/build.json');
    if (!file.existsSync()) return null; // An interrupted build.
    final record = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    return Installation(
      source: source,
      version: record['version'] as String,
      checkout: record['checkout'] as String,
      location: location,
      commands: {
        for (final entry in (record['executables'] as Map).entries)
          entry.key as String: LaunchCommand('$location/${entry.value}'),
      },
    );
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
    if (live) return _installation(project);

    // Build away from the selected executables. A failed rebuild must leave
    // every old command usable, including rk rebuilding itself.
    final parent = Directory(store.localBuilds(project))
      ..createSync(recursive: true);
    final build = parent.createTempSync(
      '${DateTime.now().microsecondsSinceEpoch}-',
    );
    var complete = false;
    try {
      final executables = {
        for (final entry in project.entrypoints.entries)
          entry.key: '${entry.value}/bundle/bin/${entry.value}',
      };
      for (final name in project.entrypoints.values.toSet()) {
        progress('Compiling $name from this checkout…');
        final relative = '$name/bundle/bin/$name';
        final defines = project.project.dartDefines;
        if (defines.isEmpty) {
          // Let Dart build and bundle native hook outputs beside the executable.
          await checked(tools, dartExecutable!, [
            '--suppress-analytics',
            'build',
            'cli',
            '--target',
            'bin/$name.dart',
            '--output',
            '${build.path}/$name',
          ], directory: project.directory);
        } else {
          // The SDK bundler does not accept -D. The ordinary compiler does;
          // it also refuses hooks rather than silently omitting native assets.
          File('${build.path}/$relative').parent.createSync(recursive: true);
          await checked(tools, dartExecutable!, [
            '--suppress-analytics',
            'compile',
            'exe',
            for (final define in defines.entries)
              '-D${define.key}=${define.value}',
            'bin/$name.dart',
            '-o',
            '${build.path}/$relative',
          ], directory: project.directory);
        }
      }
      final record = File('${build.path}/.build.json');
      record.writeAsStringSync(
        jsonEncode({
          'version': project.version,
          'checkout': project.directory,
          'executables': executables,
        }),
      );
      record.renameSync('${build.path}/build.json');
      complete = true;
      return _readBuild(build.path)!;
    } on InstallationFailure catch (error) {
      throw InstallationFailure(
        error.message,
        '${error.remedy}\nFix the build and retry, or use rk use local --live to run source with Dart.',
      );
    } finally {
      if (!complete) build.deleteSync(recursive: true);
    }
  }

  /// Only compiled copies are rk's to remove; a checkout is never deleted.
  @override
  Future<void> uninstall(ExecutableProject project) async {
    final builds = Directory(store.localBuilds(project));
    if (builds.existsSync()) builds.deleteSync(recursive: true);
  }
}

/// Why Local has no newer version to check or install.
const followsCheckout =
    'Local follows this checkout; it has no remote version to update.';

/// Dart 3.10–3.12 discovers hooks from the invoking directory. Prepare assets
/// there, then run the original script in its own isolate with the caller cwd.
/// The child keeps Platform.script, argument handling and ordinary stdio.
String? _localBootstrap(
  ExecutableProject project,
  String command,
  String entry,
) {
  var directory = Directory(project.directory);
  File? config;
  while (true) {
    final candidate = File('${directory.path}/.dart_tool/package_config.json');
    if (candidate.existsSync()) {
      config = candidate;
      break;
    }
    if (directory.path == project.root ||
        directory.parent.path == directory.path) {
      return null;
    }
    directory = directory.parent;
  }
  final json = jsonDecode(config.readAsStringSync()) as Map<String, dynamic>;
  final packages = (json['packages'] as List).cast<Map<String, dynamic>>();
  final hasHooks = packages.any((package) {
    final root = Directory.fromUri(
      config!.uri.resolve(package['rootUri'] as String),
    ).uri;
    return File.fromUri(root.resolve('hook/build.dart')).existsSync();
  });
  if (!hasHooks) return null;
  final path = '${project.directory}/.dart_tool/rk-local/$command.dart';
  final script = File(path)..parent.createSync(recursive: true);
  String literal(String value) => jsonEncode(value).replaceAll(r'$', r'\$');
  script.writeAsStringSync('''
// Generated by rk use local. The application's original entrypoint is retained.
import 'dart:io';
import 'dart:isolate';
Future<void> main(List<String> args) async {
  Directory.current = args.first;
  final events = ReceivePort();
  try {
    await Isolate.spawnUri(
      Uri.parse(${literal(File(entry).uri.toString())}),
      args.sublist(1), null,
      packageConfig: Uri.parse(${literal(config.uri.toString())}),
      onExit: events.sendPort, onError: events.sendPort, errorsAreFatal: true,
    );
    await for (final event in events) {
      if (event == null) break;
      stderr.writeln((event as List).join('\\n'));
      exitCode = 255;
    }
  } finally {
    events.close();
  }
}
''');
  return path;
}
