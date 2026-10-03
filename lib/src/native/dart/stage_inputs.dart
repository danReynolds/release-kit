import 'dart:convert';
import 'dart:io';

import '../../engine/canonical_json.dart';
import '../../engine/git.dart';
import '../../engine/resolve.dart';
import '../../engine/source_tree.dart';
import '../../engine/stage.dart';
import '../../engine/tools.dart';
import 'hosted_discovery.dart';
import 'dependency_lock.dart';
import 'package_archive.dart';

enum DartStageOperation { pubArchive, binary }

/// Operation inputs read from the selected source, rather than deserialized
/// solver evidence. Reuse this reader before discovery, restore and replay.
final class DartStageInputs {
  DartStageInputs._(this.root, this.lock, this._source, this._projectPath);

  static SourceTree authoritativeSource(SourceTree source, GitState git) {
    if (git.isBound) {
      if (source is GitCommitSourceTree && source.commit != git.head) {
        throw StateError('native source commit differs from release source');
      }
      return GitCommitSourceTree(git.root, git.head);
    }
    if (source is GitCommitSourceTree) {
      throw StateError('native committed source requires a bound Git identity');
    }
    return source is FrozenSourceTree
        ? source
        : FrozenSourceTree.capture(source);
  }

  factory DartStageInputs.read({
    required SourceTree source,
    required ResolvedProject project,
    required DartStageOperation operation,
  }) {
    final rootText = source.read(project.pubspec.path);
    if (rootText == null) {
      throw StateError('native root is absent from the selected source');
    }
    final root = DartPackageManifest.parse(rootText);
    if (root.name != project.name ||
        root.version != project.version.canonical) {
      throw StateError(
        'native source root differs from the configured project',
      );
    }
    final prefix = project.pubspec.path.substring(
      0,
      project.pubspec.path.length - 'pubspec.yaml'.length,
    );
    if (source.exists('${prefix}pubspec_overrides.yaml') ||
        root.fields.containsKey('dependency_overrides')) {
      throw StateError('native source has unauthorized dependency overrides');
    }
    DartDependencyLock? lock;
    if (operation == DartStageOperation.binary) {
      final path = _effectiveLock(source, root, prefix);
      final text = source.read(path);
      if (text != null) lock = DartDependencyLock.parse(text, path: path);
    }
    return DartStageInputs._(root, lock, source, prefix);
  }

  final DartPackageManifest root;
  final DartDependencyLock? lock;
  final SourceTree _source;
  final String _projectPath;

  /// Pub owns original nested/glob membership and SDK gates. This command
  /// reads manifests; it does not solve or acquire package archives.
  Future<void> verifyWorkspace({
    required Tools tools,
    required String compiler,
  }) async {
    if (!root.fields.containsKey('resolution') &&
        !root.fields.containsKey('workspace')) {
      return;
    }
    final mirror = Directory.systemTemp.createTempSync('rk-dart-workspace-');
    try {
      var count = 0;
      var bytes = 0;
      for (final path in _source.trackedFiles()) {
        if (path != 'pubspec.yaml' &&
            !path.endsWith('/pubspec.yaml') &&
            path != 'pubspec_overrides.yaml' &&
            !path.endsWith('/pubspec_overrides.yaml')) {
          continue;
        }
        final parts = StagePath.segments(path);
        final contents = _source.readBytes(path);
        if (contents == null ||
            ++count > 2048 ||
            contents.length > 1024 * 1024 ||
            (bytes += contents.length) > 128 * 1024 * 1024) {
          throw StateError(
            'native workspace manifest snapshot is missing or exceeds its limit',
          );
        }
        final file = File([mirror.path, ...parts].join(Platform.pathSeparator));
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(contents);
      }
      final selected = Directory(
        '${mirror.path}/$_projectPath',
      ).resolveSymbolicLinksSync();
      final result = await tools.run(
        compiler,
        const ['--suppress-analytics', 'pub', 'workspace', 'list', '--json'],
        workingDirectory: selected,
        environment: {
          'PUB_CACHE': '${mirror.path}/cache',
          'PUB_ENVIRONMENT': 'rk-workspace-authorization',
        },
        timeout: const Duration(minutes: 2),
      );
      if (!result.ok) {
        throw StateError(
          'native workspace source is invalid:\n${result.transcript}',
        );
      }
      final document = jsonDecode(result.stdout);
      if (document is! Map || document['packages'] is! List) {
        throw StateError('native workspace did not return package membership');
      }
      final paths = <String>{};
      var found = false;
      final boundary =
          '${mirror.resolveSymbolicLinksSync()}${Platform.pathSeparator}';
      for (final package in document['packages'] as List) {
        if (package is! Map ||
            package['name'] is! String ||
            package['path'] is! String ||
            !paths.add(package['path'] as String)) {
          throw StateError('native workspace returned invalid membership');
        }
        final path = package['path'] as String;
        if (path != boundary.substring(0, boundary.length - 1) &&
            !path.startsWith(boundary)) {
          throw StateError('native workspace escapes the selected source');
        }
        if (path == selected && package['name'] == root.name) found = true;
      }
      if (!found) {
        throw StateError('native root is not a member of its source workspace');
      }
    } finally {
      mirror.deleteSync(recursive: true);
    }
  }

  Future<DartDiscoveryResult> discover({
    required DartHostedDiscovery discovery,
    Iterable<DartDiscoveryCandidate> candidates = const [],
  }) async {
    await verifyWorkspace(tools: discovery.tools, compiler: discovery.compiler);
    return discovery.resolve(root: root, lock: lock, candidates: candidates);
  }

  void requireMatches(
    DartPackageManifest recordedRoot,
    DartLockBinding? recordedLock,
  ) {
    root.requireSameManifest(recordedRoot);
    if (CanonicalJson.encode(lock?.binding.toJson()) !=
        CanonicalJson.encode(recordedLock?.toJson())) {
      throw StateError(
        'native effective lockfile differs from the bound source',
      );
    }
  }
}

String _effectiveLock(
  SourceTree source,
  DartPackageManifest root,
  String prefix,
) {
  if (root.fields['resolution'] != 'workspace') return '${prefix}pubspec.lock';
  // Nested workspace members keep walking until the independent workspace
  // root. Their own stale lockfiles never override the workspace lock.
  var parts = prefix.split('/').where((part) => part.isNotEmpty).toList();
  while (parts.isNotEmpty) {
    parts = parts.sublist(0, parts.length - 1);
    final parent = parts.isEmpty ? '' : '${parts.join('/')}/';
    final text = source.read('${parent}pubspec.yaml');
    if (text == null) continue;
    final manifest = readDartYamlDocument(text);
    if (source.exists('${parent}pubspec_overrides.yaml') ||
        manifest.containsKey('dependency_overrides')) {
      throw StateError(
        'native workspace has unauthorized dependency overrides',
      );
    }
    if (manifest['resolution'] == 'workspace') continue;
    if (manifest['workspace'] is! List) {
      throw StateError(
        'native workspace member has no selected workspace root',
      );
    }
    return '${parent}pubspec.lock';
  }
  throw StateError('native workspace member has no selected workspace root');
}
