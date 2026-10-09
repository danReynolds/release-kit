import 'dart:convert';
import 'dart:io';

import 'package:rk/src/asset_build.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/engine/unit_release.dart';
import 'package:rk/src/engine/workspace.dart';
import 'package:rk/src/output/output.dart';
import 'package:rk/src/output/progress.dart';
import 'package:test/test.dart';
import 'support/memory_source_tree.dart';

void main() {
  late Directory scratch;
  setUp(() => scratch = Directory.systemTemp.createTempSync('rk-asset-'));
  tearDown(() => scratch.deleteSync(recursive: true));

  final resolution = () {
    final diagnostics = Diagnostics();
    final config = ReleaseConfig.parse(
      '''
schema = 2

[release.parser]
tag = "parser-v{version}"
path = "native/parser"
publish = ["git-tag", "github-release"]
build = ["tool/build.sh", "{out}"]
assets = ["assets/parser.so", "parser.dylib"]
''',
      'release.toml',
      diagnostics,
    )!;
    return Resolution.resolve(
      config,
      MemorySourceTree({
        'native/parser/Cargo.toml':
            '[package]\nname = "parser"\nversion = "0.1.0"\n',
      }),
      diagnostics,
    )!;
  }();
  final unit = resolution.units.single;
  final project = unit.projects.single;
  final step = UnitRelease.derive(
    unit,
    resolution,
    repository: null,
    problems: Diagnostics(),
  ).work.first;
  const key = 'native/parser/tool/build.sh';

  /// A build that answers [result], and writes [writes] into its output.
  /// With a [pause], it keeps running that long after its last line.
  ({AssetBuild build, RecordingTools tools, StringBuffer printed}) harness(
    ToolResult result, {
    List<String> writes = const [],
    Duration? pause,
    bool terminal = false,
  }) {
    late final RecordingTools tools;
    void onRun(String call) {
      final out = tools.environments[call]!['RK_OUT']!;
      for (final path in writes) {
        File('$out/$path')
          ..createSync(recursive: true)
          ..writeAsStringSync(path);
      }
    }

    tools = pause == null
        ? RecordingTools(answers: (_) => result, onRun: onRun)
        : _PausingTools(answers: (_) => result, onRun: onRun, pause: pause);
    final printed = StringBuffer();
    return (
      build: AssetBuild(
        tools: tools,
        output: Output(
          sink: printed.write,
          isTerminal: terminal,
          useColor: false,
          terminalWidth: terminal ? 80 : null,
        ),
        workspace: Workspace('${scratch.path}/stage'),
        sourceRoot: '${scratch.path}/lane',
        cacheDirectory: '${scratch.path}/cache/parser/parser',
      ),
      tools: tools,
      printed: printed,
    );
  }

  test('shows the latest line of the build on its first row', () async {
    // Each start of an activity reads a later time, so a row that restarted
    // would show it.
    var starts = 0;
    final progress = ProgressModel(
      title: 'stage',
      clock: () {
        final at = Duration(seconds: ++starts);
        return () => at;
      },
      changed: (_) {},
    );
    final rows = [
      progress.addRow(id: 'so', label: 'parser.so'),
      progress.addRow(id: 'dylib', label: 'parser.dylib'),
    ];
    final handle = ProgressHandle.combine([for (final row in rows) row.handle]);
    final activity = ProgressActivity(
      running: 'building',
      failed: 'build failed',
    );
    handle.begin(activity);
    final (:build, :tools, printed: _) = harness(
      ToolResult(
        exitCode: 0,
        stdout: '\x1b[1m\x1b[32m   Compiling\x1b[0m comrak v0.54.0\r\nlater\n',
        stderr: '',
      ),
      writes: ['assets/parser.so', 'parser.dylib'],
      terminal: true,
    );

    final outcome = await build.build(step, project, progress: handle);

    expect(outcome.ok, isTrue);
    expect(
      [for (final row in progress.rows) row.activity],
      [activity, activity],
    );
    expect(
      [for (final row in progress.rows) row.elapsed],
      [const Duration(seconds: 1), const Duration(seconds: 2)],
      reason: 'the rows keep the time they started, and so their elapsed time',
    );
    expect(
      [for (final row in progress.rows) row.detail],
      ['Compiling comrak v0.54.0', null],
      reason:
          'terminal escapes are dropped, the next line comes too soon after '
          'this one to redraw, and the second row does not repeat the first',
    );
    expect(
      tools.calls.single,
      startsWith('${scratch.path}/lane/$key '),
      reason: "the build runs from the lane's copy of the source",
    );

    for (final row in rows) {
      row.complete(note: 'built');
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(
      [for (final row in progress.rows) row.note],
      ['built', 'built'],
      reason: 'a line still waiting to be shown does not redraw a settled row',
    );
  });

  test('shows the last line of a burst once the burst is over', () async {
    final progress = ProgressModel(
      title: 'stage',
      clock: () =>
          () => Duration.zero,
      changed: (_) {},
    );
    final row = progress.addRow(id: 'so', label: 'parser.so');
    final activity = ProgressActivity(
      running: 'building',
      failed: 'build failed',
    );
    row.handle.begin(activity);
    final (:build, tools: _, printed: _) = harness(
      ToolResult(exitCode: 0, stdout: 'one\ntwo\nthree\n', stderr: ''),
      writes: ['assets/parser.so', 'parser.dylib'],
      pause: const Duration(milliseconds: 400),
      terminal: true,
    );

    await build.build(step, project, progress: row.handle);

    expect(progress.rows.single.detail, 'three');
  });

  test('leaves the row alone without a terminal', () async {
    final progress = ProgressModel(
      title: 'stage',
      clock: () =>
          () => Duration.zero,
      changed: (_) {},
    );
    final row = progress.addRow(id: 'so', label: 'parser.so');
    final activity = ProgressActivity(
      running: 'building',
      failed: 'build failed',
    );
    row.handle.begin(activity);
    final (:build, tools: _, printed: _) = harness(
      ToolResult(exitCode: 0, stdout: 'Compiling comrak\n', stderr: ''),
      writes: ['assets/parser.so', 'parser.dylib'],
    );

    await build.build(step, project, progress: row.handle);

    expect(
      progress.rows.single.detail,
      isNull,
      reason: 'a log would keep whichever line was current when it printed',
    );
  });

  test('ends a failed build with lines that still say what failed', () async {
    final lane = '${scratch.path}/lane';
    final (:build, tools: _, :printed) = harness(
      ToolResult(
        exitCode: 1,
        stdout: '',
        stderr:
            '\x1b[1m$lane/native/parser/src/parser.c:3:5: \x1b[31merror:'
            '\x1b[0m expected ;\n'
            '    return x\n'
            '           ^\n'
            '\tat Parser.parse(Parser.java:12)\n'
            'plain\x1b(B text\u202e reversed\n',
      ),
    );

    await build.build(step, project);

    final remedy = problems(build).single['remedy']! as String;
    expect(
      remedy,
      contains('  native/parser/src/parser.c:3:5: error: expected ;\n'),
      reason: 'escapes go, and a path into the lane reads as the repository\'s',
    );
    expect(
      remedy,
      contains('      return x\n             ^\n'),
      reason: 'a caret stays under its column',
    );
    expect(
      remedy,
      contains('          at Parser.parse(Parser.java:12)\n'),
      reason: 'a tab widens to the next eighth column',
    );
    expect(
      remedy,
      contains('  plain text  reversed\n'),
      reason: 'no escape, control or bidi character reaches the terminal',
    );
    expect(printed.toString(), contains('error: expected ;'));
  });

  test('says when the cache cannot be made', () async {
    File('${scratch.path}/cache/parser')
      ..createSync(recursive: true)
      ..writeAsStringSync('in the way');
    final (:build, :tools, printed: _) = harness(
      ToolResult(exitCode: 0, stdout: '', stderr: ''),
    );

    final outcome = await build.build(step, project);

    expect(outcome.ok, isFalse);
    expect(tools.calls, isEmpty, reason: 'the build never ran');
    expect(problems(build).single['code'], 'RK-BUILD-003');
    expect(
      problems(build).single['message'],
      'parser: its build cache could not be made',
    );
  });

  test('tells the build where it writes and what it may keep', () async {
    final (:build, :tools, printed: _) = harness(
      ToolResult(exitCode: 0, stdout: '', stderr: ''),
      writes: ['assets/parser.so', 'parser.dylib'],
    );

    final outcome = await build.build(
      step,
      project,
      environment: const {'RK_VERSION': '0.1.0'},
    );

    final environment = tools.environments.values.single!;
    expect(environment['RK_VERSION'], '0.1.0');
    expect(
      outcome.evidence['cache'],
      '${scratch.path}/cache/parser/parser',
      reason: 'the stage records that its build could reuse a cache',
    );
    expect(environment['RK_CACHE'], '${scratch.path}/cache/parser/parser');
    expect(Directory(environment['RK_CACHE']!).existsSync(), isTrue);
    expect(
      Directory(environment['RK_OUT']!).existsSync(),
      isFalse,
      reason: 'the output directory goes once its files are staged',
    );
    expect(
      Directory(environment['RK_CACHE']!).existsSync(),
      isTrue,
      reason: 'the cache stays for the next stage',
    );
  });

  test('ends a failed build with its last lines', () async {
    final (:build, tools: _, :printed) = harness(
      ToolResult(
        exitCode: 3,
        stdout: [for (var i = 1; i <= 12; i++) 'line $i'].join('\n'),
        stderr: 'error: no linker for the target\n',
      ),
    );

    final outcome = await build.build(step, project);

    expect(outcome.ok, isFalse);
    expect(problems(build).single['code'], 'RK-BUILD-003');
    final text = printed.toString();
    expect(text, contains('parser: its build failed'));
    expect(text, contains('tool/build.sh exited 3, ending:'));
    expect(text, contains('error: no linker for the target'));
    expect(text, contains('line 12'));
    expect(text, contains('line 6'));
    expect(
      text,
      isNot(contains('line 5\n')),
      reason: 'the last eight lines, not the whole transcript',
    );
  });

  test('says when the build cannot start', () async {
    final printed = StringBuffer();
    final build = AssetBuild(
      tools: RecordingTools(
        answers: (_) => throw const ProcessException(
          'tool/build.sh',
          [],
          'Permission denied',
          13,
        ),
      ),
      output: Output(sink: printed.write, isTerminal: false, useColor: false),
      workspace: Workspace('${scratch.path}/stage'),
      sourceRoot: '${scratch.path}/lane',
    );

    final outcome = await build.build(step, project);

    expect(outcome.ok, isFalse);
    expect(problems(build).single['code'], 'RK-BUILD-003');
    final text = printed.toString();
    expect(text, contains('parser: its build did not start'));
    expect(
      text,
      contains(
        'tool/build.sh could not start: Permission denied. build names a '
        'program by its path from native/parser, or by a name on PATH, and a '
        'script needs its executable bit',
      ),
    );
  });

  test('names a link the build wrote among what it wrote', () async {
    late final RecordingTools tools;
    tools = RecordingTools(
      answers: (_) => ToolResult(exitCode: 0, stdout: '', stderr: ''),
      onRun: (call) {
        final out = tools.environments[call]!['RK_OUT']!;
        File('$out/assets/parser.so')
          ..createSync(recursive: true)
          ..writeAsStringSync('so');
        Link('$out/libparser.so').createSync('assets/parser.so');
      },
    );
    final build = AssetBuild(
      tools: tools,
      output: Output(sink: (_) {}, isTerminal: false, useColor: false),
      workspace: Workspace('${scratch.path}/stage'),
      sourceRoot: '${scratch.path}/lane',
    );

    await build.build(step, project);

    expect(
      problems(build).single['remedy'],
      contains('it wrote assets/parser.so, libparser.so.'),
    );
  });

  test('names what a build wrote when it misses a declared asset', () async {
    final (:build, tools: _, :printed) = harness(
      ToolResult(exitCode: 0, stdout: '', stderr: ''),
      writes: ['assets/parser.so', 'assets/parser-debug.so'],
    );

    final outcome = await build.build(step, project);

    expect(outcome.ok, isFalse);
    expect(problems(build).single['code'], 'RK-BUILD-004');
    final text = printed.toString();
    expect(text, contains('parser: its build did not write parser.dylib'));
    expect(text, contains('it wrote assets/parser-debug.so, assets/parser.so'));
  });
}

/// The problems [build] reported, as `--json` carries them.
List<Map<String, Object?>> problems(AssetBuild build) => [
  for (final problem
      in (jsonDecode(build.output.report.encode(exit: 1)) as Map)['problems']
          as List)
    (problem as Map).cast<String, Object?>(),
];

/// Hands over its answer's lines at once, then runs on for [pause].
final class _PausingTools extends RecordingTools {
  _PausingTools({super.answers, super.onRun, required this.pause});

  final Duration pause;

  @override
  Future<ToolResult> runStreaming(
    String executable,
    List<String> arguments, {
    required void Function(String line) onLine,
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    final result = await run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    );
    result.lines.forEach(onLine);
    await Future<void>.delayed(pause);
    return result;
  }
}
