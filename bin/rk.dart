import 'dart:io';

import 'package:rk/src/commands/init.dart';
import 'package:rk/src/commands/release.dart';
import 'package:rk/src/commands/status.dart';
import 'package:rk/src/commands/verify.dart';
import 'package:rk/src/engine/compare.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnosis.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/git.dart';
import 'package:rk/src/engine/inspect.dart';
import 'package:rk/src/engine/output.dart';
import 'package:rk/src/engine/registry.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/tools.dart';

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
  // `--at=<ref>` carries a value, so it is peeled before the set membership
  // checks that every other flag goes through.
  String? at;
  var atEmpty = false;
  final flags = <String>{};
  for (final arg in args.where((a) => a.startsWith('-'))) {
    if (arg.startsWith('--at=')) {
      at = arg.substring('--at='.length);
      if (at.isEmpty) atEmpty = true;
      continue;
    }
    flags.add(arg);
  }
  final positional = args.where((a) => !a.startsWith('-')).toList();
  final json = flags.contains('--json');

  // A bare unit name is the common slip, so an unrecognised verb is tried as
  // one — but the verb is decided here, once, so that every path below agrees
  // on what ran and no flag is quietly dropped by a fallthrough.
  const verbs = {'status', 'verify', 'release', 'init'};
  final first = positional.isEmpty ? null : positional.first;
  final command = first == null || !verbs.contains(first) ? 'status' : first;
  final target = first != null && !verbs.contains(first)
      ? first
      : (positional.length > 1 ? positional[1] : null);

  final output = Output.stdio(
    verbose: flags.contains('-v') || flags.contains('--verbose'),
    json: json,
    command: command,
  );

  // A flag that exists but does not apply to this verb is refused the same
  // way as one that does not exist: `rk release --offline` performing live
  // reads under a flag that promises none is worse than an error.
  const perVerb = {
    'status': {'-v', '--verbose', '-h', '--help', '--json', '--offline'},
    'verify': {'-v', '--verbose', '-h', '--help', '--json'},
    'release': {'-v', '--verbose', '-h', '--help', '--json', '--dry-run'},
    'init': {'-v', '--verbose', '-h', '--help', '--json'},
  };
  final inapplicable = {
    ...flags.difference(perVerb[command] ?? known),
    if (at != null && command != 'verify') '--at=<ref>',
  };
  final unknown = flags.difference(known);
  if (unknown.isNotEmpty) {
    // Silently ignoring a flag is worse than refusing it: a caller asking for
    // something rk does not do should be told, not answered as if it had not
    // asked. It is told through the report as well, so a refusal a caller
    // asked for in JSON is not answered in prose it cannot read.
    output.problem(
      Diagnostic(
        code: 'RK-CLI-001',
        message: 'rk does not have ${unknown.join(', ')}',
        remedy: _usage.trim(),
      ),
    );
    exitCode = ExitCodes.usage;
    if (json) stdout.write(output.report.encode(exit: ExitCodes.usage));
    return;
  }

  if (inapplicable.isNotEmpty &&
      !flags.contains('-h') &&
      !flags.contains('--help')) {
    output.problem(
      Diagnostic(
        code: 'RK-CLI-005',
        message: 'rk $command does not have ${inapplicable.join(', ')}',
        remedy: _usage.trim(),
      ),
    );
    exitCode = ExitCodes.usage;
    if (json) stdout.write(output.report.encode(exit: ExitCodes.usage));
    return;
  }

  // Misuse is refused, not repaired: an empty ref would be resolved as
  // something, and a third word would be dropped as if it had not been said.
  if (atEmpty || positional.length > 2) {
    output.problem(
      Diagnostic(
        code: 'RK-CLI-007',
        message: atEmpty
            ? '--at= names no ref'
            : 'rk takes a verb and a unit, and got '
                '"${positional.join(' ')}"',
        remedy: _usage.trim(),
      ),
    );
    exitCode = ExitCodes.usage;
    if (json) stdout.write(output.report.encode(exit: ExitCodes.usage));
    return;
  }

  if (flags.contains('-h') || flags.contains('--help')) {
    // Under --json stdout carries the document and nothing else, so the usage
    // travels inside it rather than beside it.
    if (json) {
      output.report.next(_usage.trim());
      stdout.write(output.report.encode(exit: ExitCodes.ok));
    } else {
      stdout.write(_usage);
    }
    return;
  }

  int code;
  String? crash;
  try {
    code = switch (command) {
      'verify' => await _verify(output, target, at: at),
      'release' => await _release(
          output,
          target,
          dryRun: flags.contains('--dry-run'),
          interactive: !json,
        ),
      'init' => await _init(output, interactive: !json),
      _ => await _status(
          output,
          target,
          offline: flags.contains('--offline'),
        ),
    };
  } on Object catch (error, stack) {
    code = ExitCodes.refused;
    crash = '$error\n$stack';
    // `status` and `verify` change nothing, so a crash in one of them did not
    // act — saying "an effect may exist" there would teach a reader to
    // discount the sentence everywhere it is true.
    const readOnly = {'status', 'verify'};
    output.halt(
      readOnly.contains(command) ? HaltKind.beforeActing : HaltKind.lostTrack,
    );
    output.problem(
      Diagnostic(
        code: 'RK-INT-001',
        message: 'rk failed in a way it does not have a message for: $error',
        remedy: 'this is a bug in rk. The run\'s evidence is written beside '
            'this message, and re-running will inspect what is really there.',
      ),
    );
  } finally {
    // Rendering owns a repeating timer while a step is running, and a timer
    // keeps the isolate alive. Without this, a thrown exception turns a crash
    // into a hang.
    output.close();
  }

  _recordDiagnosis(output, code, crash: crash);

  exitCode = code;

  // The machine surface survives a non-zero exit — including a crash — because
  // it is written here, after the code is known, rather than by whichever path
  // decided to stop.
  if (json) stdout.write(output.report.encode(exit: code));
}

