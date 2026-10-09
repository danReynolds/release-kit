import 'dart:convert';
import 'dart:io';
import 'package:rk/src/transforms/digest.dart';
import 'package:rk/src/transforms/archive.dart';
import 'package:rk/src/installations/metadata.dart';
import 'package:rk/src/engine/release_manifest.dart';
import 'package:rk/src/engine/assets.dart';
import 'dart:typed_data';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/installations/discovery.dart';
import 'package:rk/src/installations/model.dart';
import 'package:rk/src/installations/provider.dart';
import 'package:test/test.dart';

ExecutableProject fixture(
  Directory scratch, {
  String name = 'orbit_cli',
  List<String> commands = const ['orbit', 'orbit_admin'],
  bool binary = false,
}) {
  final root = Directory('${scratch.path}/$name')..createSync(recursive: true);
  File('${root.path}/pubspec.yaml').writeAsStringSync('''
name: $name
version: 1.2.0
environment:
  sdk: ^3.10.4
executables:
${commands.map((c) => '  $c: ${c}_main').join('\n')}
''');
  for (final command in commands) {
    File('${root.path}/bin/${command}_main.dart')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        "import 'dart:io';\nvoid main(List<String> args) { print('$command'); print(Directory.current.path); print(args.join('|')); }\n",
      );
  }
  File('${root.path}/release.toml').writeAsStringSync('''
schema = 2
[release.app]
publish = ["pub.dev"${binary ? ', "github-release", "git-tag", "homebrew"' : ''}]
${binary ? 'binary_platforms = ["linux-x64", "macos-arm64"]' : ''}
''');
  final diagnostics = Diagnostics();
  final tree = FileSystemSourceTree(root.path);
  final config = ReleaseConfig.parse(
    tree.read('release.toml')!,
    'release.toml',
    diagnostics,
  )!;
  final resolution = Resolution.resolve(config, tree, diagnostics);
  expect(diagnostics.found, isEmpty);
  return executableProjects(
    resolution!,
    root.path,
    repository: 'owner/$name',
  ).single;
}

class StubProvider implements InstallationProvider {
  StubProvider(this.source);
  @override
  final InstallationSource source;
  Installation? installed;
  bool fail = false;
  int installs = 0, removals = 0;
  Future<void> Function()? preparing;
  @override
  Future<SourceInspection> inspect(ExecutableProject project) async =>
      SourceInspection(installation: installed);
  @override
  Future<Installation> install(
    ExecutableProject project,
    void Function(String) progress,
  ) async {
    installs++;
    await preparing?.call();
    if (fail) throw const InstallationFailure('Preparation failed.');
    return installed = Installation(
      source: source,
      version: '1.2.0',
      location: '/fixture',
      commands: {
        for (final command in project.commands)
          command: LaunchCommand(
            '/bin/echo',
            arguments: [source.name, command],
          ),
      },
    );
  }

  @override
  Future<void> uninstall(
    ExecutableProject project,
    Installation installation,
  ) async {
    removals++;
    installed = null;
  }
}

class TestTools implements Tools {
  TestTools(this.runTool);
  final Future<ToolResult> Function(
    String,
    List<String>,
    String?,
    Map<String, String>?,
  )
  runTool;
  @override
  Future<ToolResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
  }) => runTool(executable, arguments, workingDirectory, environment);
  @override
  Future<int> runInteractive(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) => throw UnimplementedError();
}

ToolResult ok([String output = '']) =>
    ToolResult(exitCode: 0, stdout: output, stderr: '');

/// A newer release a check found: Pub's 1.3.0 unless said otherwise.
class Release extends AvailableInstallation {
  Release(
    super.project, [
    super.source = InstallationSource.pub,
    super.version = '1.3.0',
  ]);
}

/// A Homebrew prefix on disk, answering the brew commands rk runs. Kegs live
/// in `Cellar/<name>/<version>`, each with a receipt naming its tap, and
/// `opt/<name>` points at the installed one, as Homebrew lays them out.
class FakeHomebrew {
  FakeHomebrew(this.prefix, {this.version = '1.2.0'});
  final String prefix;
  String version;
  final calls = <List<String>>[];
  final environments = <Map<String, String>?>[];

  /// Runs brew for '/brew' and every other executable for real (chmod, the
  /// launchers themselves).
  Tools get tools => TestTools((exe, args, cwd, env) async {
    if (exe != '/brew') {
      return const SystemTools().run(
        exe,
        args,
        workingDirectory: cwd,
        environment: env,
      );
    }
    calls.add(args);
    environments.add(env);
    return run(args);
  });

  String _name(String formula) => formula.split('/').last;
  String _tap(String formula) => formula.substring(0, formula.lastIndexOf('/'));

