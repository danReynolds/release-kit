/// rk's entry point, and its composition root.
///
/// The release command composition root: this file finds the
/// git root, reads and parses `release.toml`, resolves it against the
/// repository, and constructs the `Registry`, `SystemTools`, and `Output` the
/// operational verbs are handed. It also dispatches the repository-independent
/// target reference and, on a run that failed after acting, writes the
/// diagnosis.
///
/// Release commands read config through `_prepare`; installation commands
/// compose their working-tree view in `installations.dart`. Both hand resolved
/// models to the engine, keeping source discovery outside its policy layer.
library;

import 'dart:io';

import 'package:rk/src/builds/capability.dart';
import 'package:rk/src/commands/clean.dart';
import 'package:rk/src/commands/init.dart';
import 'package:rk/src/tui/init_picker.dart' deferred as init_ui;
import 'installations.dart' deferred as installations;
import 'package:rk/src/commands/plan.dart';
import 'package:rk/src/commands/release.dart';
import 'package:rk/src/commands/status.dart';
import 'package:rk/src/commands/target.dart';
import 'package:rk/src/targets/pub_dev/client.dart';
import 'package:rk/src/targets/pub_dev/endpoint.dart';
import 'package:rk/src/output/diagnosis.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/git.dart';
import 'package:rk/src/engine/inspect.dart';
import 'package:rk/src/output/output.dart';
import 'package:rk/src/engine/registry.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/release_stage.dart';
import 'package:rk/src/engine/release_source.dart';
import 'package:rk/src/engine/stage_store.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/targets/catalog.dart';
import 'package:rk/src/version.dart';
import 'package:rk/src/engine/timings.dart';

const _usage = '''
rk makes releasing code simple

Release this project
  rk init                         choose what to release; writes release.toml
  rk status [unit]                what is released, staged and left to do; bare rk too
  rk stage [unit]                 build and check what a release publishes; publishes nothing
  rk release [unit]               release what is not released yet, in dependency order
  rk plan [unit]                  the release graph: each unit's steps and what they wait on
  rk target [name]                the targets this rk supports, or one in detail
  rk clean                        remove this repository's staged release work
  rk help [command]               this, or one command's flags and examples

Run locally
  rk use [source] [-p project]        choose the source of your commands
  rk install [source] [-p project]    prepare an installation without switching
  rk uninstall [source] [-p project]  remove an inactive installation

Flags
  --json      the machine surface (doc/json.md)
  -y, --yes   release, clean or uninstall: confirm without an interactive prompt
  --timings   stage or release: how long each step took, after the run
              (and .rk/timings.json, a trace Perfetto opens)
  --write     init: write the default configuration without a prompt
  --latest    install: get the latest compatible version without changing source
  --version   print this binary's version and exit

Marks: ✓ done,  · already satisfied,  ✗ problem or conflict,  ! warning,
       → your next move,  unmarked pending
Exit:  0 successful report or completed command, 1 refused or failed,
       2 usage, 3 rk itself crashed — --json mirrors it in "exit"
''';

const _unitHelp = '''
A unit is named by [release.<unit>] in release.toml and groups packages
released together. Package names come from pubspec.yaml; rk use -p uses those.
''';

const _initUsage = '''
rk init [--write] [--json]

Discover Dart packages, choose release outputs, and review release.toml.
Creates the file after confirmation; existing configurations are left alone.
In a Git repository, also adds .rk/ to .gitignore. Nothing is published.

--write   write the default configuration without opening the selector
--json    show the default proposal as JSON; combine with --write to save it

Without a terminal, rk init shows the default proposal and writes nothing.
To choose different outputs, run rk init in a terminal.

Example: rk init
''';

const _statusUsage =
    '''
rk status [unit] [--json]

Check configured release destinations and local staged artifacts.
Reports what is released, what remains, and any issues that prevent release.
May read the network; does not build or publish. Bare rk also runs status.

$_unitHelp
Omit the unit to check every release unit.
--json    emit one structured report

Example: rk status tools
See rk plan tools for the configured steps without destination checks.
''';

const _planUsage =
    '''
rk plan [unit] [--json]

Show the configured release steps and their dependencies.
Reads source configuration only: no destination checks, builds, or changes.
Use rk status to check which steps are already complete.

$_unitHelp
Omit the unit to show every release unit.
--json    emit the complete graph as one structured report

Example: rk plan tools
''';

