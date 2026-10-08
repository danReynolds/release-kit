import 'dart:io';

import '../engine/stage_plan.dart';
import '../engine/tools.dart';
import 'binary_artifact.dart';
import 'capability.dart';
import 'dart_launcher.dart';

/// Builds a Dart executable for one platform, and runs what it produced.
///
/// The smoke test is part of building rather than a later step someone
/// could skip — and where the host cannot run the result at all, the build
/// succeeds with [BuildOutcome.unproven] set rather than failing. What rk
/// will not do is claim a binary was checked when it was not.
class DartCliBuilder {
  DartCliBuilder({
    required this.tools,
    required this.capabilities,
    this.compilerExecutable = 'dart',
  });

  final Tools tools;
  final HostCapabilities capabilities;

  /// The SDK's `dart`; beside it, the runtime a bundle ships.
  final String compilerExecutable;

  /// Compiles [entryPoint] for [platform], writing to [output].
  Future<BuildOutcome> build({
    required String platform,
    required String entryPoint,
    required String output,
    required String workingDirectory,
    required String expectedVersion,
    Map<String, String> defines = const {},
    void Function(DartBuildEvent event)? onProgress,
    Future<ToolResult> Function(List<String> arguments)? runCompiler,
  }) async {
    // The caller refuses an unproducible platform with a diagnostic before
    // reaching here, so this asks only *how* to produce it.
    final capability = capabilities.resolve(platform);

    final target = _target(platform);
    final artifact = BinaryArtifact.forPlatform(_fileNameOf(output), platform);
    final root = _directoryOf(output);
    final module = artifact.isBundle
        ? '$root/lib/${artifact.entryPoint}/app.aot'
        : output;
    if (artifact.isBundle) File(module).parent.createSync(recursive: true);
    final arguments = [
      'compile',
      artifact.isBundle ? 'aot-snapshot' : 'exe',
      for (final name in defines.keys.toList()..sort())
        '-D$name=${defines[name]}',
      if (capability.capability == Capability.crossCompiled ||
          capability.capability == Capability.buildableUnproven) ...[
        '--target-os=${target.os}',
        '--target-arch=${target.arch}',
      ],
      entryPoint,
      '-o',
      module,
    ];
    final compiled = runCompiler == null
        ? await tools.run(
            compilerExecutable,
            arguments,
            workingDirectory: workingDirectory,
          )
        : await runCompiler(arguments);

    if (!compiled.ok) {
      return BuildOutcome.failed(
        compiled.summary,
        transcript: compiled.transcript,
      );
    }

    if (artifact.isBundle) {
      // Homebrew rewrites each library's install name to its keg path and
      // re-signs it ad hoc, which the signed runtime then refuses. The
      // generated formula preserves @rpath names, so this one keeps the
      // module's bytes intact.
      final named = await tools.run('/usr/bin/install_name_tool', [
        '-id',
        '@rpath/app.aot',
        module,
      ]);
      if (!named.ok) {
        return BuildOutcome.failed(
          'the Dart module install name could not be set',
          transcript: named.transcript,
        );
      }
      try {
        final assembled = await _assembleBundle(artifact, root);
        if (assembled != null) return assembled;
      } on FileSystemException catch (error) {
        return BuildOutcome.failed(
          'the Dart bundle could not be assembled: $error',
        );
      } on DartSdkUnavailable catch (error) {
        return BuildOutcome.failed('$error');
      } on StateError catch (error) {
        return BuildOutcome.failed('$error');
      }
    }

    // Another platform's binary runs in a container, when one answers.
    final runtime =
        capability.capability == Capability.native || !capability.canProve
        ? null
        : await capabilities.containerRuntime();
    if (!capability.canProve ||
        (capability.capability != Capability.native && runtime == null)) {
      // Built, and nothing here can run it. The absence of the proof is
      // carried forward rather than swallowed or treated as a failure.
      return BuildOutcome.built(
        output,
        unproven: capability.reason ?? noContainerRuntime,
      );
    }

    onProgress?.call(DartBuildEvent.testing);
    final smoke = await _smokeTest(
      platform: platform,
      binary: output,
      runtime: runtime,
      expectedVersion: expectedVersion,
    );
    if (smoke != null) return smoke;

    return BuildOutcome.built(output);
  }

