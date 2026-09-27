import 'dart:convert';
import 'dart:io';

import '../../engine/diagnostic.dart';
import '../../engine/pubspec.dart';
import '../../engine/tools.dart';
import '../../engine/yaml.dart';
import '../../installations/model.dart';
import '../../installations/provider.dart';

/// Pub owns the activation and dependency graph; rk owns only its routing.
class PubInstallationProvider implements InstallationProvider {
  PubInstallationProvider(this.tools, this.dart, this.environment);
  final Tools tools;
  final String? dart;
  final Map<String, String> environment;
  @override
  InstallationSource get source => InstallationSource.pub;
  String get cache =>
      environment['PUB_CACHE'] ?? '${environment['HOME']}/.pub-cache';
  Map<String, String> get _environment => {
    ...environment,
    'PUB_CACHE': cache,
    'PUB_HOSTED_URL': 'https://pub.dev',
  };

  @override
  Future<SourceInspection> inspect(ExecutableProject project) async {
    if (!project.project.pubspec.declaresPubDev) {
      return const SourceInspection(
        problem:
            'This project publishes to a custom registry. The pub source currently supports pub.dev.',
      );
    }
    if (dart == null) {
      return const SourceInspection(problem: 'Install Dart to use pub.dev.');
    }
    if (!cache.startsWith('/')) {
      return const SourceInspection(
        problem: 'PUB_CACHE must be an absolute path.',
      );
    }
    final root = '$cache/global_packages/${project.name}';
    final repair =
        'The Pub activation is incomplete.\n\nRepair it with:\n'
        'dart pub global activate --no-executables ${project.name}';
    final lock = File('$root/pubspec.lock');
    if (!lock.existsSync()) {
      return Directory(root).existsSync()
          ? SourceInspection(problem: repair)
          : const SourceInspection();
    }
    final diagnostics = Diagnostics();
    final package = parseYaml(
      lock.readAsStringSync(),
      lock.path,
      diagnostics,
    )?.map('packages')?.map(project.name);
    if (diagnostics.isNotEmpty ||
        package?.string('source') != 'hosted' ||
        package?.map('description')?.string('url') != 'https://pub.dev') {
      return const SourceInspection(
        problem:
            'The global activation uses a different source. Keep it or deactivate it with Dart before installing from pub.dev.',
      );
    }
    final config = File('$root/.dart_tool/package_config.json');
    if (!config.existsSync()) {
      return SourceInspection(problem: repair);
    }
    final decoded = jsonDecode(config.readAsStringSync());
    if (decoded is! Map || decoded['packages'] is! List) {
      throw const FormatException('Invalid pub package configuration.');
    }
    final entries = (decoded['packages'] as List)
        .whereType<Map>()
        .where((p) => p['name'] == project.name)
        .toList();
    if (entries.length != 1 || entries.single['rootUri'] is! String) {
      throw const FormatException('Missing or ambiguous activated package.');
    }
    final uri = config.uri.resolve(entries.single['rootUri'] as String);
    if (uri.scheme != 'file') {
      throw const FormatException('The activated package is not a local file.');
    }
    final directory = uri.toFilePath();
    final manifest = File('$directory/pubspec.yaml');
    final pubspec = Pubspec.parse(
      manifest.readAsStringSync(),
      manifest.path,
      diagnostics,
    );
    if (pubspec == null ||
        pubspec.name != project.name ||
        pubspec.version?.canonical != package?.string('version')) {
      return const SourceInspection(
        problem: 'The pub activation does not match its package metadata.',
      );
    }
    final scripts = pubspec.executableScripts;
    if (scripts.length != project.commands.length ||
        !scripts.keys.toSet().containsAll(project.commands) ||
        scripts.values.any((s) => !safeCommandName(s))) {
      return const SourceInspection(
        problem:
            'The installed pub package exports different commands. Activate a matching version with Dart.',
      );
    }
    return SourceInspection(
      installation: Installation(
        source: source,
        version: package!.string('version')!,
        location: directory,
        exportedPaths: [
          for (final command in project.commands) '$cache/bin/$command',
        ],
        commands: {
          for (final e in scripts.entries)
            e.key: LaunchCommand(
              dart!,
              arguments: [
                '--suppress-analytics',
                'pub',
                'global',
                'run',
                '${project.name}:${e.value}',
              ],
              environment: {
                'PUB_CACHE': cache,
                'PUB_HOSTED_URL': 'https://pub.dev',
              },
              requiredFiles: [lock.path, manifest.path],
            ),
        },
      ),
    );
  }

  @override
  Future<Installation> install(
    ExecutableProject project,
    void Function(String) progress,
  ) async {
    progress('Installing ${project.name} from pub.dev…');
    // No native binstub changes: install prepares; only use selects.
    await checked(tools, dart!, [
      '--suppress-analytics',
      'pub',
      'global',
      'activate',
      '--no-executables',
      project.name,
    ], environment: _environment);
    final state = await inspect(project);
    return state.installation ??
        (throw InstallationFailure(
          state.problem ?? 'Pub did not install ${project.name}.',
        ));
  }

  @override
  Future<void> uninstall(
    ExecutableProject project,
    Installation installation,
  ) async {
    await checked(tools, dart!, [
      '--suppress-analytics',
      'pub',
      'global',
      'deactivate',
      project.name,
    ], environment: _environment);
  }
}