const _stageUsage =
    '''
rk stage [unit] [--timings] [--json]

Prepare and validate the exact artifacts for a release; publish nothing.
Runs configured builds, signing, notarization, and package checks.
May contact private services; does not ask for publication approval.

$_unitHelp
Omit the unit to prepare the whole repository; units build side by side.
A named unit takes a sibling not yet on pub.dev from the same commit.
Naming a unit never builds other units. No publication is performed.
--timings print how long each phase and step took, once the run ends,
          and write it to .rk/timings.json as a trace
--json    emit one structured report

Example: rk stage tools
Then:    rk release tools
Release reuses a valid stage and prepares one when needed.
''';

const _releaseUsage =
    '''
rk release [unit] [--yes] [--timings] [--json]

Prepare configured artifacts, then publish unfinished release targets.
Reuses a valid stage and prepares one when needed; rk stage is optional.
Existing releases are checked before work proceeds. Public changes require
confirmation in a terminal, or --yes when that confirmation is intentional.

$_unitHelp
Omit the unit to release every unfinished unit in dependency order.

-y, --yes answer yes to the publication prompt; checks still run
--timings print how long each phase and step took, once the run ends,
          and write it to .rk/timings.json as a trace
--json    emit one structured report; does not prompt

Example: rk release tools
To prepare without publishing: rk stage tools
Use rk plan tools to see the configured work before running it.
''';

const _verbs = {
  'status',
  'plan',
  'stage',
  'release',
  'init',
  'clean',
  'target',
};

/// The flags each verb takes. A flag that exists but does not apply to a
/// verb is refused the same way as one that does not exist: accepting
/// `rk status --yes` would imply that a read-only report needs
/// authorization.
const _perVerb = {
  'status': {'-h', '--help', '--json'},
  'plan': {'-h', '--help', '--json'},
  'stage': {'-h', '--help', '--json', '--timings'},
  'release': {'-h', '--help', '--json', '-y', '--yes', '--timings'},
  'init': {'-h', '--help', '--json', '--write'},
  'clean': {'-h', '--help', '--json', '-y', '--yes'},
  'target': {'-h', '--help', '--json'},
  'help': {'-h', '--help', '--json'},
};

/// What a misused verb takes instead, in one line: the usage itself is a
/// command away, rather than poured under the refusal.
String _takes(String command) {
  final flags = [
    for (final flag in _perVerb[command]!)
      if (flag == '--yes')
        '-y/--yes'
      else if (flag != '-h' && flag != '--help' && flag != '-y')
        flag,
  ];
  final series = flags.length <= 2
      ? flags.join(' and ')
      : '${flags.sublist(0, flags.length - 1).join(', ')} and ${flags.last}';
  return 'rk $command takes $series · rk help $command';
}

const _commands =
    'the commands are init, status, stage, release, plan, target, clean, '
    'use, install, uninstall and help; a unit follows one, as in '
    'rk status [unit]';

String _usageFor(String? command) => switch (command) {
  'init' => _initUsage,
  'status' => _statusUsage,
  'plan' => _planUsage,
  'stage' => _stageUsage,
  'release' => _releaseUsage,
  'target' => TargetCommand.usage,
  'clean' => CleanCommand.usage,
  _ => _usage,
};

Future<void> main(List<String> args) {
  // A reader that stops reading, as `rk --help | head -1` does, closes the
  // pipe under rk's later writes. Output nobody reads is not an error: rk
  // finishes what it was doing, writes nothing more, and exits as it would
  // have, rather than dying with a stack trace mid-run.
  stdout.done.catchError((_) {}, test: _closedPipe);
  return runRk(args);
}

/// EPIPE: the reading end of stdout is gone.
bool _closedPipe(Object error) => switch (error) {
  FileSystemException(:final osError?) => osError.errorCode == 32,
  SocketException(:final osError?) => osError.errorCode == 32,
  _ => false,
};

