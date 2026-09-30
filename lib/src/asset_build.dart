import 'dart:io';

import 'binary_chain.dart';
import 'engine/assets.dart';
import 'engine/checklist.dart';
import 'engine/diagnostic.dart';
import 'engine/resolve.dart';
import 'engine/tools.dart';
import 'engine/workspace.dart';
import 'output/output.dart';

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
  });

  final Tools tools;
  final Output output;
  final Workspace workspace;

  /// The lane's copy of the staged source, where the build runs.
  final String sourceRoot;

  /// Runs [project]'s build with [environment] added to rk's own, which
  /// carries the facts a build may need about the release it is part of.
  Future<LocalProducerOutcome> build(
    Step step,
    ResolvedProject project, {
    Map<String, String> environment = const {},
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
      final result = await tools.run(
        program,
        command.sublist(1),
        workingDirectory: directory,
        environment: {...environment, 'RK_OUT': out.path},
      );
      final transcript = [
        result.stdout.trim(),
        result.stderr.trim(),
      ].where((part) => part.isNotEmpty).join('\n');
      if (!result.ok) {
        output.problem(
          Diagnostic(
            code: 'RK-BUILD-003',
            message: '${project.name}: its build failed',
            remedy:
                '${project.build.first} exited ${result.exitCode}. Fix the '
                'build, then stage ${step.unit} again.',
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
        output.problem(
          Diagnostic(
            code: 'RK-BUILD-004',
            message:
                '${project.name}: its build did not write '
                '${missing.join(', ')}',
            remedy:
                'assets names files the build writes under {out}. Make the '
                'build write them, or correct assets, then stage '
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
}
