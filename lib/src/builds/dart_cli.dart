import '../engine/tools.dart';
import 'capability.dart';

/// Builds a Dart executable for one platform, and runs what it produced.
///
/// A binary rk cannot execute is a binary rk will not ship, so the smoke test
/// is part of building rather than a later step someone could skip.
class DartCliBuilder {
  DartCliBuilder({
    required this.tools,
    required this.capabilities,
  });

  final Tools tools;
  final HostCapabilities capabilities;

  /// Compiles [entryPoint] for [platform], writing to [output].
  Future<BuildOutcome> build({
    required String platform,
    required String entryPoint,
    required String output,
    required String workingDirectory,
    required String expectedVersion,
  }) async {
    final capability = capabilities.resolve(platform);
    if (!capability.canProduce) {
      return BuildOutcome.blocked(capability.reason ?? 'not possible here');
    }

    final target = _target(platform);
    final compiled = await tools.run(
      'dart',
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

class BuildOutcome {
  const BuildOutcome._(this.path, this.problem, this.wasBlocked);

  const BuildOutcome.built(String path) : this._(path, null, false);
  const BuildOutcome.failed(String problem) : this._(null, problem, false);
  const BuildOutcome.blocked(String problem) : this._(null, problem, true);

  final String? path;
  final String? problem;

  /// Whether this host simply cannot produce it, as opposed to trying and
  /// failing.
  final bool wasBlocked;

  bool get ok => path != null;
}