/// Shared command composition. The shipped entry point always uses pub.dev;
/// native publication qualification supplies an explicit loopback endpoint.
Future<void> runRk(
  List<String> args, {
  PubEndpoint pubEndpoint = const PubEndpoint.pubDev(),
}) async {
  // This is deliberately self-contained: smoke tests, Homebrew, and a user
  // holding only the compiled artifact must be able to identify its bytes
  // without a repository, release.toml, network, or credential access.
  if (args.length == 1 && args.single == '--version') {
    stdout.writeln('rk $rkVersion');
    return;
  }

  const known = {
    '-h',
    '--help',
    '--json',
    '-y',
    '--yes',
    '--write',
    '--timings',
  };
  final flags = args.where((argument) => argument.startsWith('-')).toSet();
  final positional = args.where((a) => !a.startsWith('-')).toList();
  final json = flags.contains('--json');

  final first = positional.isEmpty ? null : positional.first;
  if (first == 'help') {
    await _help(positional.skip(1).toList(), flags, json: json);
    return;
  }
  if (const {'use', 'install', 'uninstall'}.contains(first)) {
    await installations.loadLibrary();
    await installations.installationMain(args, first!);
    return;
  }
  final command = first ?? 'status';
  final target = positional.length > 1 ? positional[1] : null;

  final output = Output.stdio(json: json, command: command);

  if (!_verbs.contains(command)) {
    output.problem(
      Diagnostic(
        code: 'RK-CLI-008',
        message: 'rk has no command named "$command"',
        remedy: _commands,
      ),
    );
    exitCode = ExitCodes.usage;
    if (json) stdout.write(output.report.encode(exit: ExitCodes.usage));
    return;
  }

  final inapplicable = flags.difference(_perVerb[command] ?? known);
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
        remedy: _takes(command),
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
        remedy: _takes(command),
      ),
    );
    exitCode = ExitCodes.usage;
    if (json) stdout.write(output.report.encode(exit: ExitCodes.usage));
    return;
  }

  // Misuse is refused, not repaired: a third word would be dropped as if it
  // had not been said, and `rk init somepkg` would configure the whole
  // repository while reading as if it had scoped itself to one unit.
  if (positional.length > 2 ||
      ((command == 'init' || command == 'clean') && target != null)) {
    output.problem(
      Diagnostic(
        code: 'RK-CLI-007',
        message:
            (command == 'init' || command == 'clean') && positional.length <= 2
            ? 'rk $command takes no unit — it applies to the whole '
                  'repository, and got "$target"'
            : command == 'target'
            ? 'rk target takes "list" or one release choice name, and '
                  'got "${positional.skip(1).join(' ')}"'
            : 'rk takes a verb and a unit, and got '
                  '"${positional.join(' ')}"',
        remedy: 'rk help $command',
      ),
    );
    exitCode = ExitCodes.usage;
    if (json) stdout.write(output.report.encode(exit: ExitCodes.usage));
    return;
  }

  if (flags.contains('-h') || flags.contains('--help')) {
    final usage = _usageFor(first);
    // Under --json stdout carries the document and nothing else, so the usage
    // travels inside it rather than beside it.
    if (json) {
      output.report.next(usage.trim());
      stdout.write(output.report.encode(exit: ExitCodes.ok));
    } else {
      output.help(usage);
    }
    return;
  }

  int code;
  String? crash;
  try {
    code = switch (command) {
      'stage' || 'release' => await _release(
        output,
        target,
        pubEndpoint: pubEndpoint,
        stageOnly: command == 'stage',
        interactive: !json,
        yes: flags.contains('--yes') || flags.contains('-y'),
      ),
      'init' => await _init(
        output,
        interactive: !json,
        write: flags.contains('--write'),
      ),
      'clean' => await _clean(
        output,
        yes: flags.contains('--yes') || flags.contains('-y'),
        interactive: !json,
      ),
      'target' => TargetCommand(output: output).run(target),
      'plan' => await _plan(output, target),
      _ => await _status(output, target, pubEndpoint: pubEndpoint),
    };
  } on Object catch (error, stack) {
    // Its own exit class: an agent must tell "refused — remedy, then retry"
    // from "rk broke — a diagnosis was written and a human should hear".
    code = ExitCodes.crashed;
    crash = '$error\n$stack';
    // The report's own acted flag decides the sentence, not the verb: a
    // release that crashed while still reading has not touched anything, and
    // an init that crashed after writing has. Keying on the verb made every
    // init crash claim "an effect may exist" — including the ones that never
    // reached the write — which teaches a reader to discount the sentence
    // everywhere it is true.
    output.halt(
      output.report.acted ? HaltKind.lostTrack : HaltKind.beforeActing,
    );
    final recordsDiagnosis = Diagnosis.shouldWrite(
      command: command,
      acted: output.report.acted,
      crashed: true,
    );
    output.problem(
      Diagnostic(
        code: 'RK-INT-001',
        message: 'rk failed in a way it does not have a message for: $error',
        remedy: recordsDiagnosis
            ? 'this is a bug in rk. The run\'s evidence is written beside '
                  'this message, and re-running will inspect what is really '
                  'there.'
            : 'this is a bug in rk. rk plan is read-only, so it did not '
                  'write a diagnosis. Re-run with --json and report the error.',
      ),
    );
  } finally {
    // Rendering owns a repeating timer while a step is running, and a timer
    // keeps the isolate alive. Without this, a thrown exception turns a crash
    // into a hang.
    output.close();
  }

  _recordDiagnosis(output, code, crash: crash);
  _reportTimings(
    output,
    command: command,
    code: code,
    requested: flags.contains('--timings'),
  );

  Timings.report(stderr);
  exitCode = code;

  // The machine surface survives a non-zero exit — including a crash — because
  // it is written here, after the code is known, rather than by whichever path
  // decided to stop.
  if (json) stdout.write(output.report.encode(exit: code));
}

