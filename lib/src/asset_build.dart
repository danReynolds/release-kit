import 'dart:async';
import 'dart:io';

import 'binary_chain.dart';
import 'engine/assets.dart';
import 'engine/checklist.dart';
import 'engine/diagnostic.dart';
import 'engine/resolve.dart';
import 'engine/tools.dart';
import 'engine/workspace.dart';
import 'output/output.dart';
import 'output/progress.dart';

/// A project's own build, run for the release assets it declares.
///
/// rk does not know how the assets are made. It runs the command the project
/// declares, from the project's directory in the lane's copy of the staged
/// source, and keeps the files the project declares, under their file names.
/// The command writes to `{out}`, also given as `RK_OUT`: a directory of its
/// own outside the stage, removed afterwards, so nothing else it writes
/// reaches the release.
///
/// Like [BinaryChain], it sits at the top of `lib/src` because it reports
/// through an [Output].
final class AssetBuild {
  AssetBuild({
    required this.tools,
    required this.output,
    required this.workspace,
    required this.sourceRoot,
    this.cacheDirectory,
  });

  final Tools tools;
  final Output output;
  final Workspace workspace;

  /// The lane's copy of the staged source, where the build runs.
  final String sourceRoot;

  /// A directory that outlives every stage, given to the build as
  /// `RK_CACHE` for what it can reuse, such as a compiler's target
  /// directory. Nothing in it reaches a release.
  final String? cacheDirectory;

  /// How many of the build's last lines a failure shows.
  static const _tailLength = 8;

  /// How often the build's latest line may redraw its progress row.
  static const _redraw = Duration(milliseconds: 200);

  /// Runs [project]'s build with [environment] added to rk's own, which
  /// carries the facts a build may need about the release it is part of.
  /// While it runs, the first of [progress]'s rows shows its latest line.
  Future<LocalProducerOutcome> build(
    Step step,
    ResolvedProject project, {
    Map<String, String> environment = const {},
    ProgressHandle? progress,
  }) async {
    final out = Directory.systemTemp.createTempSync('rk-build-');
    try {
      final directory = project.directoryIn(sourceRoot);
      final command = [
        for (final argument in project.build)
          argument.replaceAll('{out}', out.path),
      ];
      // A program named by a relative path is the project's own.
      final program =
          command.first.contains('/') && !command.first.startsWith('/')
          ? '$directory/${command.first}'
          : command.first;
      final cache = cacheDirectory;
      if (cache != null) Directory(cache).createSync(recursive: true);
      final tail = <String>[];
      // The rows the build makes share its elapsed time. Its latest line goes
      // on the first alone, rather than down the whole board.
      final lead = progress?.first;
      final activity = lead?.activity;
      Timer? wait;
      String? unshown;
      void show(String text) {
        lead!.begin(activity!, detail: text);
        // Lines that come before the next redraw wait for it, and only the
        // last of them is shown.
        wait = Timer(_redraw, () {
          wait = null;
          final next = unshown;
          unshown = null;
          if (next != null) show(next);
        });
      }

      void seen(String line) {
        final text = _printable(line);
        if (text == null) return;
        tail.add(text);
        if (tail.length > _tailLength) tail.removeAt(0);
        if (activity == null) return;
        if (wait == null) {
          show(text);
        } else {
          unshown = text;
        }
      }

      final tools = this.tools;
      final arguments = command.sublist(1);
      final env = {
        ...environment,
        'RK_OUT': out.path,
        if (cache != null) 'RK_CACHE': cache,
      };
      final ToolResult result;
      try {
        if (tools is StreamingTools) {
          result = await tools.runStreaming(
            program,
            arguments,
            onLine: seen,
            workingDirectory: directory,
            environment: env,
          );
        } else {
          result = await tools.run(
            program,
            arguments,
            workingDirectory: directory,
            environment: env,
          );
          result.lines.forEach(seen);
        }
      } on ProcessException catch (error) {
        final from = project.pubspec.directory == '.'
            ? 'the repository root'
            : project.pubspec.directory;
        output.problem(
          Diagnostic(
            code: 'RK-BUILD-003',
            message: '${project.name}: its build did not start',
            remedy:
                '${project.build.first} could not start: ${error.message}. '
                'build names a program by its path from $from, or by a name '
                'on PATH. Fix it, then stage ${step.unit} again.',
          ),
          unit: step.unit,
        );
        return const LocalProducerOutcome.failed('the build did not start');
      } finally {
        // The rows settle once the build returns, and must not redraw after.
        wait?.cancel();
      }
      final transcript = [
        result.stdout.trim(),
        result.stderr.trim(),
      ].where((part) => part.isNotEmpty).join('\n');
      if (!result.ok) {
        final ending = tail.isEmpty
            ? '. '
            : ', ending:\n${[for (final line in tail) '  $line'].join('\n')}\n';
        output.problem(
          Diagnostic(
            code: 'RK-BUILD-003',
            message: '${project.name}: its build failed',
            remedy:
                '${project.build.first} exited ${result.exitCode}$ending'
                'Fix the build, then stage ${step.unit} again.',
            evidence: transcript.isEmpty ? null : transcript,
          ),
          unit: step.unit,
        );
        return LocalProducerOutcome.failed(
          'the build exited ${result.exitCode}',
        );
      }
      final missing = [
        for (final declared in project.assets)
          if (FileSystemEntity.typeSync('${out.path}/$declared') !=
              FileSystemEntityType.file)
            declared,
      ];
      if (missing.isNotEmpty) {
        final written = [
          for (final entity in out.listSync(recursive: true))
            if (entity is File) entity.path.substring(out.path.length + 1),
        ]..sort();
        final wrote = written.isEmpty
            ? 'it wrote nothing there'
            : 'it wrote ${written.take(10).join(', ')}'
                  '${written.length > 10 ? ', and ${written.length - 10} more' : ''}';
        output.problem(
          Diagnostic(
            code: 'RK-BUILD-004',
            message:
                '${project.name}: its build did not write '
                '${missing.join(', ')}',
            remedy:
                'assets names files the build writes under {out}, and $wrote. '
                'Make the build write them, or correct assets, then stage '
                '${step.unit} again.',
            evidence: transcript.isEmpty ? null : transcript,
          ),
          unit: step.unit,
        );
        return const LocalProducerOutcome.failed(
          'the build did not write every declared asset',
        );
      }
      for (final declared in project.assets) {
        final staged = File(
          workspace.pathOf(ReleaseAssets.assetPath(project, declared)),
        );
        staged.parent.createSync(recursive: true);
        File('${out.path}/$declared').copySync(staged.path);
      }
      return LocalProducerOutcome.succeeded(
        outputs: [
          for (final entry in ReleaseAssets.assetOutputs(project).entries)
            LocalProducerOutput(entry.key, entry.value),
        ],
        evidence: {'command': project.build},
      );
    } finally {
      out.deleteSync(recursive: true);
    }
  }

  /// [line] as one short printable line, or null when nothing is left once
  /// terminal escapes and control characters are gone.
  static String? _printable(String line) {
    final text = line
        .replaceAll(RegExp(r'\x1b\[[0-?]*[ -/]*[@-~]'), '')
        .replaceAll(RegExp(r'\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)'), '')
        .replaceAll(
          RegExp(
            r'[\x00-\x1f\x7f\u200B-\u200F\u202A-\u202E\u2060-\u206F\uFEFF]',
          ),
          ' ',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (text.isEmpty) return null;
    final runes = text.runes.toList();
    return runes.length <= 100
        ? text
        : '${String.fromCharCodes(runes.take(99))}…';
  }
}
