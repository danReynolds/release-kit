/// rk's entry point, and its composition root.
///
/// Everything a run needs is built here and nowhere else: this file finds the
/// git root, reads and parses `release.toml`, resolves it against the
/// repository, and constructs the `Registry`, `SystemTools`, and `Output` the
/// verbs are handed. It then dispatches to one of the three verbs
/// and, on a run that failed after acting, writes the diagnosis.
///
/// So the answer to "where does rk read release.toml?" is `_prepare` below,
/// not a file under `lib/`. Reading files and deciding exit codes is
/// composition-root work; pushing it down would put `dart:io` in the layer
/// `engine/source_tree.dart` exists to keep testable.
library;

import 'dart:io';

import 'package:release_kit/src/commands/init.dart';
import 'package:release_kit/src/commands/init_selector.dart';
import 'package:release_kit/src/commands/release.dart';
import 'package:release_kit/src/commands/status.dart';
import 'package:release_kit/src/destinations/pub_dev.dart';
import 'package:release_kit/src/engine/compare.dart';
import 'package:release_kit/src/engine/config.dart';
import 'package:release_kit/src/output/diagnosis.dart';
import 'package:release_kit/src/engine/diagnostic.dart';
import 'package:release_kit/src/engine/git.dart';
import 'package:release_kit/src/engine/inspect.dart';
import 'package:release_kit/src/engine/init_plan.dart';
import 'package:release_kit/src/engine/dart_workspace.dart';
import 'package:release_kit/src/engine/publish_target.dart';
import 'package:release_kit/src/output/output.dart';
import 'package:release_kit/src/engine/registry.dart';
import 'package:release_kit/src/engine/resolve.dart';
import 'package:release_kit/src/engine/release_stage.dart';
import 'package:release_kit/src/engine/source_tree.dart';
import 'package:release_kit/src/engine/source_context.dart';
import 'package:release_kit/src/engine/tools.dart';
import 'package:release_kit/src/targets/catalog.dart';
import 'package:release_kit/src/version.dart';

