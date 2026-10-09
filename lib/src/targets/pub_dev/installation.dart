import 'dart:convert';
import 'dart:io';
import 'package:pub_semver/pub_semver.dart' as semver;
import '../../installations/metadata.dart';

import '../../engine/diagnostic.dart';
import '../../engine/pubspec.dart';
import '../../engine/tools.dart';
import '../../engine/yaml.dart';
import '../../installations/model.dart';
import '../../installations/provider.dart';

/// Pub owns the activation and dependency graph; rk owns only its routing.
class PubInstallationProvider implements InstallationProvider {
  PubInstallationProvider(
    this.tools,
    this.dart,
    this.environment, {
    this.fetch = fetchHttps,
  });
  final HttpsFetch fetch;
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
    if (diagnostics.isNotEmpty || package == null) {
      return SourceInspection(problem: repair);
    }
    if (package.string('source') != 'hosted' ||
        package.map('description')?.string('url') != 'https://pub.dev') {
      final kind = switch (package.string('source')) {
        'path' => 'a local path',
        'git' => 'Git',
        _ => 'another registry',
      };
      return SourceInspection(
        problem:
            'Already activated from $kind. To replace it with pub.dev, first run:\n'
            'dart pub global deactivate ${project.name}',
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
        pubspec.version?.canonical != package.string('version')) {
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
        version: package.string('version')!,
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
  Future<AvailableInstallation> latest(
    ExecutableProject project, {
    InstallationCheck? check,
  }) async {
    if (dart == null || !project.project.pubspec.declaresPubDev) {
      throw const InstallationFailure(
        'This source needs Dart and a pub.dev package.',
      );
    }
    final sdkResult = await tools.run(dart!, [
      '--version',
    ], timeout: const Duration(seconds: 8));
    final sdkText = RegExp(
      r'Dart SDK version: ([^ ]+)',
    ).firstMatch('${sdkResult.stdout} ${sdkResult.stderr}')?.group(1);
    final sdk = sdkText == null ? null : semver.Version.parse(sdkText);
    if (!sdkResult.ok || sdk == null) {
      throw const InstallationFailure(
        'Could not determine the installed Dart SDK version.',
      );
    }
    final data =
        jsonDecode(
              utf8.decode(
                await fetch(
                  Uri.https('pub.dev', '/api/packages/${project.name}'),
                  8 * 1024 * 1024,
                  check: check,
                ),
              ),
            )
            as Map;
    if (data['isDiscontinued'] == true) {
      throw const InstallationFailure('This pub.dev package is discontinued.');
    }
    final compatible = <semver.Version>[];
    for (final entry in (data['versions'] as List).cast<Map>()) {
      if (entry['retracted'] == true) continue;
      final version = semver.Version.parse(entry['version'] as String);
      final spec = entry['pubspec'] as Map;
      final env = spec['environment'] as Map?;
      final commands = spec['executables'] as Map?;
      if (version.isPreRelease ||
          env?['flutter'] != null ||
          (spec['dependencies'] as Map?)?.containsKey('flutter') == true ||
          env?['sdk'] is! String ||
          !semver.VersionConstraint.parse(env!['sdk'] as String).allows(sdk) ||
          spec['name'] != project.name ||
          commands == null ||
          commands.length != project.commands.length ||
          !commands.keys.toSet().containsAll(project.commands)) {
        continue;
      }
      compatible.add(version);
    }
    if (compatible.isEmpty) {
      throw const InstallationFailure(
        'No stable release matches this Dart SDK and command set.',
      );
    }
    compatible.sort();
    return AvailableInstallation(compatible.last.toString());
  }

  /// Pub picks the newest version this SDK allows unless [release] names
  /// one. No native binstubs: install prepares; only use selects.
  @override
  Future<Installation> install(
    ExecutableProject project,
    AvailableInstallation? release,
    void Function(String) progress,
  ) async {
    final version = release?.version;
    progress(
      'Installing ${project.name}${version == null ? '' : ' $version'} from pub.dev…',
    );
    await checked(tools, dart!, [
      '--suppress-analytics',
      'pub',
      'global',
      'activate',
      '--no-executables',
      project.name,
      ?version,
    ], environment: _environment);
    return inspectedAfterInstall(this, project);
  }

  @override
  Future<void> uninstall(ExecutableProject project) async {
    await checked(tools, dart!, [
      '--suppress-analytics',
      'pub',
      'global',
      'deactivate',
      project.name,
    ], environment: _environment);
  }
}
