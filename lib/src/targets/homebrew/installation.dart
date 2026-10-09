import 'dart:convert';
import 'dart:io';

import '../../engine/tools.dart';
import '../../builds/capability.dart';
import '../../engine/version.dart';
import '../../installations/metadata.dart';
import '../../transforms/digest.dart';
import '../../installations/model.dart';
import '../../installations/provider.dart';

class HomebrewInstallationProvider implements InstallationProvider {
  HomebrewInstallationProvider(
    this.tools,
    this.brew, {
    this.fetch = fetchHttps,
    String? platform,
  }) : platform = platform ?? HostCapabilities.inspect().hostPlatform;
  final String platform;
  final HttpsFetch fetch;
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

  /// `brew --prefix`, asked once: it does not change during a run.
  Future<String>? _prefix;
  Future<String> _brewPrefix() => _prefix ??= () async {
    final prefix = (await checked(tools, brew!, [
      '--prefix',
    ], environment: _environment)).stdout.trim();
    if (!prefix.startsWith('/')) {
      throw const InstallationFailure('Homebrew returned a relative prefix.');
    }
    return prefix;
  }();

  @override
  Future<SourceInspection> inspect(ExecutableProject project) async {
    if (brew == null) {
      return const SourceInspection(
        problem: 'Install Homebrew to use this source.',
      );
    }
    // Homebrew points opt/<name> at the installed keg, even with --skip-link,
    // and moves it on upgrade, so launchers go through it. The keg's receipt
    // names the tap that installed it: what `brew list --full-name` reads,
    // without starting Homebrew's Ruby for each of `list` and `info` (about a
    // second on every rk use).
    final prefix = await _brewPrefix();
    final name = project.formula.split('/').last;
    final tap = project.formula.substring(0, project.formula.lastIndexOf('/'));
    final opt = '$prefix/opt/$name';
    if (FileSystemEntity.typeSync(opt, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return const SourceInspection();
    }
    final receipt = File('$opt/INSTALL_RECEIPT.json');
    if (!receipt.existsSync()) {
      return SourceInspection(
        problem:
            'The Homebrew installation is incomplete. Repair it with brew reinstall ${project.formula}.',
      );
    }
    final installedFrom =
        ((jsonDecode(receipt.readAsStringSync()) as Map)['source']
            as Map?)?['tap'];
    if (installedFrom is! String || installedFrom.toLowerCase() != tap) {
      // A formula of the same name from another tap is not this project.
      return const SourceInspection();
    }
    for (final command in project.commands) {
      if (!File('$opt/bin/$command').existsSync()) {
        return SourceInspection(
          problem:
              'Homebrew is missing $command. Repair it with brew reinstall ${project.formula}.',
        );
      }
    }
    final keg = Directory(opt).resolveSymbolicLinksSync();
    return SourceInspection(
      installation: Installation(
        source: source,
        version: keg.split('/').last,
        location: keg,
        exportedPaths: [
          for (final command in project.commands) '$prefix/bin/$command',
        ],
        commands: {
          for (final command in project.commands)
            command: LaunchCommand('$opt/bin/$command'),
        },
      ),
    );
  }

  @override
  Future<AvailableInstallation> latest(
    ExecutableProject project, {
    InstallationCheck? check,
  }) async {
    if (brew == null) {
      throw const InstallationFailure('Install Homebrew to use this source.');
    }
    final tap = project.unit.tapFor(project.repository!);
    final token = project.formula.split('/').last;
    final json =
        jsonDecode(
              utf8.decode(
                await fetch(
                  Uri.https(
                    'api.github.com',
                    '/repos/$tap/contents/Formula/$token.rb',
                  ),
                  1024 * 1024,
                  check: check,
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
    return AvailableInstallation(version.canonical, sha256: Sha256.hex(bytes));
  }

  /// Installs without linking into Homebrew's bin. A checked [release]
  /// refreshes the tap first and upgrades an installed formula; the launcher
  /// runs it through `opt/<name>` either way.
  @override
  Future<Installation> install(
    ExecutableProject project,
    AvailableInstallation? release,
    void Function(String) progress,
  ) async {
    var upgrade = false;
    if (release == null) {
      progress('Installing ${project.formula}…');
    } else {
      final tap = project.unit.tapFor(project.repository!);
      progress('Refreshing Homebrew…');
      await checked(tools, brew!, ['tap', tap], environment: _environment);
      await checked(tools, brew!, ['update'], environment: _environment);
      // Refresh may discover a release newer than the one the user clicked.
      // Compare the complete formula before allowing Homebrew to execute it.
      // Read bytes directly: `brew cat` can invoke a user-configured pager or
      // even install bat, which is outside this operation's scope.
      final repository = (await checked(tools, brew!, [
        '--repository',
        tap,
      ], environment: _environment)).stdout.trim();
      if (!repository.startsWith('/')) {
        throw const InstallationFailure(
          'Homebrew returned a relative tap directory.',
        );
      }
      final formula = File(
        '$repository/Formula/${project.formula.split('/').last}.rb',
      ).readAsBytesSync();
      if (Sha256.hex(formula) != release.sha256) {
        throw const InstallationFailure(
          'The Homebrew release changed since the check.',
          'Refresh Available and download again.',
        );
      }
      progress('Installing ${project.name} ${release.version} with Homebrew…');
      upgrade = (await inspect(project)).installation != null;
    }
    await checked(tools, brew!, [
      upgrade ? 'upgrade' : 'install',
      '--formula',
      if (!upgrade) '--skip-link',
      project.formula,
    ], environment: _environment);
    return inspectedAfterInstall(this, project);
  }

  @override
  Future<void> uninstall(ExecutableProject project) async {
    await checked(tools, brew!, [
      'uninstall',
      '--formula',
      project.formula,
    ], environment: _environment);
  }
}