/// `rk help [command]`: what `rk [command] --help` prints.
Future<void> _help(
  List<String> words,
  Set<String> flags, {
  required bool json,
}) async {
  final output = Output.stdio(json: json, command: 'help');
  void refuse(Diagnostic problem) {
    output.problem(problem);
    exitCode = ExitCodes.usage;
    if (json) stdout.write(output.report.encode(exit: ExitCodes.usage));
  }

  final inapplicable = flags.difference(_perVerb['help']!);
  if (inapplicable.isNotEmpty) {
    return refuse(
      Diagnostic(
        code: 'RK-CLI-005',
        message: 'rk help does not have ${inapplicable.join(', ')}',
        remedy: _takes('help'),
      ),
    );
  }
  if (words.length > 1) {
    return refuse(
      Diagnostic(
        code: 'RK-CLI-007',
        message: 'rk help takes one command, and got "${words.join(' ')}"',
        remedy: _commands,
      ),
    );
  }
  final named = words.firstOrNull;
  String? usage;
  if (named == null || named == 'help') {
    usage = _usage;
  } else if (_verbs.contains(named)) {
    usage = _usageFor(named);
  } else if (const {'use', 'install', 'uninstall'}.contains(named)) {
    await installations.loadLibrary();
    usage = installations.installationUsage;
  }
  if (usage == null) {
    return refuse(
      Diagnostic(
        code: 'RK-CLI-008',
        message: 'rk has no command named "$named"',
        remedy: _commands,
      ),
    );
  }
  // Under --json stdout carries the document and nothing else, so the usage
  // travels inside it rather than beside it.
  if (json) {
    output.report.next(usage.trim());
    stdout.write(output.report.encode(exit: ExitCodes.ok));
  } else {
    output.help(usage);
  }
}

/// Says where a staging or release run's time went.
///
/// On a terminal, a successful run long enough to wonder about ends with one
/// line of phases. `--timings` prints the full breakdown to stderr and writes
/// the run as a trace to `.rk/timings.json`, which is rk's own, so the next
/// release does not find it uncommitted. Pipes and `--json` are unchanged.
void _reportTimings(
  Output output, {
  required String command,
  required int code,
  required bool requested,
}) {
  if (command != 'stage' && command != 'release') return;
  if (code == ExitCodes.ok && output.isTerminal) {
    final summary = output.timeline.summaryLine();
    if (summary != null) {
      output.blank();
      output.say(summary, role: VisualRole.secondary);
    }
  }
  if (!requested) return;
  stderr.write('\n${output.timeline.breakdown()}');
  final root =
      GitSourceTree.findRoot(Directory.current.path) ??
      Directory.current.absolute.path;
  if (!File('$root/release.toml').existsSync()) return;
  final directory = '$root/.rk';
  final trace = '$directory/timings.json';
  // As the stage store does, rk writes only into a .rk that is a real
  // directory, and never through a link: either could point outside the
  // repository.
  final unsafe = switch ((
    FileSystemEntity.typeSync(directory, followLinks: false),
    FileSystemEntity.typeSync(trace, followLinks: false),
  )) {
    (FileSystemEntityType.notFound, _) => null,
    (FileSystemEntityType.directory, FileSystemEntityType.notFound) => null,
    (FileSystemEntityType.directory, FileSystemEntityType.file) => null,
    (FileSystemEntityType.directory, _) => trace,
    _ => directory,
  };
  if (unsafe != null) {
    stderr.writeln('rk: did not write timings: $unsafe is not rk\'s own');
    return;
  }
  try {
    // An earlier run's trace never answers for this one: it goes first, so
    // a write that fails leaves no trace rather than a stale one.
    final file = File(trace);
    if (file.existsSync()) file.deleteSync();
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(output.timeline.traceJson());
    stderr.writeln('rk: wrote timings to $trace');
  } on FileSystemException catch (error) {
    stderr.writeln('rk: could not write timings to $trace: ${error.message}');
  }
}

