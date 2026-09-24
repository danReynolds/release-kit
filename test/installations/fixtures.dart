import 'dart:io';
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
