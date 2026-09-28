/// Native composition root for project-scoped installation commands.
library;

import 'dart:io';

import 'package:rk/src/builds/capability.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/git.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/installations/discovery.dart';
import 'package:rk/src/installations/local.dart';
import 'package:rk/src/installations/manager.dart';
import 'package:rk/src/installations/model.dart';
import 'package:rk/src/installations/shell_routing.dart';
import 'package:rk/src/installations/store.dart';
import 'package:rk/src/output/output.dart';
import 'package:rk/src/targets/github_release/installation.dart';
import 'package:rk/src/targets/homebrew/installation.dart';
import 'package:rk/src/targets/pub_dev/installation.dart';
import 'package:rk/src/tui/installation_picker.dart';
import 'package:rk/src/tui/use_picker.dart';

const installationUsage = '''
rk use [source] [-p project]       install if needed, then select
rk install [source] [-p project]   prepare without switching
rk uninstall [source] [-p project] remove an inactive installation

Sources: local, homebrew, pub, github — only those configured for this project.
No source: open the matrix in a terminal, or list sources when redirected.
--list          inspect available sources and current selection; no changes
-p, --project   package name; required for an explicit source in a multi-app repo
--json          one structured report, no TUI or prompts
-y, --yes       uninstall: confirm removal of that exact installation

Run inside a directory containing release.toml, or one of its descendants.
SDK packages are not installations. A project's commands switch together.
''';

Future<void> installationMain(List<String> args, String command) async {
  final json = args.contains('--json');
  final output = Output.stdio(json: json, command: command);
  var code = ExitCodes.ok;
  try {
    code = await _run(args, command, output, json);
  } on InstallationFailure catch (error) {
    output.problem(
      Diagnostic(
        code: 'RK-USE-001',
        message: error.message,
        remedy: error.remedy,
      ),
    );
    code = ExitCodes.refused;
  } on FileSystemException catch (error) {
    output.problem(
      Diagnostic(
        code: 'RK-USE-002',
        message: 'Installation files could not be accessed.',
        remedy: error.toString(),
      ),
    );
    code = ExitCodes.refused;
  } on FormatException catch (error) {
    output.problem(
      Diagnostic(
        code: 'RK-USE-002',
        message: 'Installation metadata could not be read.',
        remedy: '$error',
      ),
    );
    code = ExitCodes.refused;
  } on Object catch (error) {
    output.problem(
      Diagnostic(
        code: 'RK-INT-001',
        message: 'Installation failed unexpectedly: $error',
        remedy: 'Inspect rk use --list before retrying.',
      ),
    );
    code = ExitCodes.crashed;
  } finally {
    output.close();
  }
  exitCode = code;
  if (json) stdout.write(output.report.encode(exit: code));
}

