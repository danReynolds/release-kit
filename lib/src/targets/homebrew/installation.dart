import 'dart:convert';
import 'dart:io';

import '../../engine/tools.dart';
import '../../builds/capability.dart';
import '../../engine/version.dart';
import '../../installations/metadata.dart';
import '../../transforms/digest.dart';
import '../../installations/model.dart';
import '../../installations/provider.dart';

class HomebrewInstallationProvider
    implements InstallationProvider, InstallationUpdates {
  HomebrewInstallationProvider(
    this.tools,
    this.brew, {
    this.fetch = fetchInstallationMetadata,
    String? platform,
  }) : platform = platform ?? HostCapabilities.inspect().hostPlatform;
  final String platform;
  final MetadataFetch fetch;
  final Tools tools;
  final String? brew;
  @override
  InstallationSource get source => InstallationSource.homebrew;
  static const _environment = {
    'HOMEBREW_NO_AUTO_UPDATE': '1',
    'HOMEBREW_NO_ASK': '1',
    'NONINTERACTIVE': '1',
    'HOMEBREW_NO_INSTALL_UPGRADE': '1',
    'HOMEBREW_NO_INSTALL_CLEANUP': '1',
    'HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK': '1',
  };

  @override
  Future<SourceInspection> inspect(ExecutableProject project) async {
    if (brew == null) {
      return const SourceInspection(
        problem: 'Install Homebrew to use this source.',
      );
    }
    // Read the small installed-name inventory before asking for one formula's
    // metadata. `info --installed` evaluates every formula and cask on the host.
    // The exact tap-qualified match also avoids querying an uninstalled tap.
    final identity = project.formula;
    final inventory = await checked(tools, brew!, [
      'list',
      '--formula',
      '--full-name',
      '-1',
    ], environment: _environment);
    if (!inventory.stdout
        .split('\n')
        .map((line) => line.trim())
        .contains(identity)) {
      return const SourceInspection();
    }
    final result = await checked(tools, brew!, [
      'info',
      '--json=v2',
      '--formula',
      identity,
    ], environment: _environment);
    final formulae = (jsonDecode(result.stdout) as Map)['formulae'] as List;
    final matches = formulae
        .cast<Map>()
        .where((f) => f['full_name'] == project.formula)
        .toList();
    if (matches.isEmpty) return const SourceInspection();
    final formula = matches.single;
    final installed = (formula['installed'] as List).cast<Map>();
    if (installed.isEmpty) return const SourceInspection();
    final linked = formula['linked_keg'];
    final selected =
        installed.where((i) => i['version'] == linked).firstOrNull ??
        (installed.length == 1 ? installed.single : null);
    if (selected == null) {
      return const SourceInspection(
        problem:
            'Multiple unlinked Homebrew versions exist. Select one with brew link first.',
      );
    }
    final version = selected['version'] as String;
    if (!safeCommandName(version)) {
      return const SourceInspection(
        problem: 'Homebrew returned an unsupported version directory.',
      );
    }
    // The JSON already resolved the formula's canonical rack name. Asking
    // `--cellar <formula>` would boot Homebrew's resolver a second time.
    final rack = formula['name'];
    if (rack is! String || !safeCommandName(rack)) {
      return const SourceInspection(
        problem: 'Homebrew returned an unsupported formula directory.',
      );
    }
    final cellar = (await checked(tools, brew!, [
      '--cellar',
    ], environment: _environment)).stdout.trim();
    if (!cellar.startsWith('/')) {
      throw const InstallationFailure('Homebrew returned a relative cellar.');
    }
    final prefix = '$cellar/$rack/$version';
    final globalPrefix = (await checked(tools, brew!, [
      '--prefix',
    ], environment: _environment)).stdout.trim();
    for (final command in project.commands) {
      if (!File('$prefix/bin/$command').existsSync()) {
        return SourceInspection(
          problem:
              'Homebrew is missing $command. Repair it with brew reinstall ${project.formula}.',
        );
      }
    }
    return SourceInspection(
      installation: Installation(
        source: source,
        version: version,
        location: prefix,
        exportedPaths: [
          for (final command in project.commands) '$globalPrefix/bin/$command',
        ],
        commands: {
          for (final command in project.commands)
            command: LaunchCommand('$prefix/bin/$command'),
        },
      ),
    );
  }

  @override
  Future<AvailableInstallation> latest(
    ExecutableProject project, {
    InstallationCheck? check,
  }) async {
    Future<List<int>> metadata(Uri uri, int max) =>
        fetch == fetchInstallationMetadata
        ? fetchInstallationMetadata(uri, max, check: check)
        : fetch(uri, max);
    if (brew == null) {
      throw const InstallationFailure('Install Homebrew to use this source.');
    }
    final tap = project.unit.tapFor(project.repository!);
    final token = project.formula.split('/').last;
    final json =
        jsonDecode(
              utf8.decode(
                await metadata(
                  Uri.https(
                    'api.github.com',
                    '/repos/$tap/contents/Formula/$token.rb',
                  ),
                  1024 * 1024,
                ),
              ),
            )
            as Map;
    if (json['encoding'] != 'base64' || json['content'] is! String) {
      throw const InstallationFailure(
        'The tap returned invalid formula metadata.',
      );
    }
    final bytes = base64Decode(
      (json['content'] as String).replaceAll(RegExp(r'\s'), ''),
    );
    final formula = utf8.decode(bytes);
    final versionText = RegExp(
      r'^  version "([^"\n]+)"$',
      multiLine: true,
    ).firstMatch(formula)?.group(1);
    final version = versionText == null ? null : Version.tryParse(versionText);
    if (version == null ||
        version.isPrerelease ||
        !formula.contains('# Generated by rk.')) {
      throw const InstallationFailure(
        'The tap does not contain a supported stable RK formula.',
      );
    }
    if (!project.project.binaryPlatforms.contains(platform) ||
        !formula.contains('-${version.canonical}-$platform.tar.gz')) {
      throw InstallationFailure('The tap does not offer a $platform archive.');
    }
    return _BrewRelease(project, version.canonical, Sha256.hex(bytes), tap);
  }

  @override
  Future<Installation> download(
    ExecutableProject project,
    AvailableInstallation release,
    void Function(String) progress,
  ) async {
    release.validate(project, source);
    if (release is! _BrewRelease || brew == null) {
      throw const InstallationFailure('Invalid Homebrew release.');
    }
    progress('Refreshing Homebrew…');
    await checked(tools, brew!, [
      'tap',
      release.tap,
    ], environment: _environment);
    await checked(tools, brew!, ['update'], environment: _environment);
    // Refresh may discover a release newer than the one the user clicked.
    // Compare the complete formula before allowing Homebrew to execute it.
    // Read bytes directly: `brew cat` can invoke a user-configured pager or
    // even install bat, which is outside this operation's scope.
    final repository = (await checked(tools, brew!, [
      '--repository',
      release.tap,
    ], environment: _environment)).stdout.trim();
    if (!repository.startsWith('/')) {
      throw const InstallationFailure(
        'Homebrew returned a relative tap directory.',
      );
    }
    final formula = File(
      '$repository/Formula/${project.formula.split('/').last}.rb',
    ).readAsBytesSync();
    if (Sha256.hex(formula) != release.digest) {
      throw const InstallationFailure(
        'The Homebrew release changed since the check.',
        'Refresh Available and download again.',
      );
    }
    progress('Installing ${project.name} ${release.version} with Homebrew…');
    final installed = (await inspect(project)).installation;
    await checked(tools, brew!, [
      installed == null ? 'install' : 'upgrade',
      '--formula',
      if (installed == null) '--skip-link',
      project.formula,
    ], environment: _environment);
    final state = await inspect(project);
    return state.installation ??
        (throw InstallationFailure(
          state.problem ?? 'Homebrew did not install the release.',
        ));
  }

  @override
  Future<Installation> install(
    ExecutableProject project,
    void Function(String) progress,
  ) async {
    progress('Installing ${project.formula}…');
    await checked(tools, brew!, [
      'install',
      '--formula',
      '--skip-link',
      project.formula,
    ], environment: _environment);
    final state = await inspect(project);
    return state.installation ??
        (throw InstallationFailure(
          state.problem ?? 'Homebrew did not install ${project.formula}.',
        ));
  }

  @override
  Future<void> uninstall(
    ExecutableProject project,
    Installation installation,
  ) async {
    await checked(tools, brew!, [
      'uninstall',
      '--formula',
      project.formula,
    ], environment: _environment);
  }
}

class _BrewRelease extends AvailableInstallation {
  _BrewRelease(ExecutableProject project, String version, this.digest, this.tap)
    : super(project, InstallationSource.homebrew, version);
  final String digest, tap;
}
