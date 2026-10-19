import 'dart:convert';
import 'dart:io';

import '../builds/capability.dart';
import '../builds/dart_native.dart';
import '../engine/assets.dart';
import '../engine/source_tree.dart';
import '../engine/stage.dart';
import '../engine/stage_plan.dart';
import '../engine/tools.dart';
import 'archive.dart';
import 'model.dart';
import 'provider.dart';
import 'store.dart';

class LocalInstallationProvider implements InstallationProvider {
  LocalInstallationProvider(
    this.tools,
    this.dartExecutable,
    this.store, {
    this.live = false,
    String? platform,
  }) : platform = platform ?? HostCapabilities.inspect().hostPlatform;
  final Tools tools;
  final String? dartExecutable;
  final InstallationStore store;
  final bool live;
  final String platform;
  @override
  InstallationSource get source => InstallationSource.local;

  Installation _installation(ExecutableProject project) => Installation(
    source: source,
    version: project.version,
    location: project.directory,
    commands: {
      for (final entry in project.entrypoints.entries)
        entry.key: _command(project, entry.key, entry.value),
    },
  );

  LaunchCommand _command(
    ExecutableProject project,
    String command,
    String name,
  ) {
    final entry = '${project.directory}/bin/$name.dart';
    final bootstrap = _localBootstrap(project, command, entry);
    return LaunchCommand(
      dartExecutable!,
      arguments: [
        '--suppress-analytics',
        'run',
        for (final define in project.project.dartDefines.entries)
          '-D${define.key}=${define.value}',
        bootstrap ?? entry,
      ],
      workingDirectory: bootstrap == null ? null : project.directory,
      requiredFiles: [
        '${project.directory}/pubspec.yaml',
        entry,
        if (bootstrap != null) bootstrap,
      ],
    );
  }

  /// Prefer the selected build; otherwise show the newest completed build.
  @override
  Future<SourceInspection> inspect(ExecutableProject project) async {
    final selected = store.selected(project);
    Installation? installation;
    final builds = Directory(store.localBuilds(project));
    if (selected?.source == source) {
      installation = Directory(selected!.location).parent.path == builds.path
          ? _readBuild(selected.location)
          : Installation(
              source: source,
              version: project.version,
              location: selected.location,
              commands: const {},
            );
    } else {
      installation = _builds(project).firstOrNull;
    }
    // A completed stage runs without Dart. Only a source build needs the SDK.
    return SourceInspection(installation: installation);
  }

  Iterable<Installation> _builds(ExecutableProject project) sync* {
    final directory = Directory(store.localBuilds(project));
    if (!directory.existsSync()) return;
    final entries = directory.listSync(followLinks: false)
      ..sort((a, b) => b.path.compareTo(a.path));
    for (final entry in entries.whereType<Directory>()) {
      if (_readBuild(entry.path) case final installation?) yield installation;
    }
  }

  Installation? _readBuild(String location) {
    final file = File('$location/build.json');
    if (!file.existsSync()) return null; // An interrupted build.
    final record = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    return Installation(
      source: source,
      version: record['version'] as String,
      checkout: record['checkout'] as String,
      build: record['build'] == null
          ? null
          : LocalBuildInfo.fromJson(record['build'] as Map<String, dynamic>),
      location: location,
      commands: {
        for (final entry in (record['executables'] as Map).entries)
          entry.key as String: LaunchCommand('$location/${entry.value}'),
      },
    );
  }

  @override
  Future<AvailableInstallation> latest(
    ExecutableProject project, {
    InstallationCancellation? check,
  }) async => throw const InstallationFailure(followsCheckout);

