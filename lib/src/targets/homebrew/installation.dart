import 'dart:convert';
import 'dart:io';

import '../../engine/tools.dart';
import '../../installations/model.dart';
import '../../installations/provider.dart';

class HomebrewInstallationProvider implements InstallationProvider {
  HomebrewInstallationProvider(this.tools, this.brew);
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
