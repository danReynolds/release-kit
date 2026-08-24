/// rk's entry point, and its composition root.
///
/// Everything a run needs is built here and nowhere else: this file finds the
/// git root, reads and parses `release.toml`, resolves it against the
/// repository, and constructs the `Registry`, `SystemTools`, and `Output` the
/// operational verbs are handed. It also dispatches the repository-independent
/// target reference and, on a run that failed after acting, writes the
/// diagnosis.
///
/// So the answer to "where does rk read release.toml?" is `_prepare` below,
/// not a file under `lib/`. Reading files and deciding exit codes is
/// composition-root work; pushing it down would put `dart:io` in the layer
/// `engine/source_tree.dart` exists to keep testable.
library;

import 'dart:io';

import 'package:rk/src/builds/capability.dart';
import 'package:rk/src/commands/clean.dart';
import 'package:rk/src/commands/init.dart';
import 'package:rk/src/commands/init_selector.dart';
import 'package:rk/src/commands/plan.dart';
import 'package:rk/src/commands/release.dart';
import 'package:rk/src/commands/status.dart';
import 'package:rk/src/commands/target.dart';
import 'package:rk/src/targets/pub_dev/client.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/output/diagnosis.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/git.dart';
import 'package:rk/src/engine/inspect.dart';
import 'package:rk/src/engine/init_plan.dart';
import 'package:rk/src/engine/dart_workspace.dart';
import 'package:rk/src/engine/publish_target.dart';
import 'package:rk/src/output/output.dart';
import 'package:rk/src/engine/registry.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/release_stage.dart';
import 'package:rk/src/engine/release_source.dart';
import 'package:rk/src/engine/stage_store.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/source_context.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/targets/catalog.dart';
import 'package:rk/src/version.dart';

const _usage = '''
rk — an austere release tool

Usage
  rk                              status all units
  rk --version                    print this binary's version
  rk status [unit]                status all units or one
  rk plan [unit]                  show the configured release graph; read-only
  rk init                         propose release.toml; write only on a yes
  rk clean                        remove this repository's staged release work
  rk target list                  list every release choice this rk supports
  rk target <name>                explain one choice and its configuration
  rk release [unit]               release all unfinished units, or one named unit
  rk release [unit] --stage       prepare one exact stage; name it if ambiguous

Flags
  --version   print this binary's version and exit
  --json      the machine surface (doc/json.md)
  --stage     release: build, sign, and notarize exact artifacts; publish nothing
  -y, --yes   release or clean: answer yes without an interactive prompt
  --write     init: accept the proposal without a prompt

Marks: ✓ done,  · already satisfied,  ✗ problem or conflict,  ! warning,
       → your next move,  unmarked pending
Exit:  0 successful report or completed command, 1 refused or failed,
       2 usage, 3 rk itself crashed — --json mirrors it in "exit"
''';

