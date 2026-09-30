import 'dart:convert';
import 'dart:io';

import 'package:rk/src/asset_build.dart';
import 'package:rk/src/engine/checklist.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/engine/workspace.dart';
import 'package:rk/src/output/output.dart';
import 'package:rk/src/output/progress.dart';
import 'package:test/test.dart';

void main() {
  late Directory scratch;
  setUp(() => scratch = Directory.systemTemp.createTempSync('rk-asset-'));
  tearDown(() => scratch.deleteSync(recursive: true));

  final unit = () {
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
    )!.units.single;
  }();
  final project = unit.projects.single;
  final step = Checklist.localProducerSteps(unit).single;
  const key = 'native/parser/tool/build.sh';

  /// A build that answers [result], and writes [writes] into its output.
  /// With a [pause], it keeps running that long after its last line.
  ({AssetBuild build, RecordingTools tools, StringBuffer printed}) harness(
    ToolResult result, {
    List<String> writes = const [],
    Duration? pause,
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
        output: Output(sink: printed.write, isTerminal: false, useColor: false),
        workspace: Workspace('${scratch.path}/stage'),
        sourceRoot: '${scratch.path}/lane',
        cacheDirectory: '${scratch.path}/cache/parser/parser',
      ),
      tools: tools,
      printed: printed,
    );
  }

  test('shows the latest line of the build on its first row', () async {
    final progress = ProgressModel(
      title: 'stage',
      clock: () =>
          () => Duration.zero,
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
    );

    final outcome = await build.build(step, project, progress: handle);

    expect(outcome.ok, isTrue);
    expect(
      [for (final row in progress.rows) row.activity],
      [activity, activity],
      reason: 'the rows keep their activity, and so their elapsed time',
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
    );

    await build.build(step, project, progress: row.handle);

    expect(progress.rows.single.detail, 'three');
  });

  test('tells the build where it writes and what it may keep', () async {
    final (:build, :tools, printed: _) = harness(
      ToolResult(exitCode: 0, stdout: '', stderr: ''),
      writes: ['assets/parser.so', 'parser.dylib'],
    );

    await build.build(
      step,
      project,
      environment: const {'RK_VERSION': '0.1.0'},
    );

    final environment = tools.environments.values.single!;
    expect(environment['RK_VERSION'], '0.1.0');
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
        'program by its path from native/parser, or by a name on PATH.',
      ),
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
