import 'dart:io';

import '../engine/stage_plan.dart';
import '../engine/tools.dart';
import 'binary_artifact.dart';
import 'capability.dart';
import 'dart_launcher.dart';
import 'dart_native.dart';

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
    this.nativeBuildTool,
    this.nativeBuildImage,
  });

  final Tools tools;
  final HostCapabilities capabilities;

  /// The SDK's `dart`; beside it, the runtime a bundle ships.
  final String compilerExecutable;
  final String? nativeBuildTool;
  final String? nativeBuildImage;

  /// Compiles [entryPoint] for [platform], writing to [output].
  Future<BuildOutcome> build({
    required String platform,
    required String entryPoint,
    required String output,
    required String workingDirectory,
    String? repositoryRoot,
    required String expectedVersion,
    Map<String, String> defines = const {},
    void Function(DartBuildEvent event)? onProgress,
  }) async {
    // The caller refuses an unproducible platform with a diagnostic before
    // reaching here, so this asks only *how* to produce it.
    final capability = capabilities.resolve(platform);
    final sourceRoot = repositoryRoot ?? workingDirectory;
    final locked = dartBuildIsLocked(workingDirectory, sourceRoot);
    if (dartBuildFile(workingDirectory, sourceRoot, 'pubspec.yaml') != null) {
      final resolved = await tools.run(compilerExecutable, [
        'pub',
        'get',
        if (locked) '--enforce-lockfile',
      ], workingDirectory: workingDirectory);
      if (!resolved.ok) {
        return BuildOutcome.failed(
          resolved.summary,
          transcript: resolved.transcript,
        );
      }
    }
    if (hasDartBuildHooks(workingDirectory, sourceRoot)) {
      return _buildNative(
        platform: platform,
        entryPoint: entryPoint,
        output: output,
        directory: workingDirectory,
        repositoryRoot: sourceRoot,
        expectedVersion: expectedVersion,
        defines: defines,
        locked: locked,
        onProgress: onProgress,
      );
    }

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
    final compiled = await tools.run(
      compilerExecutable,
      arguments,
      workingDirectory: workingDirectory,
    );

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

    return _finish(platform, artifact, root, expectedVersion, onProgress);
  }

  Future<BuildOutcome> _finish(
    String platform,
    BinaryArtifact artifact,
    String root,
    String expectedVersion,
    void Function(DartBuildEvent)? onProgress, {
    String? image,
  }) async {
    final capability = capabilities.resolve(platform);
    final output = '$root/${artifact.entryPoint}';
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
        artifact: artifact,
      );
    }

    onProgress?.call(DartBuildEvent.testing);
    final smoke = await _smokeTest(
      platform: platform,
      binary: output,
      root: root,
      runtime: runtime,
      image: image,
      expectedVersion: expectedVersion,
    );
    if (smoke != null) return smoke;

    return BuildOutcome.built(output, artifact: artifact);
  }

  Future<BuildOutcome> _buildNative({
    required String platform,
    required String entryPoint,
    required String output,
    required String directory,
    required String repositoryRoot,
    required String expectedVersion,
    required Map<String, String> defines,
    required bool locked,
    void Function(DartBuildEvent)? onProgress,
  }) async {
    final scratch = Directory.systemTemp.createTempSync('rk-native-build-');
    try {
      final compiler = compilerExecutable == 'dart'
          ? DartSdk.ambient().executable
          : compilerExecutable;
      final image =
          (nativeBuildImage ?? Platform.environment['RK_DART_BUILD_IMAGE'])
              ?.replaceAll(
                '{arch}',
                platform.endsWith('-x64') ? 'amd64' : 'arm64',
              );
      final result = await buildDartNative(
        tools: tools,
        capabilities: capabilities,
        compiler: compiler,
        platform: platform,
        directory: directory,
        repositoryRoot: repositoryRoot,
        entryPoint: entryPoint,
        output: '${scratch.path}/build',
        defines: defines,
        locked: locked,
        helper: nativeBuildTool ?? Platform.environment['RK_DART_BUILD_TOOL'],
        image: image,
      );
      if (!result.ok) {
        return BuildOutcome.failed(
          result.summary,
          transcript: result.transcript,
        );
      }
      final macos = platform.startsWith('macos-');
      final bundle = '${scratch.path}/build/bundle';
      final sourceName = _fileNameOf(
        entryPoint,
      ).replaceFirst(RegExp(r'\.dart$'), '');
      final sourceEntry = 'bin/$sourceName${macos ? '.aot' : ''}';
      final libraries = dartNativeLibraries(bundle, sourceEntry);
      final artifact = BinaryArtifact.nativeBundle(
        _fileNameOf(output),
        macos: macos,
        libraries: libraries,
      );
      final root = _directoryOf(output);
      void copy(String from, String to) {
        final target = File('$root/$to')..parent.createSync(recursive: true);
        File('$bundle/$from').copySync(target.path);
      }

      copy(sourceEntry, macos ? artifact.module : artifact.entryPoint);
      for (final name in libraries) {
        copy(
          'lib/$name',
          macos ? 'lib/${artifact.command}/lib/$name' : 'lib/$name',
        );
      }
      if (macos) {
        final named = await tools.run('/usr/bin/install_name_tool', [
          '-id',
          '@rpath/app.aot',
          '$root/${artifact.module}',
        ]);
        if (!named.ok) {
          return BuildOutcome.failed(
            named.summary,
            transcript: named.transcript,
          );
        }
        final assembled = await _assembleBundle(artifact, root);
        if (assembled != null) return assembled;
      } else {
        File(
          '$root/${BinaryArtifact.manifestName}',
        ).writeAsStringSync(artifact.manifest);
      }
      return await _finish(
        platform,
        artifact,
        root,
        expectedVersion,
        onProgress,
        image: image,
      );
    } on FileSystemException catch (error) {
      return BuildOutcome.failed(
        'the native Dart bundle could not be assembled: $error',
      );
    } on FormatException catch (error) {
      return BuildOutcome.failed('$error');
    } on DartSdkUnavailable catch (error) {
      return BuildOutcome.failed('$error');
    } finally {
      if (scratch.existsSync()) scratch.deleteSync(recursive: true);
    }
  }

  Future<BuildOutcome?> _assembleBundle(
    BinaryArtifact artifact,
    String root,
  ) async {
    final compiler = compilerExecutable == 'dart'
        ? DartSdk.ambient().executable
        : File(compilerExecutable).absolute.path;
    // A copy keeps the runtime's executable mode; the archive records every
    // file's mode from the layout.
    File(
      '${File(compiler).parent.path}/dartaotruntime',
    ).copySync('$root/${artifact.identityFile}');
    File(
      '${File(compiler).parent.parent.path}/LICENSE',
    ).copySync('$root/lib/${artifact.entryPoint}/LICENSE.dart');
    if (artifact.layout == 'dart-aot-native') {
      final rpath = await tools.run('/usr/bin/install_name_tool', [
        '-add_rpath',
        '@executable_path/..',
        '$root/${artifact.identityFile}',
      ]);
      if (!rpath.ok) {
        return BuildOutcome.failed(rpath.summary, transcript: rpath.transcript);
      }
      final signed = await tools.run('/usr/bin/codesign', [
        '--force',
        '--sign',
        '-',
        '$root/${artifact.identityFile}',
      ]);
      if (!signed.ok) {
        return BuildOutcome.failed(
          signed.summary,
          transcript: signed.transcript,
        );
      }
    }
    final scratch = Directory.systemTemp.createTempSync('rk-dart-launcher-');
    final source = File('${scratch.path}/launcher.c');
    try {
      source.writeAsStringSync(
        dartLauncherSource(
          artifact.command,
          runtimePath: artifact.identityFile,
          modulePath: artifact.module,
        ),
      );
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
    required String root,
    required String? runtime,
    String? image,
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
        '$root:/w:ro',
        image ?? 'debian:bookworm-slim',
        '/w/${binary.substring(root.length + 1)}',
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
    this.artifact,
  });

  const BuildOutcome.built(
    String path, {
    String? unproven,
    BinaryArtifact? artifact,
  }) : this._(path, null, unproven: unproven, artifact: artifact);
  const BuildOutcome.failed(String problem, {String? transcript})
    : this._(null, problem, transcript: transcript);

  final String? path;
  final String? problem;
  final BinaryArtifact? artifact;

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