Future<void> main(List<String> args) async {
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
    '--stage',
    '--json',
    '-y',
    '--yes',
    '--write',
  };
  final flags = args.where((argument) => argument.startsWith('-')).toSet();
  final positional = args.where((a) => !a.startsWith('-')).toList();
  final json = flags.contains('--json');

  const verbs = {'status', 'plan', 'release', 'init', 'clean', 'target'};
  final first = positional.isEmpty ? null : positional.first;
  final command = first ?? 'status';
  final target = positional.length > 1 ? positional[1] : null;

  final output = Output.stdio(json: json, command: command);
  // The document says how it was asked to operate — only where the answer
  // varies. status and init have no modes, so their documents carry none.
  if (command == 'release') {
    output.report.mode.addAll({'stage': flags.contains('--stage')});
  }

  if (!verbs.contains(command)) {
    output.problem(
      Diagnostic(
        code: 'RK-CLI-008',
        message: 'rk has no command named "$command"',
        remedy: _usage.trim(),
      ),
    );
    exitCode = ExitCodes.usage;
    if (json) stdout.write(output.report.encode(exit: ExitCodes.usage));
    return;
  }

  // A flag that exists but does not apply to this verb is refused the same
  // way as one that does not exist: `rk status --stage` staging under a verb
  // that promises to be read-only is worse than an error.
  const perVerb = {
    'status': {'-h', '--help', '--json'},
    'plan': {'-h', '--help', '--json'},
    'release': {'-h', '--help', '--json', '--stage', '-y', '--yes'},
    'init': {'-h', '--help', '--json', '--write'},
    'clean': {'-h', '--help', '--json', '-y', '--yes'},
    'target': {'-h', '--help', '--json'},
  };
  final inapplicable = flags.difference(perVerb[command] ?? known);
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

  if ((flags.contains('--yes') || flags.contains('-y')) &&
      flags.contains('--stage') &&
      !flags.contains('-h') &&
      !flags.contains('--help')) {
    // Staging publishes nothing, so there is nothing the yes could apply
    // to; accepting and discarding an authorization teaches callers that
    // consent is decorative.
    output.problem(
      Diagnostic(
        code: 'RK-CLI-005',
        message: 'rk release --stage does not have --yes',
        remedy: 'staging publishes nothing, so it takes no authorization. '
            'Stage first, then rk release <unit> --yes',
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
        remedy: _usage.trim(),
      ),
    );
    exitCode = ExitCodes.usage;
    if (json) stdout.write(output.report.encode(exit: ExitCodes.usage));
    return;
  }

  if (flags.contains('-h') || flags.contains('--help')) {
    final usage = switch (command) {
      'target' => TargetCommand.usage,
      'clean' => CleanCommand.usage,
      _ => _usage,
    };
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
      'release' => await _release(
          output,
          target,
          stageOnly: flags.contains('--stage'),
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
      _ => await _status(output, target),
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
  final root = GitSourceTree.findRoot(Directory.current.path) ??
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
  final git =
      gitRoot == null ? GitState.unbound(root) : await GitState.read(root);
  final selectorEnabled = interactive && !write && _usableInitTerminal();

  return InitCommand(
    tree: tree,
    output: output,
    capabilities: HostCapabilities.inspect(),
    origin: git.originUrl,
    gitBound: git.isBound,
    hasRemote: git.hasRemote,
    ambientPubHostedUrl: Platform.environment['PUB_HOSTED_URL'],
    select: selectorEnabled ? _selectInitPlan : null,
    review: selectorEnabled
        ? (prompt) async {
            output.prompt(prompt);
            return InitCommand.reviewed(stdin.readLineSync());
          }
        : null,
    updateGitignore: git.isBound ? () => _ensureRkIgnored(root) : null,
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
}

Future<int> _clean(
  Output output, {
  required bool yes,
  required bool interactive,
}) {
  final root = GitSourceTree.findRoot(Directory.current.path) ??
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
        '.rk/\n');
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

Future<InitPlan?> _selectInitPlan(InitPlan plan) async {
  var interrupted = false;
  final signals = ProcessSignal.sigint.watch().listen((_) {
    interrupted = true;
  });
  try {
    return await runInitSelector(
      plan,
      const _StdioInitTerminal(),
      interrupted: () => interrupted,
    );
  } finally {
    await signals.cancel();
  }
}

final class _StdioInitTerminal implements InitTerminal {
  const _StdioInitTerminal();

  @override
  bool get lineMode => stdin.lineMode;
  @override
  set lineMode(bool value) => stdin.lineMode = value;

  @override
  bool get echoMode => stdin.echoMode;
  @override
  set echoMode(bool value) => stdin.echoMode = value;

  @override
  bool get echoNewlineMode => stdin.echoNewlineMode;
  @override
  set echoNewlineMode(bool value) => stdin.echoNewlineMode = value;

  @override
  int get width => stdout.terminalColumns;

  @override
  int get height => stdout.terminalLines;

  @override
  bool get useColor =>
      !Platform.environment.containsKey('NO_COLOR') &&
      (Platform.environment['TERM'] ?? '').toLowerCase() != 'dumb';

  @override
  int readByte() => stdin.readByteSync();

  @override
  void write(String value) => stdout.write(value);

  @override
  Future<void> flush() => stdout.flush();
}

Future<int> _release(
  Output output,
  String? unit, {
  required bool stageOnly,
  required bool interactive,
  required bool yes,
}) async {
  final prepared = await _prepare(output);
  if (!prepared.isReady) return prepared.code!;
  final context = prepared.context!;
  final source = _selectReleaseSource(prepared, unit, output);
  if (source == null) return ExitCodes.refused;
  final registry = Registry();
  final capabilities = source.resolution.units.any((unit) => unit.shipsBinaries)
      ? await HostCapabilities.detect()
      : HostCapabilities.inspect();
  StageStoreLock? stageLock;
  try {
    try {
      stageLock = StageStore(context.root).acquireForMutation();
    } on StageStoreBusy catch (error) {
      output.problem(_stageStoreProblem(error));
      return ExitCodes.refused;
    } on StageStoreUnsafe catch (error) {
      output.problem(_stageStoreProblem(error));
      return ExitCodes.refused;
    }
    final resolution = source.resolution;
    final tree = source.tree;
    final git = source.binding;
    final targets = TargetCatalog.builtIn();
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
      repositoryGit: source.repository,
      sourceWarning: source.warning,
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
      refreshStage: stages.refresh,
      refreshGit: () async => git.isBound
          ? await GitState.read(context.root)
          : GitState.unbound(context.root),
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
  output.prompt(prompt);
  return stdin.readLineSync();
}

/// What reading the repository produced: either everything a command needs,
/// or the exit code that reading it decided.
///
/// Not-onboarded is exit 0, since a repository without a release.toml is a
/// correct answer rather than a failure — an agent sweeping a fleet must not
/// see a fault for every repository that simply does not use rk.
class _Prepared {
  _Prepared.ready(this.resolution, this.context) : code = null;
  _Prepared.stopped(this.code)
      : resolution = null,
        context = null;

  final Resolution? resolution;
  final SourceContext? context;
  final int? code;

  bool get isReady => code == null;
}

Future<_Prepared> _prepare(Output output) async {
  final gitRoot = GitSourceTree.findRoot(Directory.current.path);
  final root = gitRoot ?? Directory.current.absolute.path;
  SourceTree tree =
      gitRoot == null ? FileSystemSourceTree(root) : GitSourceTree(gitRoot);
  final git =
      gitRoot == null ? GitState.unbound(root) : await GitState.read(root);
  if (git.isClean && git.hasCommit) {
    tree = GitCommitSourceTree(root, git.head);
  }
  final String? source;
  try {
    source = tree.read('release.toml');
  } on SourceUnreadable catch (error) {
    output.repository(name: root.split('/').last);
    output.problem(
      error.path == 'release.toml'
          ? _wrongReleaseConfigProblem(error.reason)
          : Diagnostic(
              code: 'RK-SRC-003',
              message: 'the selected source could not be read',
              remedy: '${error.path}: ${error.reason}\n'
                  'Repair the repository source, then run rk again.',
            ),
    );
    return _Prepared.stopped(ExitCodes.refused);
  }
  if (source == null) {
    if (tree.exists('release.toml')) {
      output.repository(name: root.split('/').last);
      output.problem(
        _wrongReleaseConfigProblem('release.toml must be a regular file'),
      );
      return _Prepared.stopped(ExitCodes.refused);
    }
    _showNoReleaseConfig(output, root);
    return _Prepared.stopped(ExitCodes.ok);
  }

  final diagnostics = Diagnostics();
  ReleaseConfig? config;
  Resolution? resolution;
  try {
    config = ReleaseConfig.parse(source, 'release.toml', diagnostics);
    resolution =
        config == null ? null : Resolution.resolve(config, tree, diagnostics);

    if (resolution != null && !git.isBound) {
      tree = FileSystemSourceTree(
        root,
        roots: _filesystemSourceRoots(tree, resolution),
      );
      final narrowedDiagnostics = Diagnostics();
      resolution = Resolution.resolve(config!, tree, narrowedDiagnostics);
      for (final diagnostic in narrowedDiagnostics.found) {
        diagnostics.report(diagnostic);
      }
    }
  } on SourceUnreadable catch (error) {
    diagnostics.add(
      'RK-SRC-003',
      'the source snapshot could not be read',
      remedy: '${error.path}: ${error.reason}\n'
          'Make that path a readable repository-local regular file or '
          'directory, then run rk again.',
    );
    resolution = null;
  }

  if (resolution != null && !git.isBound) {
    for (final unit in resolution.units) {
      final requiringGit = <PublishTarget>{
        ...unit.publish.where((target) => target.requiresGit),
        for (final project in unit.projects)
          ...project.publish.where((target) => target.requiresGit),
      };
      if (requiringGit.isEmpty) continue;
      final names = requiringGit.map((target) => target.configName).toList()
        ..sort();
      diagnostics.add(
        'RK-SRC-001',
        '${unit.name} selects targets that require Git',
        remedy: 'initialize a Git repository, or remove '
            '${names.join(', ')} from this unit',
      );
    }
  }

  if (resolution == null || diagnostics.isNotEmpty) {
    output.repository(name: root.split('/').last);
    output.blank();
    output.problems(diagnostics.found);
    return _Prepared.stopped(ExitCodes.refused);
  }

  return _Prepared.ready(
    resolution,
    SourceContext(tree: tree, git: git),
  );
}

Set<String> _filesystemSourceRoots(
  SourceTree tree,
  Resolution resolution,
) {
  final roots = <String>{
    'release.toml',
    ...DartWorkspaceDiscovery(tree).sourceRoots,
    for (final unit in resolution.units)
      for (final project in unit.projects) project.pubspec.directory,
  };
  return roots;
}

ReleaseSource? _selectReleaseSource(
  _Prepared prepared,
  String? unit,
  Output output,
) {
  final context = prepared.context!;
  final diagnostics = Diagnostics();
  final source = ReleaseSource.select(
    tree: context.tree,
    git: context.git,
    repository: context.git,
    resolution: prepared.resolution!,
    only: unit,
    diagnostics: diagnostics,
  );
  if (source != null) return source;

  final git = context.git;
  output.repository(
    name: context.root.split('/').last,
    branch: git.branch,
    commit: git.hasCommit ? git.shortHead : null,
    uncommitted: git.uncommitted.length,
    head: git.hasCommit ? git.head : null,
    remote: git.originUrl,
  );
  output.blank();
  output.problems(diagnostics.found);
  return null;
}

Future<int> _plan(
  Output output,
  String? unit,
) async {
  final gitRoot = GitSourceTree.findRoot(Directory.current.path);
  final root = gitRoot ?? Directory.current.absolute.path;
  final initial = SourceContext(
    tree: gitRoot == null ? FileSystemSourceTree(root) : GitSourceTree(gitRoot),
    git: gitRoot == null ? GitState.unbound(root) : await GitState.read(root),
  );
  final prepared = await _selectPlanSource(initial, output);
  if (!prepared.isReady) return prepared.code!;
  return PlanCommand(
    resolution: prepared.resolution!,
    git: prepared.context!.git,
    output: output,
    targets: TargetCatalog.builtIn(),
  ).run(only: unit);
}

/// Captures one immutable current-source view for `rk plan`.
///
/// This intentionally does less than [ReleaseSource.select]: a configured Git
/// target is valid topology even when this directory has no Git identity.
/// Readiness belongs to status and release. Like release, a clean repository
/// with a commit resolves from immutable HEAD while a dirty, unborn, or
/// unbound repository gets one double-read byte snapshot. Bound Git identity
/// is re-read before returning so topology and its displayed branch/commit
/// cannot come from two moments.
Future<_Prepared> _selectPlanSource(
  SourceContext context,
  Output output,
) async {
  final initialGit = context.git;
  if (initialGit.worktreeStatusError != null) {
    _showPlanSourceProblem(
      output,
      context,
      initialGit.uncommittedProblem() ??
          Diagnostic(
            code: 'RK-GIT-008',
            message: 'the worktree state could not be read',
            remedy: '${initialGit.worktreeStatusError}\n'
                '`git status --porcelain` must succeed before rk can select '
                'the source for this plan.',
          ),
    );
    return _Prepared.stopped(ExitCodes.refused);
  }

  final SourceTree selected;
  try {
    selected = !initialGit.isBound
        ? _captureUnboundPlanSource(context.root)
        : initialGit.isClean && initialGit.head.isNotEmpty
            ? GitCommitSourceTree(context.root, initialGit.head)
            : FrozenSourceTree.capture(GitWorktreeSourceTree(context.root));
  } on SourceUnreadable catch (error) {
    _showPlanSourceProblem(
      output,
      context,
      error.path == 'release.toml' &&
              error.kind == SourceUnreadableKind.wrongType
          ? _wrongReleaseConfigProblem(error.reason)
          : Diagnostic(
              code: 'RK-SRC-003',
              message: 'the source snapshot could not be selected',
              remedy: '${error.path}: ${error.reason}\n'
                  'Stop concurrent edits, then run rk plan again.',
            ),
    );
    return _Prepared.stopped(ExitCodes.refused);
  }

  final diagnostics = Diagnostics();
  String? configSource;
  Resolution? resolution;
  try {
    configSource = selected.read('release.toml');
    if (configSource == null && selected.exists('release.toml')) {
      diagnostics.report(
        _wrongReleaseConfigProblem('release.toml must be a regular file'),
      );
    }
    final config = configSource == null
        ? null
        : ReleaseConfig.parse(configSource, 'release.toml', diagnostics);
    resolution = config == null
        ? null
        : Resolution.resolve(config, selected, diagnostics);
  } on SourceUnreadable catch (error) {
    if (error.path == 'release.toml' &&
        error.kind == SourceUnreadableKind.wrongType) {
      diagnostics.report(_wrongReleaseConfigProblem(error.reason));
    } else {
      diagnostics.add(
        'RK-SRC-003',
        'the selected source could not be read',
        remedy: '${error.path}: ${error.reason}\n'
            'Repair the repository, then run rk plan again.',
      );
    }
  }
  var selectedGit = initialGit;
  if (initialGit.isBound) {
    selectedGit = await GitState.read(context.root);
    if (selectedGit.worktreeStatusError != null) {
      _showPlanSourceProblem(
        output,
        context,
        selectedGit.uncommittedProblem() ??
            Diagnostic(
              code: 'RK-GIT-008',
              message: 'the worktree state could not be re-read',
              remedy: '${selectedGit.worktreeStatusError}\n'
                  '`git status --porcelain` must remain readable while rk '
                  'selects the source for this plan.',
            ),
      );
      return _Prepared.stopped(ExitCodes.refused);
    }
    if (!_samePlanGitIdentity(initialGit, selectedGit)) {
      _showPlanSourceProblem(
        output,
        context,
        const Diagnostic(
          code: 'RK-SRC-003',
          message: 'Git changed while the release plan was being captured',
          remedy: 'Stop concurrent edits or checkouts, then run rk plan '
              'again.',
        ),
      );
      return _Prepared.stopped(ExitCodes.refused);
    }
  }

  if (diagnostics.isNotEmpty) {
    output.repository(
      name: context.root.split('/').last,
      branch: selectedGit.branch,
      commit: selectedGit.hasCommit ? selectedGit.shortHead : null,
      uncommitted: selectedGit.isBound ? selectedGit.uncommitted.length : null,
      head: selectedGit.hasCommit ? selectedGit.head : null,
      remote: selectedGit.originUrl,
    );
    output.blank();
    output.problems(diagnostics.found);
    return _Prepared.stopped(ExitCodes.refused);
  }
  if (configSource == null) {
    _showNoReleaseConfig(output, context.root);
    return _Prepared.stopped(ExitCodes.ok);
  }
  if (resolution == null) {
    _showPlanSourceProblem(
      output,
      SourceContext(tree: selected, git: selectedGit),
      const Diagnostic(
        code: 'RK-SRC-003',
        message: 'the selected source could not be resolved',
        remedy: 'Run rk plan again. If this repeats, report an rk bug.',
      ),
    );
    return _Prepared.stopped(ExitCodes.refused);
  }
  return _Prepared.ready(
    resolution,
    SourceContext(tree: selected, git: selectedGit),
  );
}

/// Freezes only the files plan resolution consumes in an unbound directory.
///
/// The first release.toml read discovers that finite manifest set; the frozen
/// copy must contain the same release.toml bytes or discovery is retried. This
/// avoids both an unbounded recursive snapshot and a plan assembled from two
/// configurations when the file changes between scope discovery and capture.
FrozenSourceTree _captureUnboundPlanSource(String root) {
  final discovery = FileSystemSourceTree(root);
  for (var attempt = 0; attempt < 2; attempt++) {
    final source = discovery.read('release.toml');
    final roots = <String>{'release.toml'};
    final projectPaths = <String>{};
    if (source != null) {
      final diagnostics = Diagnostics();
      final config = ReleaseConfig.parse(source, 'release.toml', diagnostics);
      if (config != null) {
        for (final unit in config.units) {
          for (final project in unit.projects) {
            projectPaths.add(project.path);
            roots.add(
              project.path == '.'
                  ? 'pubspec.yaml'
                  : '${project.path}/pubspec.yaml',
            );
          }
        }
      }
    }
    final frozen = FrozenSourceTree.capture(
      FileSystemSourceTree(
        root,
        roots: roots,
        rootsAreFiles: true,
      ),
      preservePaths: projectPaths,
    );
    if (frozen.read('release.toml') == source) return frozen;
  }
  throw SourceUnreadable(
    'the unbound source',
    'the file changed while plan inputs were being selected',
  );
}

bool _samePlanGitIdentity(GitState before, GitState after) =>
    after.worktreeStatusError == null &&
    before.head == after.head &&
    before.branch == after.branch &&
    before.originUrl == after.originUrl &&
    _sameStrings(before.uncommitted, after.uncommitted);

bool _sameStrings(List<String> before, List<String> after) {
  if (before.length != after.length) return false;
  for (var index = 0; index < before.length; index++) {
    if (before[index] != after[index]) return false;
  }
  return true;
}

void _showNoReleaseConfig(Output output, String root) {
  output.repository(name: root.split('/').last);
  output.blank();
  output.line('no release.toml', mark: Mark.none);
  output.say('rk init writes one, and changes nothing else.');
}

Diagnostic _wrongReleaseConfigProblem(String reason) => Diagnostic(
      code: 'RK-CONF-034',
      message: 'release.toml is there and rk could not read it',
      source: const SourceLocation('release.toml', 1),
      remedy: reason,
    );

void _showPlanSourceProblem(
  Output output,
  SourceContext context,
  Diagnostic problem,
) {
  final git = context.git;
  output.repository(
    name: context.root.split('/').last,
    branch: git.branch,
    commit: git.hasCommit ? git.shortHead : null,
    uncommitted: git.worktreeStatusError == null && git.isBound
        ? git.uncommitted.length
        : null,
    head: git.hasCommit ? git.head : null,
    remote: git.originUrl,
  );
  output.blank();
  output.problem(problem);
}

Future<int> _status(
  Output output,
  String? unit,
) async {
  final prepared = await _prepare(output);
  if (!prepared.isReady) return prepared.code!;
  final source = _selectReleaseSource(prepared, unit, output);
  if (source == null) return ExitCodes.refused;
  final registry = Registry();
  final resolution = source.resolution;
  final tree = source.tree;
  final git = source.binding;
  try {
    final targets = TargetCatalog.builtIn();
    final stages = ReleaseStages(
      source: tree,
      git: git,
      stageContracts: targets.stageContractResolver(resolution),
    );
    const targetTools = SystemTools(timeout: Duration(minutes: 2));
    return await StatusCommand(
      resolution: resolution,
      tree: tree,
      git: git,
      repositoryGit: source.repository,
      sourceWarning: source.warning,
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
    ).run(only: unit);
  } finally {
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