  @override
  Future<Installation> install(
    ExecutableProject project,
    AvailableInstallation? release,
    void Function(String) progress,
  ) async {
    if (!live) {
      final staged = await _installStaged(project, progress);
      if (staged != null) return staged;
    }
    if (dartExecutable == null || !File(dartExecutable!).existsSync()) {
      throw const InstallationFailure('Dart is required for the local source.');
    }
    progress('Preparing ${project.name} from this checkout…');
    await checked(tools, dartExecutable!, [
      '--suppress-analytics',
      'pub',
      'get',
    ], directory: project.directory);
    if (live) return _installation(project);
    final source = await _buildSource(project);

    // Build away from the selected executables. A failed rebuild must leave
    // every old command usable, including rk rebuilding itself.
    final parent = Directory(store.localBuilds(project))
      ..createSync(recursive: true);
    final build = parent.createTempSync(
      '${DateTime.now().microsecondsSinceEpoch}-',
    );
    var complete = false;
    try {
      final executables = {
        for (final entry in project.entrypoints.entries)
          entry.key: '${entry.value}/bundle/bin/${entry.value}',
      };
      final defines = project.project.dartDefines;
      final native = hasDartBuildHooks(project.directory, project.root);
      for (final name in project.entrypoints.values.toSet()) {
        final relative = '$name/bundle/bin/$name';
        if (native) {
          final capabilities = HostCapabilities.detect();
          final compiler = DartSdk.resolveExecutable(dartExecutable!);
          final helper = Platform.environment['RK_DART_BUILD_TOOL'];
          final result = await buildDartNative(
            tools: tools,
            capabilities: capabilities,
            compiler: compiler,
            platform: capabilities.hostPlatform,
            directory: project.directory,
            repositoryRoot: project.root,
            entryPoint: 'bin/$name.dart',
            output: '${build.path}/$name',
            defines: defines,
            locked: dartBuildIsLocked(project.directory, project.root),
            helper: helper,
            separateAot: false,
            onCompile: () => progress('Compiling $name from this checkout…'),
          );
          if (!result.ok) {
            throw localNativeBuildFailure(project, compiler, helper, result);
          }
        } else {
          progress('Compiling $name from this checkout…');
          // Pure Dart does not need the native-build helper for declarations.
          File('${build.path}/$relative').parent.createSync(recursive: true);
          await checked(tools, dartExecutable!, [
            '--suppress-analytics',
            'compile',
            'exe',
            for (final define in defines.entries)
              '-D${define.key}=${define.value}',
            'bin/$name.dart',
            '-o',
            '${build.path}/$relative',
          ], directory: project.directory);
        }
      }
      final installation = _completeBuild(
        project,
        build,
        executables,
        LocalBuildInfo(
          builtAt: DateTime.now().toUtc(),
          commit: source.commit,
          dirty: source.dirty,
        ),
      );
      complete = true;
      return installation;
    } finally {
      if (!complete) build.deleteSync(recursive: true);
    }
  }

  /// A release already prepared from this clean checkout is also a Local
  /// build. Read only its receipt and host archive, without release preflight,
  /// credentials, dependency resolution or another build.
  Future<Installation?> _installStaged(
    ExecutableProject project,
    void Function(String) progress,
  ) async {
    if (!project.project.binaryPlatforms.contains(platform)) return null;
    final builds = _builds(project).toList();
    final stages = Stages(project.root);
    if (!Directory(stages.path).existsSync() &&
        !builds.any((b) => b.build?.stage != null)) {
      return null;
    }
    final source = await _buildSource(project);
    if (source.commit == null || source.dirty != false) return null;
    final tree = await tools.run(
      'git',
      ['rev-parse', '${source.commit}^{tree}'],
      workingDirectory: project.root,
      timeout: const Duration(seconds: 5),
    );
    if (!tree.ok) return null;
    final plan = stagePlanFor(project.unit, project.repository);
    final stage = Stage(
      root: project.root,
      id: StageId.of(
        commit: source.commit!,
        tree: tree.stdout.trim(),
        plan: plan,
      ),
      plan: plan,
      source: WorkingTree(project.root, git: false),
    );
    final receipt = stage.completedReceipt();
    final path = ReleaseAssets.archivePath(project.project, platform);
    final recorded = receipt?.files[path];
    // The installed copy is independent of stage cleanup. A newly prepared
    // archive at the same commit still replaces it when its digest differs.
    for (final installed in builds) {
      if (installed.build?.stage == stage.id.id &&
          installed.build!.archiveSha256 != null &&
          (recorded == null ||
              installed.build!.archiveSha256 == recorded.sha256) &&
          installed.commands.values.every(
            (c) => File(c.executable).existsSync(),
          )) {
        progress('Reusing ${project.name} from its staged release…');
        return installed;
      }
    }
    if (recorded == null) return null;
    final archive = File(stage.pathOf(path));
    if (!archive.existsSync()) return null;
    progress('Installing ${project.name} from its staged release…');
    final decoded = await decodeInstallationArchive(
      await archive.readAsBytes(),
      project.commands.single,
      size: recorded.size,
      sha256: recorded.sha256,
    );
    final parent = Directory(store.localBuilds(project))
      ..createSync(recursive: true);
    final build = parent.createTempSync(
      '${DateTime.now().microsecondsSinceEpoch}-',
    );
    var complete = false;
    try {
      final artifact = await installArchive(
        archive: decoded,
        version: project.version,
        directory: Directory('${build.path}/bundle'),
        tools: tools,
      );
      final installation = _completeBuild(
        project,
        build,
        {project.commands.single: 'bundle/${artifact.entryPoint}'},
        LocalBuildInfo(
          builtAt: DateTime.now().toUtc(),
          commit: source.commit,
          dirty: false,
          stage: stage.id.id,
          archiveSha256: recorded.sha256,
        ),
      );
      complete = true;
      return installation;
    } finally {
      if (!complete) build.deleteSync(recursive: true);
    }
  }

