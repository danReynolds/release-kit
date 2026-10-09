/// Native composition root for project-scoped installation commands.
library;

import 'dart:io';

import 'package:rk/src/builds/capability.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/git.dart';
import 'package:rk/src/engine/release_source.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/timings.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/installations/local.dart';
import 'package:rk/src/installations/manager.dart';
import 'package:rk/src/installations/model.dart';
import 'package:rk/src/installations/store.dart';
import 'package:rk/src/output/output.dart';
import 'package:rk/src/targets/github_release/installation.dart';
import 'package:rk/src/targets/homebrew/installation.dart';
import 'package:rk/src/targets/pub_dev/installation.dart';
import 'package:rk/src/tui/use_picker.dart';

const installationUsage = '''
rk use [source] [-p project]       install if needed, then select
rk install [source] [-p project]   prepare without switching
rk uninstall [source] [-p project] remove an inactive installation

Sources: local, homebrew, pub, github — only those configured for this project.
No source: open the matrix in a terminal, or list sources when redirected.
--latest        install: get the latest compatible version; keep the selected source
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
  } on Exception catch (error) {
    final failure = installationFailure(error);
    output.problem(
      Diagnostic(
        code: 'RK-USE-001',
        message: failure.message,
        remedy: failure.remedy,
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
  Timings.report(stderr);
  exitCode = code;
  if (json) stdout.write(output.report.encode(exit: code));
}

/// What [args] ask of rk [command], with the first usage error among them.
({
  String? project,
  String? source,
  bool list,
  bool yes,
  bool latest,
  bool help,
  String? error,
})
_arguments(List<String> args, String command) {
  String? project, source, error;
  var list = false, yes = false, latest = false, help = false;
  final rest = [...args]..remove(command);
  for (var i = 0; i < rest.length && error == null; i++) {
    final arg = rest[i];
    switch (arg) {
      case '--latest':
        latest = true;
      case '--list':
        list = true;
      case '--json': // Owned by the output.
        break;
      case '-y' || '--yes':
        yes = true;
      case '-h' || '--help':
        help = true;
      case _
          when arg == '-p' ||
              arg == '--project' ||
              arg.startsWith('--project='):
        if (project != null) {
          error = 'Name one project only.';
        } else {
          project = arg.startsWith('--project=')
              ? arg.substring(10)
              : ++i < rest.length && !rest[i].startsWith('-')
              ? rest[i]
              : '';
          if (project.isEmpty) error = '$arg needs a package name.';
        }
      case _ when !arg.startsWith('-') && source == null:
        source = arg;
      default:
        error = 'Unexpected argument: $arg';
    }
  }
  if (latest && (command != 'install' || source == null || list)) {
    error = '--latest needs an explicit rk install source.';
  }
  if (latest && source == 'local') error = followsCheckout;
  if (yes && (command != 'uninstall' || source == null || list)) {
    error = '--yes needs an explicit rk uninstall source.';
  }
  if (list && source != null) error = '--list does not select a source.';
  return (
    project: project,
    source: source,
    list: list,
    yes: yes,
    latest: latest,
    help: help,
    error: error,
  );
}

Future<int> _run(
  List<String> args,
  String command,
  Output output,
  bool json,
) async {
  final asked = _arguments(args, command);
  if (asked.error case final usageError?) {
    output.problem(
      Diagnostic(
        code: 'RK-CLI-005',
        message: usageError,
        remedy: 'rk help $command',
      ),
    );
    return ExitCodes.usage;
  }
  if (asked.help) {
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
  final Resolution resolution;
  switch (await ReleaseSource.configIn(
    WorkingTree(root, git: false),
    releasing: false,
  )) {
    case ConfigResolved(resolution: final resolved):
      resolution = resolved;
    case ConfigProblems(:final problems):
      output.problems(problems);
      return ExitCodes.refused;
    case ConfigMissing():
      throw const InstallationFailure(
        'No rk setup found in this directory.',
        'Run inside your project, or start with rk init.',
      );
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
  if (asked.project case final name?) {
    projects = projects.where((p) => p.name == name).toList();
    if (projects.isEmpty) {
      throw InstallationFailure(
        '$name is not an executable project here.',
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
  final source = asked.source == null
      ? null
      : InstallationSource.named(asked.source!);
  if (asked.source != null && source == null) {
    throw InstallationFailure(
      'Unknown source: ${asked.source}',
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
  final platform = HostCapabilities.inspect().hostPlatform;
  final manager = InstallationManager(
    store: store,
    environment: environment,
    providers: {
      InstallationSource.local: LocalInstallationProvider(tools, dart, store),
      InstallationSource.pub: PubInstallationProvider(tools, dart, environment),
      InstallationSource.homebrew: HomebrewInstallationProvider(
        tools,
        findExecutable('brew', environment),
        platform: platform,
      ),
      InstallationSource.github: GithubInstallationProvider(
        tools,
        store,
        platform,
      ),
    },
  );
  final commandAction = InstallationAction.values.byName(command);
  final outcomes = <String>[];
  Future<List<ProjectInstallations>> refresh() async {
    final states = [
      for (final project in projects) await manager.inspect(project),
    ];
    output.report.section('installations', {
      'root': root,
      'managed_bin': store.bin,
      'projects': states.map((s) => s.toJson()).toList(),
      'outcomes': outcomes.toList(),
    });
    return states;
  }

  Future<String> perform(
    Operation operation,
    void Function(String) progress,
  ) async {
    output.report.acted = true;
    final message = await manager.apply(operation, progress: progress);
    outcomes.add(message);
    return message;
  }

  final interactive =
      !json &&
      stdin.hasTerminal &&
      stdout.hasTerminal &&
      environment['TERM'] != 'dumb';
  final states = await refresh();
  if (source == null && !asked.list && interactive) {
    final result = await runUsePicker(
      states: states,
      refresh: refresh,
      check: (project, source, check) =>
          manager.latest(project, source, check: check),
      perform: perform,
      command: 'rk $command',
    );
    // The picker refreshes after operations. Dismissing it is not another
    // inspection: a Homebrew subprocess here delayed even an idle Ctrl+C.
    for (final message in outcomes) {
      _result(output, message);
    }
    if (result.exitCode != 0) return result.exitCode;
    if (result.failure case final failure?) throw InstallationFailure(failure);
    if (outcomes.isEmpty) output.say('No installations changed.');
  } else if (source == null) {
    _list(output, states);
  } else {
    if (commandAction == InstallationAction.uninstall && !asked.yes) {
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
      final release = asked.latest
          ? await manager.latest(projects.single, source)
          : null;
      final result = await perform(
        Operation(projects.single, source, commandAction, release: release),
        (message) => output.say(message),
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

/// The inventory `--list`, or a bare command without a terminal, prints.
void _list(Output output, List<ProjectInstallations> states) {
  for (final state in states) {
    output.line(
      state.project.name == state.project.label
          ? state.project.name
          : '${state.project.name} · ${state.project.label}',
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
                      ? ' · default on PATH'
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
}