  Future<BuildOutcome?> _assembleBundle(
    BinaryArtifact artifact,
    String root,
  ) async {
    final compiler = compilerExecutable == 'dart'
        ? DartSdk.ambient().executable
        : File(compilerExecutable).absolute.path;
    final runtime = '${File(compiler).parent.path}/dartaotruntime';
    final installedRuntime = '$root/${artifact.identityFile}';
    final copied = await tools.run('/bin/cp', [runtime, installedRuntime]);
    if (!copied.ok) {
      return BuildOutcome.failed(
        'the matching Dart runtime could not be copied',
        transcript: copied.transcript,
      );
    }
    final licensePath = '$root/lib/${artifact.entryPoint}/LICENSE.dart';
    final license = await tools.run('/bin/cp', [
      '${File(compiler).parent.parent.path}/LICENSE',
      licensePath,
    ]);
    if (!license.ok) {
      return BuildOutcome.failed(
        'the Dart runtime license could not be copied',
        transcript: license.transcript,
      );
    }
    final scratch = Directory.systemTemp.createTempSync('rk-dart-launcher-');
    final source = File('${scratch.path}/launcher.c');
    try {
      source.writeAsStringSync(dartLauncherSource(artifact.entryPoint));
      // Xcode's clang shim finds the SDK itself.
      final launcher = await tools.run('/usr/bin/clang', [
        '-O2',
        '-Wall',
        '-Werror',
        source.path,
        '-o',
        '$root/${artifact.entryPoint}',
      ]);
      if (!launcher.ok) {
        return BuildOutcome.failed(
          'the native launcher could not be built',
          transcript: launcher.transcript,
        );
      }
    } finally {
      scratch.deleteSync(recursive: true);
    }
    File(
      '$root/${BinaryArtifact.manifestName}',
    ).writeAsStringSync(artifact.manifest);
    for (final file in artifact.files) {
      final mode = await tools.run('/bin/chmod', [
        file.mode,
        '$root/${file.path}',
      ]);
      if (!mode.ok) {
        return BuildOutcome.failed(mode.summary, transcript: mode.transcript);
      }
    }
    return null;
  }

  /// Runs the binary and checks it reports the version being released.
  ///
  /// The strongest cheap signal that the right thing was built: a binary that
  /// prints the wrong version is one nobody should ship, and it is exactly
  /// what a stale artifact looks like.
  /// [runtime] runs another platform's binary; null runs it here.
  Future<BuildOutcome?> _smokeTest({
    required String platform,
    required String binary,
    required String? runtime,
    required String expectedVersion,
  }) async {
    final ToolResult result;
    if (runtime == null) {
      result = await tools.run(binary, const [
        '--version',
      ], timeout: _smokeTimeout);
    } else {
      final target = _target(platform);
      result = await tools.run(runtime, [
        'run',
        '--rm',
        '--platform',
        'linux/${target.arch == 'x64' ? 'amd64' : 'arm64'}',
        '-v',
        '${_directoryOf(binary)}:/w:ro',
        'debian:bookworm-slim',
        '/w/${_fileNameOf(binary)}',
        '--version',
      ], timeout: _smokeTimeout);
    }

    if (!result.ok) {
      return BuildOutcome.failed(
        'the binary would not run: ${result.summary}',
        transcript: result.transcript,
      );
    }
    if (!result.stdout.contains(expectedVersion)) {
      return BuildOutcome.failed(
        'it reports "${result.stdout.trim()}" rather than $expectedVersion',
        transcript: result.transcript,
      );
    }
    return null;
  }

  /// A smoke test has no interactive work. Bounding both native execution
  /// and the container wrapper prevents a broken runtime or credential helper
  /// from holding the entire private stage forever.
  static const _smokeTimeout = Duration(minutes: 2);

  static ({String os, String arch}) _target(String platform) {
    final parts = platform.split('-');
    return (os: parts.first, arch: parts.last);
  }

  static String _directoryOf(String path) {
    final cut = path.lastIndexOf('/');
    return cut < 0 ? '.' : path.substring(0, cut);
  }

  static String _fileNameOf(String path) {
    final cut = path.lastIndexOf('/');
    return cut < 0 ? path : path.substring(cut + 1);
  }
}

enum DartBuildEvent { testing }

class BuildOutcome {
  const BuildOutcome._(
    this.path,
    this.problem, {
    this.unproven,
    this.transcript,
  });

  const BuildOutcome.built(String path, {String? unproven})
    : this._(path, null, unproven: unproven);
  const BuildOutcome.failed(String problem, {String? transcript})
    : this._(null, problem, transcript: transcript);

  final String? path;
  final String? problem;

  /// The whole of what the tool said, carried to whoever reports this.
  ///
  /// [problem] is the line a person reads. This is the rest, and rk is its
  /// last holder: null only when no tool spoke.
  final String? transcript;

  /// Why the binary was never executed, when it was not. Null means it ran
  /// and reported the version it should — the only case rk calls proven.
  final String? unproven;

  bool get ok => path != null;
}