  Installation _completeBuild(
    ExecutableProject project,
    Directory directory,
    Map<String, String> executables,
    LocalBuildInfo info,
  ) {
    final record = File('${directory.path}/.build.json');
    record.writeAsStringSync(
      jsonEncode({
        'version': project.version,
        'checkout': project.directory,
        'build': info.toJson(),
        'executables': executables,
      }),
    );
    record.renameSync('${directory.path}/build.json');
    return _readBuild(directory.path)!;
  }

  /// One optional Git read before compilation. Missing Git, a non-repository,
  /// or an unreadable checkout must not prevent a development build.
  Future<({String? commit, bool? dirty})> _buildSource(
    ExecutableProject project,
  ) async {
    try {
      final result = await tools.run(
        'git',
        ['status', '--porcelain=v2', '--branch', '--untracked-files=normal'],
        workingDirectory: project.root,
        timeout: const Duration(seconds: 5),
      );
      if (result.ok) {
        final lines = const LineSplitter().convert(result.stdout);
        final oid = lines
            .where((line) => line.startsWith('# branch.oid '))
            .firstOrNull;
        final commit = oid?.substring('# branch.oid '.length);
        return (
          commit: commit == '(initial)' ? null : commit,
          dirty: lines.any((line) => !line.startsWith('#')),
        );
      }
    } on ProcessException {
      // Git is not required to compile a local checkout.
    }
    return (commit: null, dirty: null);
  }

  /// Only compiled copies are rk's to remove; a checkout is never deleted.
  @override
  Future<void> uninstall(ExecutableProject project) async {
    final builds = Directory(store.localBuilds(project));
    if (builds.existsSync()) builds.deleteSync(recursive: true);
  }
}

/// Why Local has no newer version to check or install.
const followsCheckout =
    'Local follows this checkout; it has no remote version to update.';

/// Dart 3.10–3.12 discovers hooks from the invoking directory. Prepare assets
/// there, then run the original script in its own isolate with the caller cwd.
/// The child keeps Platform.script, argument handling and ordinary stdio.
String? _localBootstrap(
  ExecutableProject project,
  String command,
  String entry,
) {
  var directory = Directory(project.directory);
  File? config;
  while (true) {
    final candidate = File('${directory.path}/.dart_tool/package_config.json');
    if (candidate.existsSync()) {
      config = candidate;
      break;
    }
    if (directory.path == project.root ||
        directory.parent.path == directory.path) {
      return null;
    }
    directory = directory.parent;
  }
  final json = jsonDecode(config.readAsStringSync()) as Map<String, dynamic>;
  final packages = (json['packages'] as List).cast<Map<String, dynamic>>();
  final hasHooks = packages.any((package) {
    final root = Directory.fromUri(
      config!.uri.resolve(package['rootUri'] as String),
    ).uri;
    return File.fromUri(root.resolve('hook/build.dart')).existsSync();
  });
  if (!hasHooks) return null;
  final path = '${project.directory}/.dart_tool/rk-local/$command.dart';
  final script = File(path)..parent.createSync(recursive: true);
  String literal(String value) => jsonEncode(value).replaceAll(r'$', r'\$');
  script.writeAsStringSync('''
// Generated by rk use local. The application's original entrypoint is retained.
import 'dart:io';
import 'dart:isolate';
Future<void> main(List<String> args) async {
  Directory.current = args.first;
  final events = ReceivePort();
  try {
    await Isolate.spawnUri(
      Uri.parse(${literal(File(entry).uri.toString())}),
      args.sublist(1), null,
      packageConfig: Uri.parse(${literal(config.uri.toString())}),
      onExit: events.sendPort, onError: events.sendPort, errorsAreFatal: true,
    );
    await for (final event in events) {
      if (event == null) break;
      stderr.writeln((event as List).join('\\n'));
      exitCode = 255;
    }
  } finally {
    events.close();
  }
}
''');
  return path;
}

/// What a failed native build of [project] tells the person switching to
/// it. A helper that is not ready says so once, with the command that
/// retries this switch; any other failure keeps the tool's whole output.
InstallationFailure localNativeBuildFailure(
  ExecutableProject project,
  String compiler,
  String? helper,
  ToolResult result,
) {
  final context = [
    'Directory: ${project.directory}',
    'Dart compiler: $compiler',
    'Native build helper: ${helper ?? 'automatic (rk-dart-build if required)'}',
  ];
  if (result is NativeHelperUnready) {
    return InstallationFailure.withEvidence(
      result.message,
      remedy:
          '${result.remedy}\n'
          'For one command: env PATH="/path/to/dart-sdk/bin:'
          '/path/to/rk-dart-build-3.13.5-1-macos-arm64:\$PATH" '
          'rk use local -p ${project.name}',
      evidence: [...context, result.detail].join('\n'),
    );
  }
  return InstallationFailure.withEvidence(
    result.summary,
    remedy: 'Fix the reported build error, then retry the same command.',
    evidence: [...context, result.transcript].join('\n'),
  );
}