/// Writes the evidence for a run that began changing things and then failed.
///
/// Only then: a refusal that never acted — an unreadable release.toml — has
/// already said everything it knows on stdout, and copying that into a
/// directory would fill `.rk/diagnosis` with typos while teaching an operator
/// to ignore it. Operational crashes retain their stack; `rk plan` remains
/// strictly read-only even when rk itself fails.
void _recordDiagnosis(Output output, int code, {String? crash}) {
  if (code == ExitCodes.ok || code == ExitCodes.usage) return;
  if (!Diagnosis.shouldWrite(
    command: output.report.command,
    acted: output.report.acted,
    crashed: crash != null,
  )) {
    return;
  }
  final root =
      GitSourceTree.findRoot(Directory.current.path) ??
      Directory.current.absolute.path;
  if (!File('$root/release.toml').existsSync()) return;

  final at = Diagnosis.write(
    root,
    stamp: DateTime.now().toIso8601String().replaceAll(':', '-'),
    report: output.report,
    exit: code,
    attachments: {
      ...output.report.attachments,
      if (crash != null) 'crash.txt': crash,
    },
  );
  output.report.diagnosis = at;
  output.say('what this run saw: $at');
}

Future<int> _init(
  Output output, {
  required bool interactive,
  required bool write,
}) async {
  final gitRoot = GitSourceTree.findRoot(Directory.current.path);
  final root = gitRoot ?? Directory.current.absolute.path;
  final tree = gitRoot == null
      ? FileSystemSourceTree(root)
      : GitSourceTree(gitRoot) as SourceTree;
  final git = gitRoot == null ? null : await GitState.read(root);
  final selectorEnabled = interactive && !write && _usableInitTerminal();

  if (selectorEnabled) await init_ui.loadLibrary();
  final interaction = selectorEnabled ? init_ui.InitInteraction() : null;
  final transcript = StringBuffer();
  // Print command diagnostics and the result after clearing the inline region.
  final commandOutput = interaction == null
      ? output
      : Output(
          sink: transcript.write,
          isTerminal: output.isTerminal,
          useColor: output.useColor,
          terminalWidth: output.terminalWidth,
          report: output.report,
        );
  late final int code;
  try {
    code = await InitCommand(
      tree: tree,
      output: commandOutput,
      capabilities: HostCapabilities.inspect(),
      origin: git?.originUrl,
      gitBound: git != null,
      hasRemote: git?.hasRemote ?? false,
      ambientPubHostedUrl: Platform.environment['PUB_HOSTED_URL'],
      select: interaction?.select,
      review: interaction?.review,
      updateGitignore: git != null ? () => _ensureRkIgnored(root) : null,
      write: (path, contents) {
        if (path == 'release.toml') {
          final file = File('$root/$path')..createSync(exclusive: true);
          file.writeAsStringSync(contents, flush: true);
        } else {
          File('$root/$path').writeAsStringSync(contents);
        }
      },
      // A prompt would be written straight to stdout, past the sink that --json
      // silences, so asking is not an option when a caller is parsing the
      // answer. init already refuses when nobody can confirm. The answer is
      // parsed by InitCommand.consented, where EOF is a decline — hasTerminal
      // alone does not guard that, because macOS reports a terminal for
      // `rk init < /dev/null`.
      // --write is the typed yes, carried as a flag: the door for scripts and
      // agents, named in the refusal a terminal-less run prints.
      confirm: write ? (_) async => true : null,
    ).run();
  } finally {
    try {
      await interaction?.close();
    } finally {
      if (interaction != null) {
        commandOutput.close();
        if (interaction.signalExitCode == null) {
          output.sink(transcript.toString());
        }
      }
    }
  }
  return interaction?.signalExitCode ?? code;
}

