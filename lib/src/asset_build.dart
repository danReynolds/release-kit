import 'dart:async';
import 'dart:io';

import 'targets/target_module.dart';
import 'engine/assets.dart';
import 'engine/diagnostic.dart';
import 'engine/resolve.dart';
import 'engine/stage.dart';
import 'engine/tools.dart';
import 'engine/unit_release.dart';
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
    required this.stage,
    required this.sourceRoot,
    this.cacheDirectory,
  });

  final Tools tools;
  final Output output;

  /// Where the declared assets are kept.
  final Stage stage;

  /// The lane's copy of the staged source, where the build runs.
  final String sourceRoot;

  /// A directory that outlives every stage, given to the build as
  /// `RK_CACHE` for what it can reuse, such as a compiler's target
  /// directory. rk never publishes it; what the build makes from it is what
  /// gets released, so a build reuses from it only what it can check.
  final String? cacheDirectory;

  /// How many of the build's last lines a failure shows.
  static const _tailLength = 8;

  /// How often the build's latest line may redraw its progress row.
  static const _redraw = Duration(milliseconds: 200);

  /// Runs [project]'s build with [environment] added to rk's own, which
  /// carries the facts a build may need about the release it is part of.
  /// While it runs, the first of [progress]'s rows shows its latest line.
  Future<Produced> build(
    Work step,
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
      if (cache != null) {
        try {
          Directory(cache).createSync(recursive: true);
        } on FileSystemException catch (error) {
          output.problem(
            Diagnostic(
              code: 'RK-BUILD-003',
              message: '${project.name}: its build cache could not be made',
              remedy:
                  '$cache: ${error.osError?.message ?? error.message}. '
                  'Remove what is in the way, then stage ${step.unit} again.',
            ),
            unit: step.unit,
          );
          return const Produced.failed();
        }
      }
      final tail = <String>[];
      // The rows the build makes share its elapsed time. Its latest line goes
      // on the first alone, rather than down the whole board, and only on a
      // terminal: a log keeps whichever line happened to be current.
      final lead = output.isTerminal ? progress?.first : null;
      final activity = lead?.activity;
      Timer? wait;
      String? unshown;
      void show(String text) {
        if (!lead!.active) return;
        lead.begin(activity!, detail: text);
        // Lines that come before the next redraw wait for it, and only the
        // last of them is shown.
        wait = Timer(_redraw, () {
          wait = null;
          final next = unshown;
          unshown = null;
          if (next != null) show(next);
        });
      }

      void seen(String raw) {
        // Paths into the lane's copy read as the repository's own.
        final line = raw.replaceAll('$sourceRoot/', '');
        final kept = _readable(line);
        if (kept == null) return;
        tail.add(kept);
        if (tail.length > _tailLength) tail.removeAt(0);
        final text = _printable(line);
        if (activity == null || text == null) return;
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
                'on PATH, and a script needs its executable bit and the '
                'interpreter its first line names. Fix it, then stage '
                '${step.unit} again.',
          ),
          unit: step.unit,
        );
        return const Produced.failed();
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
        return const Produced.failed();
      }
      final missing = [
        for (final declared in project.assets)
          if (FileSystemEntity.typeSync('${out.path}/$declared') !=
              FileSystemEntityType.file)
            declared,
      ];
      if (missing.isNotEmpty) {
        final written = [
          for (final entity in out.listSync(
            recursive: true,
            followLinks: false,
          ))
            if (entity is File || entity is Link)
              entity.path
                  .substring(out.path.length + 1)
                  .replaceAll(Platform.pathSeparator, '/'),
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
        return const Produced.failed();
      }
      for (final declared in project.assets) {
        final staged = File(
          stage.pathOf(ReleaseAssets.assetPath(project, declared)),
        );
        staged.parent.createSync(recursive: true);
        File('${out.path}/$declared').copySync(staged.path);
      }
      return Produced(evidence: {'command': project.build, 'cache': ?cache});
    } finally {
      out.deleteSync(recursive: true);
    }
  }

  /// [line] as a failure's remedy shows it: terminal escapes gone, spacing
  /// kept, since a caret under a column means something, and a line too long
  /// to read kept at both ends. Null for a blank line.
  static String? _readable(String line) {
    final text = _expandTabs(
      _withoutEscapes(line),
    ).replaceAll(invisibleCharacters, ' ').trimRight();
    if (text.trim().isEmpty) return null;
    final runes = text.runes.toList();
    return runes.length <= 300
        ? text
        : '${String.fromCharCodes(runes.take(150))}…'
              '${String.fromCharCodes(runes.skip(runes.length - 149))}';
  }

  static String _withoutEscapes(String line) => line
      .replaceAll(RegExp(r'\x1b\[[0-?]*[ -/]*[@-~]'), '')
      .replaceAll(RegExp(r'\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)'), '')
      // A character set's designation, then any other escape.
      .replaceAll(RegExp(r'\x1b[()*+].'), '')
      .replaceAll(RegExp(r'\x1b[@-_]'), '');

  /// [line] with each tab widened to the next eighth column, as a terminal
  /// would show it, so what lines up under it still does.
  static String _expandTabs(String line) {
    if (!line.contains('\t')) return line;
    final out = StringBuffer();
    var column = 0;
    for (final rune in line.runes) {
      if (rune == 9) {
        final pad = 8 - column % 8;
        out.write(' ' * pad);
        column += pad;
      } else {
        out.writeCharCode(rune);
        column++;
      }
    }
    return out.toString();
  }

  /// [line] as one short printable line, or null when nothing is left once
  /// terminal escapes and control characters are gone.
  static String? _printable(String line) {
    final text = _withoutEscapes(line)
        .replaceAll(invisibleCharacters, ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (text.isEmpty) return null;
    final runes = text.runes.toList();
    return runes.length <= 100
        ? text
        : '${String.fromCharCodes(runes.take(99))}…';
  }
}