  /// Installs [formula] at [version] as Homebrew does: a new keg, opt moved
  /// to it. Without [keepOld], the previous keg is cleaned up, as `brew
  /// upgrade` does by default.
  void pour(String formula, String version, {bool keepOld = true}) {
    final name = _name(formula);
    final opt = Link('$prefix/opt/$name');
    final previous = opt.existsSync() ? opt.resolveSymbolicLinksSync() : null;
    final keg = '$prefix/Cellar/$name/$version';
    File('$keg/bin/$name')
      ..createSync(recursive: true)
      ..writeAsStringSync('#!/bin/sh\nprintf "brew $version\\n"\n');
    Process.runSync('/bin/chmod', ['755', '$keg/bin/$name']);
    File('$keg/INSTALL_RECEIPT.json').writeAsStringSync(
      jsonEncode({
        'source': {'tap': _tap(formula)},
      }),
    );
    if (opt.existsSync()) opt.deleteSync();
    opt.createSync(keg, recursive: true);
    if (!keepOld && previous != null && previous != keg) {
      Directory(previous).deleteSync(recursive: true);
    }
  }

  List<String> _kegs(String name) {
    final rack = Directory('$prefix/Cellar/$name');
    if (!rack.existsSync()) return const [];
    return [for (final keg in rack.listSync()) keg.path.split('/').last];
  }

  String? _installedTap(String name) {
    final receipt = File('$prefix/opt/$name/INSTALL_RECEIPT.json');
    if (!receipt.existsSync()) return null;
    return ((jsonDecode(receipt.readAsStringSync()) as Map)['source']
        as Map)['tap'];
  }

  ToolResult run(List<String> args) {
    switch (args) {
      case ['--prefix']:
        return ok(prefix);
      case ['--cellar']:
        return ok('$prefix/Cellar');
      case ['list', '--formula', '--full-name', '-1']:
        final rack = Directory('$prefix/Cellar');
        return ok(
          [
            if (rack.existsSync())
              for (final entry in rack.listSync())
                if (_installedTap(entry.path.split('/').last) case final tap?)
                  '$tap/${entry.path.split('/').last}',
          ].join('\n'),
        );
      case ['info', '--json=v2', '--formula', final formula]:
        final name = _name(formula);
        final ours = _installedTap(name) == _tap(formula);
        final opt = Link('$prefix/opt/$name');
        return ok(
          jsonEncode({
            'formulae': [
              {
                'full_name': formula,
                'name': name,
                'linked_keg': ours && opt.existsSync()
                    ? opt.resolveSymbolicLinksSync().split('/').last
                    : null,
                'installed': [
                  if (ours)
                    for (final keg in _kegs(name)) {'version': keg},
                ],
              },
            ],
          }),
        );
      case ['install', '--formula', '--skip-link', final formula]:
        pour(formula, version);
        return ok();
      case ['upgrade', '--formula', final formula]:
        pour(formula, version);
        return ok();
      case ['uninstall', '--formula', final formula]:
        final name = _name(formula);
        Directory('$prefix/Cellar/$name').deleteSync(recursive: true);
        Link('$prefix/opt/$name').deleteSync();
        return ok();
    }
    throw StateError('unexpected brew $args');
  }
}

/// Public GitHub releases of a single-command [project], served without a
/// network. Each release's archive holds a script that prints its version.
class FakeReleases {
  FakeReleases(this.project, Iterable<String> versions) {
    versions.forEach(publish);
  }
  final ExecutableProject project;
  final _archives = <String, Uint8List>{};
  int archiveFetches = 0;

  void publish(String version) {
    _archives[version] = Uint8List.fromList(
      ArchiveBuilder.gzip(
        ArchiveBuilder.tar([
          ArchiveEntry(
            name: project.commands.single,
            bytes: utf8.encode('#!/bin/sh\nprintf "release $version\\n"\n'),
            executable: true,
          ),
        ]),
      ),
    );
  }

  String _archive(String version) =>
      ReleaseAssets.archiveName(project.commands.single, version, 'linux-x64');

  Future<Uint8List> fetch(
    Uri uri,
    int limit, {
    InstallationCheck? check,
  }) async {
    if (uri.host == 'api.github.com') {
      return Uint8List.fromList(
        utf8.encode(
          jsonEncode([
            for (final version in _archives.keys.toList().reversed)
              {
                'tag_name': 'v$version',
                'draft': false,
                'prerelease': false,
                'assets': [
                  {'name': ReleaseAssets.manifest},
                  {'name': _archive(version)},
                ],
              },
          ]),
        ),
      );
    }
    final tag = uri.pathSegments[uri.pathSegments.length - 2];
    final version = tag.substring(1);
    final archive = _archives[version]!;
    if (uri.pathSegments.last == ReleaseAssets.manifest) {
      return Uint8List.fromList(
        utf8.encode(
          ReleaseManifest(
            unit: project.unit.name,
            version: version,
            tag: tag,
            commit: 'a' * 40,
            artifacts: [
              ReleaseManifestArtifact(
                name: _archive(version),
                type: 'archive',
                size: archive.length,
                sha256: Sha256.hex(archive),
              ),
            ],
          ).encode(),
        ),
      );
    }
    archiveFetches++;
    return archive;
  }
}