Future<int> _clean(
  Output output, {
  required bool yes,
  required bool interactive,
}) {
  final root =
      GitSourceTree.findRoot(Directory.current.path) ??
      Directory.current.absolute.path;
  return CleanCommand(
    store: StageStore(root),
    output: output,
    yes: yes,
    confirm: interactive && stdin.hasTerminal && stdout.hasTerminal
        ? (prompt) => _promptOnTerminal(output, prompt)
        : null,
  ).run();
}

void _ensureRkIgnored(String root) {
  final file = File('$root/.gitignore');
  final handle = file.openSync(mode: FileMode.append);
  try {
    handle.lockSync(FileLock.exclusive);
    final current = file.readAsStringSync();
    if (current.split('\n').any((line) => line.trim() == '.rk/')) return;
    handle.writeStringSync(
      '${current.isEmpty || current.endsWith('\n') ? '' : '\n'}'
      '.rk/\n',
    );
    handle.flushSync();
  } finally {
    try {
      handle.unlockSync();
    } on Object {
      // Closing releases the lock too; do not hide the actual init outcome.
    }
    handle.closeSync();
  }
}

bool _usableInitTerminal() {
  if (!stdin.hasTerminal || !stdout.hasTerminal) return false;
  if ((Platform.environment['TERM'] ?? '').toLowerCase() == 'dumb') {
    return false;
  }
  try {
    return stdout.terminalColumns >= 32;
  } on Object {
    return false;
  }
}

Future<int> _release(
  Output output,
  String? unit, {
  required PubEndpoint pubEndpoint,
  required bool stageOnly,
  required bool interactive,
  required bool yes,
}) async {
  final prepared = await _prepare(output);
  if (!prepared.isReady) return prepared.code!;
  final source = prepared.source!;
  // Outside Git there is nothing to stage, and nothing of rk's — not even
  // the stage lock — belongs in this directory.
  if (!source.inRepository) {
    _showRepository(output, source);
    output.problem(source.git.stagingProblem()!);
    output.halt(HaltKind.beforeActing);
    return ExitCodes.refused;
  }
  final resolution = prepared.resolution!;
  final registry = Registry(
    host: pubEndpoint.uri.authority,
    secure: pubEndpoint.uri.scheme == 'https',
  );
  // A container runtime is asked for only when a smoke test needs one.
  final capabilities = HostCapabilities.detect();
  StageStoreLock? stageLock;
  try {
    try {
      stageLock = StageStore(source.root).acquireForMutation();
    } on StageStoreBusy catch (error) {
      output.problem(_stageStoreProblem(error));
      return ExitCodes.refused;
    } on StageStoreUnsafe catch (error) {
      output.problem(_stageStoreProblem(error));
      return ExitCodes.refused;
    }
    final tree = source.tree;
    final git = source.git;
    final targets = TargetCatalog.builtIn(pubEndpoint: pubEndpoint);
    final stages = ReleaseStages(
      source: tree,
      git: git,
      stageContracts: targets.stageContractResolver(resolution),
    );
    const targetTools = SystemTools(timeout: Duration(minutes: 2));
    return await ReleaseCommand(
      resolution: resolution,
      tree: tree,
      git: git,
      inspector: Inspector(
        registry: registry,
        pubDev: PubDevTarget(registry: registry),
        git: git,
        tools: targetTools,
        repository: git.originUrl,
        stageFor: stages.call,
        targets: targets,
      ),
      tools: const SystemTools(),
      capabilities: capabilities,
      output: output,
      // The prompt is written straight to stdout, past the sink --json
      // silences: asking would corrupt the document, and the consequences the
      // prompt exists to disclose would be suppressed while the question was
      // still asked. release already refuses when nobody can authorize.
      // --yes answers only the ordinary authorization question. It skips no
      // inspection, plan rendering, endpoint check, or read-back.
      confirm: yes
          ? (_) async => 'yes'
          : interactive && stdin.hasTerminal && stdout.hasTerminal
          ? (prompt) => _promptOnTerminal(output, prompt)
          : null,
      allowInteractiveTools:
          interactive && stdin.hasTerminal && stdout.hasTerminal,
      stageOnly: stageOnly,
      stageFor: stages.call,
    ).run(only: unit);
  } finally {
    stageLock?.close();
    registry.close();
  }
}