const _usage = '''
rk — an austere release tool

Usage
  rk                              status all units
  rk --version                    print this binary's version
  rk status [unit]                status all units or one
  rk init                         propose release.toml; write only on a yes
  rk release [unit]               stage, confirm, then publish one unit
  rk release [unit] --stage       prepare its exact stage; publish nothing

Flags
  --version   print this binary's version and exit
  --json      the machine surface (doc/json.md)
  --stage     release: build, sign, and notarize exact artifacts; publish nothing
  --confirm=<version>
              release: authorize exactly this version without a prompt
  --write     init: accept the proposal without a prompt

Marks: ✓ done,  · already satisfied,  ✗ problem or conflict,  → your next move,
       unmarked pending
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
    '--confirm',
    '--write',
  };
  // --confirm carries the exact version as its value: the typed yes for
  // scripts and agents, the same door init opens with --write. A bare
  // --confirm authorizes nothing and is refused below.
  final confirmVersions = <String>{};
  final flags = <String>{};
  for (final flag in args.where((a) => a.startsWith('-'))) {
    if (flag.startsWith('--confirm=')) {
      confirmVersions.add(flag.substring('--confirm='.length));
      flags.add('--confirm');
    } else {
      flags.add(flag);
    }
  }
  final confirmVersion =
      confirmVersions.length == 1 ? confirmVersions.single : null;
  final positional = args.where((a) => !a.startsWith('-')).toList();
  final json = flags.contains('--json');

  const verbs = {'status', 'release', 'init'};
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
    'release': {'-h', '--help', '--json', '--stage', '--confirm'},
    'init': {'-h', '--help', '--json', '--write'},
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

  if (flags.contains('--confirm') &&
      (confirmVersion == null || confirmVersion.isEmpty) &&
      !flags.contains('-h') &&
      !flags.contains('--help')) {
    // Bare, empty, or contradictory: none of these name one version, and
    // two authorizations are refused the way two positionals are — not
    // repaired by picking one.
    output.problem(
      Diagnostic(
        code: 'RK-CLI-009',
        message: '--confirm names the exact version it authorizes',
        remedy: 'rk release <unit> --confirm=<version>, exactly once — the '
            'flag is the typed yes, so it must say what it says yes to',
      ),
    );
    exitCode = ExitCodes.usage;
    if (json) stdout.write(output.report.encode(exit: ExitCodes.usage));
    return;
  }

  if (flags.contains('--confirm') &&
      flags.contains('--stage') &&
      !flags.contains('-h') &&
      !flags.contains('--help')) {
    // Staging publishes nothing, so there is nothing the yes could apply
    // to; accepting and discarding an authorization teaches callers that
    // consent is decorative.
    output.problem(
      Diagnostic(
        code: 'RK-CLI-005',
        message: 'rk release --stage does not have --confirm',
        remedy: 'staging publishes nothing, so it takes no authorization. '
            'Stage first, then rk release <unit> --confirm=<version>',
      ),
    );
    exitCode = ExitCodes.usage;
    if (json) stdout.write(output.report.encode(exit: ExitCodes.usage));
    return;
  }

  // Misuse is refused, not repaired: a third word would be dropped as if it
  // had not been said, and `rk init somepkg` would configure the whole
  // repository while reading as if it had scoped itself to one unit.
  if (positional.length > 2 || (command == 'init' && target != null)) {
    output.problem(
      Diagnostic(
        code: 'RK-CLI-007',
        message: command == 'init' && positional.length <= 2
            ? 'rk init takes no unit — it proposes for the whole '
                'repository, and got "$target"'
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
      'release' => await _release(
          output,
          target,
          stageOnly: flags.contains('--stage'),
          interactive: !json,
          confirmVersion: confirmVersion,
        ),
      'init' => await _init(
          output,
          interactive: !json,
          write: flags.contains('--write'),
        ),
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
  final git = gitRoot == null ? GitState.unbound(root) : GitState.read(root);
  final selectorEnabled = interactive && !write && _usableInitTerminal();

  return InitCommand(
    tree: tree,
    output: output,
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
  bool get useColor => !Platform.environment.containsKey('NO_COLOR');

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
  String? confirmVersion,
}) async {
  final prepared = _prepare(output);
  if (!prepared.isReady) return prepared.code!;
  final resolution = prepared.resolution!;
  final context = prepared.context!;
  final tree = context.tree;
  final git = context.git;
  final registry = prepared.registry!;
  final targets = TargetCatalog.builtIn();
  final stages = ReleaseStages(
    source: tree,
    git: git,
    stageContracts: targets.stageContractResolver(resolution),
  );
  const targetTools = SystemTools(timeout: Duration(minutes: 2));
  try {
    return await ReleaseCommand(
      resolution: resolution,
      tree: tree,
      git: git,
      inspector: Inspector(
        registry: registry,
        pubDev: PubDevTarget(
          registry: registry,
          comparator: Comparator(tools: targetTools),
          source:
              git.isBound ? GitCommitSourceTree(context.root, git.head) : tree,
          allowCurrentSourceFallback: git.isBound,
        ),
        git: git,
        tools: targetTools,
        repository: git.originUrl,
        stageFor: stages.call,
        targets: targets,
      ),
      tools: const SystemTools(),
      output: output,
      // The prompt is written straight to stdout, past the sink --json
      // silences: asking would corrupt the document, and the consequences the
      // prompt exists to disclose would be suppressed while the question was
      // still asked. release already refuses when nobody can authorize.
      // --confirm is the typed yes carried as a flag: it supplies exactly
      // what the operator would type, authorizes only the version it names,
      // and skips no inspection on the way there.
      confirm: confirmVersion != null
          ? (_) async => confirmVersion
          : interactive && stdin.hasTerminal
              ? _promptOnTerminal
              : null,
      preauthorized: confirmVersion,
      stageOnly: stageOnly,
      stageFor: stages.call,
      refreshStage: stages.refresh,
      refreshGit: () => git.isBound
          ? GitState.read(context.root)
          : GitState.unbound(context.root),
    ).run(only: unit);
  } finally {
    registry.close();
  }
}

/// Asks at the terminal, or answers null when there is none.
///
/// Lives at the entry point rather than in a command file: reading a line
/// from a person is this program's edge, and a verb that could reach for
/// stdin is a verb that could ask a question no caller can answer.
Future<String?> _promptOnTerminal(String prompt) async {
  if (!stdin.hasTerminal) return null;
  stdout.write(prompt);
  return stdin.readLineSync();
}

/// What reading the repository produced: either everything a command needs,
/// or the exit code that reading it decided.
///
/// Not-onboarded is exit 0, since a repository without a release.toml is a
/// correct answer rather than a failure — an agent sweeping a fleet must not
/// see a fault for every repository that simply does not use rk.
class _Prepared {
  _Prepared.ready(this.resolution, this.context, this.registry) : code = null;
  _Prepared.stopped(this.code)
      : resolution = null,
        context = null,
        registry = null;

  final Resolution? resolution;
  final SourceContext? context;
  final Registry? registry;
  final int? code;

  bool get isReady => code == null;
}

_Prepared _prepare(Output output) {
  final gitRoot = GitSourceTree.findRoot(Directory.current.path);
  final root = gitRoot ?? Directory.current.absolute.path;
  SourceTree tree =
      gitRoot == null ? FileSystemSourceTree(root) : GitSourceTree(gitRoot);
  final git = gitRoot == null ? GitState.unbound(root) : GitState.read(root);
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
  var resolution =
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
    Registry(),
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

Future<int> _status(
  Output output,
  String? unit,
) async {
  final prepared = _prepare(output);
  if (!prepared.isReady) return prepared.code!;
  final resolution = prepared.resolution!;
  final context = prepared.context!;
  final tree = context.tree;
  final git = context.git;
  final registry = prepared.registry!;
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
      inspector: Inspector(
        registry: registry,
        pubDev: PubDevTarget(
          registry: registry,
          comparator: Comparator(tools: targetTools),
          source:
              git.isBound ? GitCommitSourceTree(context.root, git.head) : tree,
          allowCurrentSourceFallback: git.isBound,
        ),
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
