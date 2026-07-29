import 'dart:io';

import 'package:rk/src/commands/status.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/git.dart';
import 'package:rk/src/engine/output.dart';
import 'package:rk/src/engine/registry.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';

const _usage = '''
rk — an austere release tool

Usage: rk [command] [unit]

  status    Where things stand: what is live, what is ready, what is blocking.
  init      Write release.toml for this repository.
  release   Execute a release.
  verify    Prove a published release against what it claims.

Bare `rk` runs status.  -v for detail.
''';

Future<void> main(List<String> args) async {
  final flags = args.where((a) => a.startsWith('-')).toSet();
  final positional = args.where((a) => !a.startsWith('-')).toList();

  final output = Output.stdio(
    verbose: flags.contains('-v') || flags.contains('--verbose'),
  );

  if (flags.contains('-h') || flags.contains('--help')) {
    stdout.write(_usage);
    return;
  }

  final command = positional.isEmpty ? 'status' : positional.first;
  final target = positional.length > 1 ? positional[1] : null;

  switch (command) {
    case 'status':
      exitCode = await _status(output, target);
    case 'init' || 'release' || 'verify':
      output.line('$command is not built yet', mark: Mark.blocked);
      output.say('rk status works today; see doc/plan.md');
      exitCode = ExitCodes.usage;
    default:
      // A bare unit name is the common slip, so try it as one.
      exitCode = await _status(output, command);
  }
}

Future<int> _status(Output output, String? unit) async {
  final root = GitSourceTree.findRoot(Directory.current.path);
  if (root == null) {
    output.line('this is not a git repository', mark: Mark.blocked);
    return ExitCodes.usage;
  }

  final tree = GitSourceTree(root);
  final source = tree.read('release.toml');
  if (source == null) {
    output.heading(root.split('/').last);
    output.blank();
    output.line('no release.toml', mark: Mark.blocked);
    output.say('rk init writes one, and changes nothing else.');
    return ExitCodes.ok;
  }

  final diagnostics = Diagnostics();
  final config = ReleaseConfig.parse(source, 'release.toml', diagnostics);
  final resolution = config == null
      ? null
      : Resolution.resolve(config, tree, diagnostics);

  if (resolution == null) {
    output.heading(root.split('/').last);
    output.blank();
    output.problems(diagnostics.found);
    return ExitCodes.refused;
  }

  final registry = Registry();
  try {
    return await StatusCommand(
      resolution: resolution,
      tree: tree,
      git: GitState.read(root),
      registry: registry,
      output: output,
    ).run(only: unit);
  } finally {
    registry.close();
  }
}