/// Asks at the terminal, or answers null when there is none.
///
/// Lives at the entry point rather than in a command file: reading a line
/// from a person is this program's edge, and a verb that could reach for
/// stdin is a verb that could ask a question no caller can answer.
Future<String?> _promptOnTerminal(Output output, String prompt) async {
  if (!stdin.hasTerminal) return null;
  // The one place rk waits on a person, so the only wait it leaves out of a
  // run's times: --yes and --json never come here.
  return output.timeline.waitingOnPerson(() async {
    output.prompt(prompt);
    return stdin.readLineSync();
  });
}

/// What reading the repository produced: either everything a command needs,
/// or the exit code that reading it decided.
///
/// Not-onboarded is exit 0, since a repository without a release.toml is a
/// correct answer rather than a failure — an agent sweeping a fleet must not
/// see a fault for every repository that simply does not use rk.
class _Prepared {
  _Prepared.ready(this.source, this.resolution) : code = null;
  _Prepared.stopped(this.code) : source = null, resolution = null;

  final ReleaseSource? source;
  final Resolution? resolution;
  final int? code;

  bool get isReady => code == null;
}

/// Reads the release configuration once — at HEAD for a clean repository,
/// from the working tree otherwise — for status, plan, stage and release.
Future<_Prepared> _prepare(Output output) async {
  final source = await ReleaseSource.open(Directory.current.absolute.path);
  switch (source.readConfig()) {
    case ConfigMissing():
      output.repository(name: source.root.split('/').last);
      output.blank();
      output.line('no release.toml', mark: Mark.none);
      output.next('rk init');
      return _Prepared.stopped(ExitCodes.ok);
    case ConfigProblems(:final problems):
      _showRepository(output, source);
      output.blank();
      output.problems(problems);
      return _Prepared.stopped(ExitCodes.refused);
    case ConfigResolved(:final resolution):
      return _Prepared.ready(source, resolution);
  }
}

/// The repository line a refusal before any command starts is shown under.
void _showRepository(Output output, ReleaseSource source) {
  final git = source.git;
  output.repository(
    name: source.root.split('/').last,
    branch: git.branch,
    commit: git.hasCommit ? git.shortHead : null,
    uncommitted: source.inRepository && git.worktreeStatusError == null
        ? git.uncommitted.length
        : null,
    head: git.hasCommit ? git.head : null,
    remote: git.originUrl,
  );
}

Future<int> _plan(Output output, String? unit) async {
  final prepared = await _prepare(output);
  if (!prepared.isReady) return prepared.code!;
  return PlanCommand(
    resolution: prepared.resolution!,
    git: prepared.source!.git,
    output: output,
    targets: TargetCatalog.builtIn(),
  ).run(only: unit);
}

Future<int> _status(
  Output output,
  String? unit, {
  required PubEndpoint pubEndpoint,
}) async {
  final prepared = await _prepare(output);
  if (!prepared.isReady) return prepared.code!;
  final source = prepared.source!;
  final registry = Registry(
    host: pubEndpoint.uri.authority,
    secure: pubEndpoint.uri.scheme == 'https',
  );
  final cancellation = ToolCancellation();
  final resolution = prepared.resolution!;
  final tree = source.tree;
  final git = source.git;
  try {
    final targets = TargetCatalog.builtIn(pubEndpoint: pubEndpoint);
    final stages = ReleaseStages(
      source: tree,
      git: git,
      stageContracts: targets.stageContractResolver(resolution),
    );
    final targetTools = SystemTools(
      timeout: const Duration(minutes: 2),
      cancellation: cancellation,
    );
    final command = StatusCommand(
      resolution: resolution,
      tree: tree,
      git: git,
      inspector: Inspector(
        registry: registry,
        pubDev: PubDevTarget(registry: registry),
        git: git,
        tools: targetTools,
        repository: git.originUrl,
        stageFor: stages.call,
        targets: targets,
      ),
      output: output,
    );
    return await command.run(only: unit);
  } finally {
    cancellation.cancel();
    registry.close();
  }
}

Diagnostic _stageStoreProblem(Object error) => Diagnostic(
  code: 'RK-STAGE-006',
  message: error is StageStoreBusy
      ? 'another rk command is using staged work'
      : 'the local stage path is not safe to use',
  remedy: error is StageStoreBusy
      ? 'let that command finish, then run rk again'
      : '$error\nRK did not follow or change the unexpected path.',
);
