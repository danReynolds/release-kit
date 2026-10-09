import 'diagnostic.dart';
import 'pubspec.dart';
import 'source_tree.dart';

/// The Dart packages `rk init` can propose: the root manifest and its
/// workspace members, or every tracked manifest.
final class DartWorkspaceDiscovery {
  DartWorkspaceDiscovery._({
    required Iterable<String> notices,
    required Iterable<DartProjectDiscovery> projects,
  }) : notices = List.unmodifiable(notices),
       projects = List.unmodifiable(projects);

  factory DartWorkspaceDiscovery(
    SourceTree tree, {
    bool trackedManifests = false,
  }) {
    if (trackedManifests) {
      final manifests =
          tree
              .trackedFiles()
              .where(
                (path) =>
                    path == 'pubspec.yaml' || path.endsWith('/pubspec.yaml'),
              )
              .toList()
            ..sort();
      return _dartResult(
        tree,
        manifests: manifests,
        missingDescription: 'tracked but not on disk',
      );
    }
    if (!tree.exists('pubspec.yaml')) {
      return DartWorkspaceDiscovery._(notices: const [], projects: const []);
    }
    final manifests = <String>['pubspec.yaml'];
    final notices = <String>[];
    final source = tree.read('pubspec.yaml');
    if (source == null) {
      return _dartResult(
        tree,
        manifests: manifests,
        missingDescription: 'discovered but missing',
      );
    }
    final diagnostics = Diagnostics();
    final root = Pubspec.parse(source, 'pubspec.yaml', diagnostics);
    if (root == null) {
      return _dartResult(
        tree,
        manifests: manifests,
        missingDescription: 'discovered but missing',
      );
    }
    for (final raw in root.workspace) {
      final member = _safeMember(raw);
      if (member == null) {
        notices.add('workspace member "$raw" is not a safe relative path');
        continue;
      }
      final manifest = '$member/pubspec.yaml';
      if (!tree.exists(manifest)) {
        notices.add('$manifest is declared by the workspace but is missing');
        continue;
      }
      manifests.add(manifest);
    }
    manifests.sort();
    return _dartResult(
      tree,
      manifests: manifests,
      notices: notices,
      missingDescription: 'discovered but missing',
    );
  }

  final List<String> notices;
  final List<DartProjectDiscovery> projects;
}

/// Pubspec facts consumed by init policy.
final class DartProjectDiscovery {
  const DartProjectDiscovery({
    required this.name,
    required this.path,
    required this.version,
    required this.executables,
    required this.isGroupingRoot,
    required this.vetoesRegistry,
    required this.publishTo,
    required this.isExampleOrFixture,
  });

  final String name;
  final String path;
  final String? version;
  final List<String> executables;
  final bool isGroupingRoot;
  final bool vetoesRegistry;
  final String? publishTo;
  final bool isExampleOrFixture;
}

DartWorkspaceDiscovery _dartResult(
  SourceTree tree, {
  required Iterable<String> manifests,
  Iterable<String> notices = const [],
  required String missingDescription,
}) {
  final allNotices = [...notices];
  final projects = <DartProjectDiscovery>[];
  for (final path in manifests) {
    final source = tree.read(path);
    if (source == null) {
      allNotices.add('$path is $missingDescription');
      continue;
    }
    final diagnostics = Diagnostics();
    final pubspec = Pubspec.parse(source, path, diagnostics);
    if (pubspec == null) {
      allNotices.add(
        '$path could not be parsed: '
        '${diagnostics.found.map((item) => item.message).join('; ')}',
      );
      continue;
    }
    projects.add(
      DartProjectDiscovery(
        name: pubspec.name,
        path: pubspec.directory,
        version: pubspec.version?.canonical,
        executables: List.unmodifiable(pubspec.executables),
        isGroupingRoot: pubspec.isWorkspaceRoot,
        vetoesRegistry: pubspec.vetoesRegistry,
        publishTo: pubspec.publishTo,
        isExampleOrFixture: _isExampleOrFixture(pubspec.directory),
      ),
    );
  }
  return DartWorkspaceDiscovery._(notices: allNotices, projects: projects);
}

bool _isExampleOrFixture(String directory) {
  if (directory == '.') return false;
  const conventional = {
    'example',
    'examples',
    'fixture',
    'fixtures',
    'peer-fixtures',
    'test',
    'tests',
  };
  return directory
      .split('/')
      .map((part) => part.toLowerCase())
      .any(conventional.contains);
}

String? _safeMember(String raw) {
  final member = raw.trim().replaceFirst(RegExp(r'/+$'), '');
  return relativeSegments(member) == null ? null : member;
}
