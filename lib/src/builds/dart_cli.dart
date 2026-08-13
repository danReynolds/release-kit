import '../engine/tools.dart';
import 'capability.dart';

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
  final String compilerExecutable;

  /// Compiles [entryPoint] for [platform], writing to [output].
  Future<BuildOutcome> build({
    required String platform,
    required String entryPoint,
    required String output,
    required String workingDirectory,
    required String expectedVersion,
    void Function(DartBuildEvent event)? onProgress,
  }) async {
    // The caller refuses an unproducible platform with a diagnostic before
    // reaching here, so this asks only *how* to produce it.
    final capability = capabilities.resolve(platform);

    final target = _target(platform);
    final compiled = await tools.run(
      compilerExecutable,
      [
        'compile',
        'exe',
        if (capability.capability == Capability.crossCompiled) ...[
          '--target-os=${target.os}',
          '--target-arch=${target.arch}',
        ],
        entryPoint,
        '-o',
        output,
      ],
      workingDirectory: workingDirectory,
    );

    if (!compiled.ok) return BuildOutcome.failed(compiled.summary);

    if (!capability.canProve) {
      // Built, and nothing here can run it. The absence of the proof is
      // carried forward rather than swallowed or treated as a failure.
      return BuildOutcome.built(
        output,
        unproven: capability.reason ?? 'nothing here can run it',
      );
    }

    onProgress?.call(DartBuildEvent.testing);
    final smoke = await _smokeTest(
      platform: platform,
      binary: output,
      capability: capability,
      expectedVersion: expectedVersion,
    );
    if (smoke != null) return BuildOutcome.failed(smoke);

    return BuildOutcome.built(output);
  }

  /// Runs the binary and checks it reports the version being released.
  ///
  /// The strongest cheap signal that the right thing was built: a binary that
  /// prints the wrong version is one nobody should ship, and it is exactly
  /// what a stale artifact looks like.
  Future<String?> _smokeTest({
    required String platform,
    required String binary,
    required PlatformCapability capability,
    required String expectedVersion,
  }) async {
    final ToolResult result;
    if (capability.capability == Capability.native) {
      result = await tools.run(binary, const ['--version']);
    } else {
      final target = _target(platform);
      final runtime = capabilities.containerRuntime;
      if (runtime == null) {
        // Unreachable through the capability gate, and stated rather than
        // assumed: the alternative is a null-check crash at the one step
        // whose whole job is to prove the binary runs.
        return 'no container runtime is available to run it';
      }
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
      ]);
    }

    if (!result.ok) return 'the binary would not run: ${result.summary}';
    if (!result.stdout.contains(expectedVersion)) {
      return 'it reports "${result.stdout.trim()}" rather than '
          '$expectedVersion';
    }
    return null;
  }

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
  const BuildOutcome._(this.path, this.problem, {this.unproven});

  const BuildOutcome.built(String path, {String? unproven})
      : this._(path, null, unproven: unproven);
  const BuildOutcome.failed(String problem) : this._(null, problem);

  final String? path;
  final String? problem;

  /// Why the binary was never executed, when it was not. Null means it ran
  /// and reported the version it should — the only case rk calls proven.
  final String? unproven;

  bool get ok => path != null;
}
