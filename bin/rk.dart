import 'dart:io';

import 'package:rk/src/commands/init.dart';
import 'package:rk/src/commands/release.dart';
import 'package:rk/src/commands/status.dart';
import 'package:rk/src/commands/verify.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnosis.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/git.dart';
import 'package:rk/src/engine/output.dart';
import 'package:rk/src/engine/registry.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/engine/workspace.dart';

const _usage = '''
rk — an austere release tool

Usage: rk [command] [unit]

  status    Where things stand: what is live, what is ready, what is blocking.
  init      Write release.toml for this repository.
  release   Execute a release.
  verify    Prove a published release against what it claims.

Bare `rk` runs status.  -v for detail, --json for a caller.
''';

Future<void> main(List<String> args) async {
  const known = {
    '-v',
    '--verbose',
    '-h',
    '--help',
    '--dry-run',
    '--offline',
    '--json',
  };
  final flags = args.where((a) => a.startsWith('-')).toSet();
  final positional = args.where((a) => !a.startsWith('-')).toList();

  final unknown = flags.difference(known);
  if (unknown.isNotEmpty) {
    // Silently ignoring a flag is worse than refusing it: a caller asking for
    // something rk does not do should be told, not answered as if it had not
    // asked.
    stderr.writeln('rk does not have ${unknown.join(', ')}');
    stderr.write(_usage);
    exitCode = ExitCodes.usage;
    return;
  }

  if (flags.contains('-h') || flags.contains('--help')) {
    stdout.write(_usage);
    return;
  }

  final command = positional.isEmpty ? 'status' : positional.first;
  final target = positional.length > 1 ? positional[1] : null;
  final json = flags.contains('--json');

  final output = Output.stdio(
    verbose: flags.contains('-v') || flags.contains('--verbose'),
    json: json,
    command: command,
  );

  final code = switch (command) {
    'status' => await _status(
        output,
        target,
        offline: flags.contains('--offline'),
      ),
    'verify' => await _verify(output, target),
    'release' => await _release(
        output,
        target,
        dryRun: flags.contains('--dry-run'),
      ),
    'init' => await _init(output),
    // A bare unit name is the common slip, so try it as one.
    _ => await _status(output, command),
  };

  exitCode = code;

  // The machine surface survives a non-zero exit because it is written here,
  // after the code is known, rather than by whichever path decided to stop.
  if (json) stdout.write(output.report.encode(exit: code));

  _recordDiagnosis(output, code);
}

/// Writes the evidence for a run that got as far as the work and then failed.
///
/// Only then: a refusal that never looked at a step — an unreadable
/// release.toml — has already said everything it knows on stdout, and copying
/// that into a directory would fill `.rk/diagnosis` with typos while teaching
/// an operator to ignore it.
void _recordDiagnosis(Output output, int code) {
  if (code == ExitCodes.ok || code == ExitCodes.usage) return;
  if (!output.report.hasSteps) return;
  final root = GitSourceTree.findRoot(Directory.current.path);
  if (root == null) return;

  final at = Diagnosis.write(
    DirectoryWorkspace(root),
    stamp: DateTime.now().toIso8601String().replaceAll(':', '-'),
    report: output.report,
    exit: code,
  );
  output.say('what this run saw: $at');
}

Future<int> _init(Output output) async {
  final root = GitSourceTree.findRoot(Directory.current.path);
  if (root == null) {
    output.line('this is not a git repository', mark: Mark.blocked);
    return ExitCodes.usage;
  }
  final tree = GitSourceTree(root);

  return InitCommand(
    tree: tree,
    output: output,
    write: (path, contents) => File('$root/$path').writeAsStringSync(contents),
    confirm: stdin.hasTerminal
        ? (prompt) async {
            stdout.write(prompt);
            final answer = stdin.readLineSync()?.trim().toLowerCase() ?? '';
            return answer.isEmpty || answer == 'y' || answer == 'yes';
          }
        : null,
  ).run();
}

Future<int> _release(
  Output output,
  String? unit, {
  required bool dryRun,
}) async {
  final prepared = _prepare(output);
  if (!prepared.isReady) return prepared.code!;
  final resolution = prepared.resolution!;
  final tree = prepared.tree!;
  final registry = prepared.registry!;
  try {
    return await ReleaseCommand(
      resolution: resolution,
      tree: tree,
      git: GitState.read(tree.root),
      registry: registry,
      tools: const SystemTools(),
      output: output,
      confirm: promptOnTerminal,
      dryRun: dryRun,
    ).run(only: unit);
  } finally {
    registry.close();
  }
}

Future<int> _verify(Output output, String? unit) async {
  final prepared = _prepare(output);
  if (!prepared.isReady) return prepared.code!;
  final resolution = prepared.resolution!;
  final registry = prepared.registry!;
  try {
    return await VerifyCommand(
      resolution: resolution,
      registry: registry,
      output: output,
    ).run(only: unit);
  } finally {
    registry.close();
  }
}

/// What reading the repository produced: either everything a command needs,
/// or the exit code that reading it decided.
///
/// Not-onboarded is exit 0, since a repository without a release.toml is a
/// correct answer rather than a failure — an agent sweeping a fleet must not
/// see a fault for every repository that simply does not use rk.
class _Prepared {
  _Prepared.ready(this.resolution, this.tree, this.registry) : code = null;
  _Prepared.stopped(this.code)
      : resolution = null,
        tree = null,
        registry = null;

  final Resolution? resolution;
  final GitSourceTree? tree;
  final Registry? registry;
  final int? code;

  bool get isReady => code == null;
}

_Prepared _prepare(Output output) {
  final root = GitSourceTree.findRoot(Directory.current.path);
  if (root == null) {
    output.line('this is not a git repository', mark: Mark.blocked);
    output.say('rk releases from a repository, and reads its tags and '
        'history to know what is already out.');
    return _Prepared.stopped(ExitCodes.usage);
  }

  final tree = GitSourceTree(root);
  final source = tree.read('release.toml');
  if (source == null) {
    output.repository(name: root.split('/').last);
    output.blank();
    output.line('no release.toml', mark: Mark.none);
    output.say('rk init writes one, and changes nothing else.');
    return _Prepared.stopped(ExitCodes.ok);
  }

  final diagnostics = Diagnostics();
  final config = ReleaseConfig.parse(source, 'release.toml', diagnostics);
  final resolution =
      config == null ? null : Resolution.resolve(config, tree, diagnostics);

  if (resolution == null) {
    output.repository(name: root.split('/').last);
    output.blank();
    output.problems(diagnostics.found);
    return _Prepared.stopped(ExitCodes.refused);
  }

  return _Prepared.ready(resolution, tree, Registry());
}

Future<int> _status(
  Output output,
  String? unit, {
  bool offline = false,
}) async {
  final prepared = _prepare(output);
  if (!prepared.isReady) return prepared.code!;
  final resolution = prepared.resolution!;
  final tree = prepared.tree!;
  final registry = prepared.registry!;
  try {
    return await StatusCommand(
      resolution: resolution,
      tree: tree,
      git: GitState.read(tree.root),
      registry: registry,
      output: output,
      offline: offline,
    ).run(only: unit);
  } finally {
    registry.close();
  }
}