/// Writes the evidence for a run that began changing things and then failed.
///
/// Only then: a refusal that never acted — an unreadable release.toml — has
/// already said everything it knows on stdout, and copying that into a
/// directory would fill `.rk/diagnosis` with typos while teaching an operator
/// to ignore it. A crash is recorded whatever it was doing, because the stack
/// trace is the only copy of what went wrong.
void _recordDiagnosis(Output output, int code, {String? crash}) {
  if (code == ExitCodes.ok || code == ExitCodes.usage) return;
  if (!output.report.acted && crash == null) return;
  final root = GitSourceTree.findRoot(Directory.current.path);
  if (root == null) return;

  final at = Diagnosis.write(
    root,
    stamp: DateTime.now().toIso8601String().replaceAll(':', '-'),
    report: output.report,
    exit: code,
    attachments: {if (crash != null) 'crash.txt': crash},
  );
  output.report.diagnosis = at;
  output.say('what this run saw: $at');
}

Future<int> _init(Output output, {required bool interactive}) async {
  final root = GitSourceTree.findRoot(Directory.current.path);
  if (root == null) {
    output.problem(
      Diagnostic(
        code: 'RK-CLI-002',
        message: 'this is not a git repository',
        remedy: 'rk releases from a repository, and reads its tags and '
            'history to know what is already out.',
      ),
    );
    return ExitCodes.usage;
  }
  final tree = GitSourceTree(root);

  return InitCommand(
    tree: tree,
    output: output,
    write: (path, contents) => File('$root/$path').writeAsStringSync(contents),
    // A prompt would be written straight to stdout, past the sink that --json
    // silences, so asking is not an option when a caller is parsing the
    // answer. init already refuses when nobody can confirm.
    confirm: interactive && stdin.hasTerminal
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
  required bool interactive,
}) async {
  final prepared = _prepare(output);
  if (!prepared.isReady) return prepared.code!;
  final resolution = prepared.resolution!;
  final tree = prepared.tree!;
  final registry = prepared.registry!;
  final git = GitState.read(tree.root);
  try {
    return await ReleaseCommand(
      resolution: resolution,
      tree: tree,
      git: git,
      registry: registry,
      inspector: Inspector(
        registry: registry,
        git: git,
        tools: const SystemTools(),
        repository: git.originUrl,
      ),
      comparator: Comparator(tools: const SystemTools()),
      tools: const SystemTools(),
      output: output,
      // The prompt is written straight to stdout, past the sink --json
      // silences: asking would corrupt the document, and the consequences the
      // prompt exists to disclose would be suppressed while the question was
      // still asked. release already refuses when nobody can authorize.
      confirm: interactive ? promptOnTerminal : null,
      dryRun: dryRun,
    ).run(only: unit);
  } finally {
    registry.close();
  }
}

Future<int> _verify(Output output, String? unit, {String? at}) async {
  final prepared = _prepare(output);
  if (!prepared.isReady) return prepared.code!;
  final resolution = prepared.resolution!;
  final tree = prepared.tree!;
  final registry = prepared.registry!;
  try {
    return await VerifyCommand(
      resolution: resolution,
      registry: registry,
      comparator: Comparator(tools: const SystemTools()),
      treeAt: (ref) => GitTreeAtRef.at(tree.root, ref),
      output: output,
      at: at,
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
    output.problem(
      Diagnostic(
        code: 'RK-CLI-002',
        message: 'this is not a git repository',
        remedy: 'rk releases from a repository, and reads its tags and '
            'history to know what is already out.',
      ),
    );
    return _Prepared.stopped(ExitCodes.usage);
  }

  final tree = GitSourceTree(root);
  final String? source;
  try {
    source = tree.read('release.toml');
  } on SourceUnreadable catch (error) {
    output.repository(name: root.split('/').last);
    output.problem(
      Diagnostic(
        code: 'RK-CONF-034',
        message: 'release.toml is there and rk could not read it',
        source: SourceLocation('release.toml', 1),
        remedy: error.reason,
      ),
    );
    return _Prepared.stopped(ExitCodes.refused);
  }
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
    final git = GitState.read(tree.root);
    return await StatusCommand(
      resolution: resolution,
      tree: tree,
      git: git,
      registry: registry,
      inspector: Inspector(
        registry: registry,
        git: git,
        // Read-only, and only when there is a forge to ask about. Without
        // either, the forge reports as unread rather than as empty.
        tools: offline ? null : const SystemTools(),
        repository: offline ? null : git.originUrl,
      ),
      output: output,
      offline: offline,
    ).run(only: unit);
  } finally {
    registry.close();
  }
}