Future<int> _run(
  List<String> args,
  String command,
  Output output,
  bool json,
) async {
  String? projectName, sourceName;
  var list = false, yes = false, help = false, seenCommand = false;
  String? usageError;
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == command && !seenCommand) {
      seenCommand = true;
      continue;
    }
    if (arg == '-p' || arg == '--project' || arg.startsWith('--project=')) {
      if (projectName != null) {
        usageError = 'Name one project only.';
        break;
      }
      if (arg.startsWith('--project=')) {
        projectName = arg.substring(10);
      } else if (++i < args.length && !args[i].startsWith('-')) {
        projectName = args[i];
      } else {
        usageError = '$arg needs a package name.';
        break;
      }
      if (projectName.isEmpty) usageError = '$arg needs a package name.';
    } else if (arg == '--list') {
      list = true;
    } else if (arg == '--json') {
      /* Owned by the output. */
    } else if (arg == '-y' || arg == '--yes') {
      yes = true;
    } else if (arg == '-h' || arg == '--help') {
      help = true;
    } else if (!arg.startsWith('-') && sourceName == null) {
      sourceName = arg;
    } else {
      usageError = 'Unexpected argument: $arg';
      break;
    }
  }
  if (yes && (command != 'uninstall' || sourceName == null || list)) {
    usageError = '--yes needs an explicit rk uninstall source.';
  }
  if (list && sourceName != null) {
    usageError = '--list does not select a source.';
  }
  if (usageError != null) {
    output.problem(
      Diagnostic(
        code: 'RK-CLI-005',
        message: usageError,
        remedy: installationUsage,
      ),
    );
    return ExitCodes.usage;
  }
  if (help) {
    output.help(installationUsage);
    output.report.next(installationUsage);
    return ExitCodes.ok;
  }
  if (!Platform.isMacOS && !Platform.isLinux) {
    throw const InstallationFailure(
      'Installation switching currently supports macOS and Linux.',
    );
  }
  Directory? directory = Directory.current.absolute;
  String? root;
  while (directory != null) {
    if (File('${directory.path}/release.toml').existsSync()) {
      root = directory.resolveSymbolicLinksSync();
      break;
    }
    // Do not cross a nested repository into another application's config.
    if (FileSystemEntity.typeSync('${directory.path}/.git') !=
        FileSystemEntityType.notFound) {
      break;
    }
    final parent = directory.parent;
    directory = parent.path == directory.path ? null : parent;
  }
  if (root == null) {
    throw const InstallationFailure(
      'No rk setup found in this directory.',
      'Run inside your project, or start with rk init.',
    );
  }
  final tree = FileSystemSourceTree(root);
  final diagnostics = Diagnostics();
  final config = ReleaseConfig.parse(
    tree.read('release.toml')!,
    'release.toml',
    diagnostics,
  );
  final resolution = config == null
      ? null
      : Resolution.resolve(config, tree, diagnostics);
  if (resolution == null || diagnostics.isNotEmpty) {
    output.problems(diagnostics.found);
    return ExitCodes.refused;
  }
  // Installation discovery needs only the origin, not release preflight's
  // worktree status, tags, signing configuration or branch ancestry.
  final repository = await GitState.readOrigin(root);
  final discovered = executableProjects(
    resolution,
    root,
    repository: repository,
  );
  var projects = discovered;
  if (projectName != null) {
    projects = projects.where((p) => p.name == projectName).toList();
    if (projects.isEmpty) {
      throw InstallationFailure(
        '$projectName is not an executable project here.',
        'Executable projects: ${discovered.map((p) => p.name).join(', ')}.',
      );
    }
  }
  if (projects.isEmpty) {
    throw const InstallationFailure(
      'This configuration contains no executable projects.',
      'Libraries are consumed as dependencies; they cannot be selected with rk use.',
    );
  }
  final source = sourceName == null
      ? null
      : InstallationSource.named(sourceName);
  if (sourceName != null && source == null) {
    throw InstallationFailure(
      'Unknown source: $sourceName',
      'Use rk $command --list to see supported sources.',
    );
  }
  if (source != null && projects.length != 1) {
    throw InstallationFailure(
      'Choose one executable project.',
      'Add -p ${projects.first.name}, or run rk $command for the matrix. Available: ${projects.map((p) => p.name).join(', ')}.',
    );
  }
  if (source != null && !projects.single.sources.contains(source)) {
    throw InstallationFailure(
      '${projects.single.name} does not support ${source.label}.',
      'Available sources: ${projects.single.sources.map((s) => s.name).join(', ')}.',
    );
  }
  final environment = Map<String, String>.of(Platform.environment);
  final tools = const SystemTools();
  final store = InstallationStore(
    InstallationStore.defaultRoot(environment),
    tools,
  );
  final dart = findExecutable('dart', environment);
  final manager = InstallationManager(
    store: store,
    environment: environment,
    providers: {
      InstallationSource.local: LocalInstallationProvider(tools, dart, store),
      InstallationSource.pub: PubInstallationProvider(tools, dart, environment),
      InstallationSource.homebrew: HomebrewInstallationProvider(
        tools,
        findExecutable('brew', environment),
      ),
      InstallationSource.github: GithubInstallationProvider(
        tools,
        store,
        HostCapabilities.inspect().hostPlatform,
      ),
    },
  );
  final action = InstallationAction.values.byName(command);
  final outcomes = <String>[];
  Future<List<ProjectInstallations>> refresh() async {
    final states = [
      for (final project in projects) await manager.inspect(project),
    ];
    output.report.installations({
      'root': root,
      'managed_bin': store.bin,
      'projects': states.map((s) => s.toJson()).toList(),
      'outcomes': outcomes.toList(),
    });
    return states;
  }

  Future<String> operate(
    ExecutableProject project,
    InstallationSource source,
    void Function(String) progress,
    InstallationCancellation cancellation,
  ) async {
    output.report.acted = true;
    final result = await manager.act(
      project,
      source,
      action,
      progress: progress,
      cancellation: cancellation,
    );
    final routing = action == InstallationAction.use
        ? await ShellRouting(store, tools, environment).ensure(project)
        : null;
    final message = [result, if (routing != null) routing].join('\n');
    outcomes.add(message);
    return message;
  }

  final interactive =
      !json &&
      stdin.hasTerminal &&
      stdout.hasTerminal &&
      environment['TERM'] != 'dumb';
  final states = await refresh();
  if (source == null && !list && interactive) {
    final result = action == InstallationAction.use
        ? await runUsePicker(
            states: states,
            refresh: refresh,
            use: operate,
            checkAvailable: (project, source, check) =>
                manager.latest(project, source, check: check),
            downloadAvailable:
                (project, release, progress, cancellation) async {
                  output.report.acted = true;
                  final message = await manager.download(
                    project,
                    release,
                    progress: progress,
                    cancellation: cancellation,
                  );
                  outcomes.add(message);
                  return message;
                },
          )
        : await runInstallationPicker(
            action: action,
            states: states,
            refresh: refresh,
            operate: operate,
          );
    // The picker refreshes after operations. Dismissing it is not another
    // inspection: a Homebrew subprocess here delayed even an idle Ctrl+C.
    for (final message in outcomes) {
      _result(output, message);
    }
    if (result.exitCode != 0) return result.exitCode;
    if (result.failed) throw InstallationFailure(result.message);
    if (outcomes.isEmpty) output.say('No installations changed.');
  } else if (source == null) {
    for (final state in states) {
      output.line(
        '${state.project.name} · ${state.project.label}',
        strong: true,
      );
      for (final e in state.sources.entries) {
        output.line(
          e.key.label,
          depth: 1,
          mark: state.selected == e.key || state.currentSource == e.key
              ? Mark.done
              : Mark.none,
          note:
              e.value.problem ??
              (e.value.installation == null
                  ? 'Not installed'
                  : '${e.value.installation!.version}${state.currentSource == e.key
                        ? ' · using'
                        : state.selected == e.key
                        ? ' · selected'
                        : ' · installed'}'),
        );
        if (e.key == InstallationSource.local && e.value.installation != null) {
          output.line(
            e.value.installation!.location,
            depth: 2,
            role: VisualRole.secondary,
          );
        }
      }
      for (final problem in state.routing) {
        output.line(problem, mark: Mark.warning);
      }
    }
  } else {
    if (action == InstallationAction.uninstall && !yes) {
      if (!interactive) {
        throw const InstallationFailure(
          'Removal needs confirmation.',
          'Repeat the same rk uninstall command with --yes to confirm.',
        );
      }
      final installation = states.single.sources[source]?.installation;
      output.prompt(
        'Remove ${projects.single.name} from ${source.label}${installation == null ? '' : ' (${installation.version})'}? [y/N] ',
      );
      if (!{'y', 'yes'}.contains(stdin.readLineSync()?.trim().toLowerCase())) {
        output.say('Nothing removed.');
        return ExitCodes.ok;
      }
    }
    try {
      final result = await operate(
        projects.single,
        source,
        (message) => output.say(message),
        InstallationCancellation(),
      );
      _result(output, result);
    } finally {
      await refresh();
    }
  }
  return ExitCodes.ok;
}

void _result(Output output, String message) {
  final lines = message.split('\n');
  for (var i = 0; i < lines.length; i++) {
    output.line(lines[i], mark: i == 0 ? Mark.done : Mark.none);
  }
}
