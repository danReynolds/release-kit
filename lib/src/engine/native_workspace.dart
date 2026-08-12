import 'diagnostic.dart';
import 'pubspec.dart';
import 'source_tree.dart';

/// Adapter-owned native discovery facts for a source root.
///
/// Dart is the only adapter today. Keeping its manifest candidates and source
/// closure in one result prevents init and staging from growing separate
/// ecosystem-specific guesses. This remains an internal seam, not TOML.
final class NativeWorkspaceDiscovery {
  NativeWorkspaceDiscovery._({
    required Iterable<String> manifests,
    required Iterable<String> sourceRoots,
    required Iterable<String> notices,
    required Iterable<NativeProjectDiscovery> projects,
  })  : manifests = List.unmodifiable(manifests),
        sourceRoots = Set.unmodifiable(sourceRoots),
        notices = List.unmodifiable(notices),
        projects = List.unmodifiable(projects);

  factory NativeWorkspaceDiscovery.dart(
    SourceTree tree, {
    bool trackedManifests = false,
  }) {
    if (trackedManifests) {
      final manifests = tree
          .trackedFiles()
          .where((path) =>
              path == 'pubspec.yaml' || path.endsWith('/pubspec.yaml'))
          .toList()
        ..sort();
      return _dartResult(
        tree,
        manifests: manifests,
        sourceRoots: const [],
        missingDescription: 'tracked but not on disk',
      );
    }
    if (!tree.exists('pubspec.yaml')) {
      return NativeWorkspaceDiscovery._(
        manifests: const [],
        sourceRoots: const [],
        notices: const [],
        projects: const [],
      );
    }
    final manifests = <String>['pubspec.yaml'];
    final roots = <String>{'pubspec.yaml'};
    final notices = <String>[];
    final source = tree.read('pubspec.yaml');
    if (source == null) {
      return _dartResult(
        tree,
        manifests: manifests,
        sourceRoots: roots,
        missingDescription: 'discovered but missing',
      );
    }
    final diagnostics = Diagnostics();
    final root = Pubspec.parse(source, 'pubspec.yaml', diagnostics);
    if (root == null) {
      return _dartResult(
        tree,
        manifests: manifests,
        sourceRoots: roots,
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
      roots.add(member);
    }
    manifests.sort();
    return _dartResult(
      tree,
      manifests: manifests,
      sourceRoots: roots,
      notices: notices,
      missingDescription: 'discovered but missing',
    );
  }

  final List<String> manifests;
  final Set<String> sourceRoots;
  final List<String> notices;
  final List<NativeProjectDiscovery> projects;
}

/// Adapter-normalized static facts consumed by init policy.
///
/// This is deliberately internal and concrete. A second built-in ecosystem
/// can report the same facts without teaching the selector how to parse its
/// native manifest; adding its actual target remains an explicit product
/// change rather than a generic configuration/plugin surface.
final class NativeProjectDiscovery {
  const NativeProjectDiscovery({
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

NativeWorkspaceDiscovery _dartResult(
  SourceTree tree, {
  required Iterable<String> manifests,
  required Iterable<String> sourceRoots,
  Iterable<String> notices = const [],
  required String missingDescription,
}) {
  final allNotices = [...notices];
  final projects = <NativeProjectDiscovery>[];
  for (final path in manifests) {
    final source = tree.read(path);
    if (source == null) {
      allNotices.add('$path is $missingDescription');
      continue;
    }
    final diagnostics = Diagnostics();
    final pubspec = Pubspec.parse(source, path, diagnostics);
    if (pubspec == null) {
      allNotices.add('$path could not be parsed: '
          '${diagnostics.found.map((item) => item.message).join('; ')}');
      continue;
    }
    projects.add(NativeProjectDiscovery(
      name: pubspec.name,
      path: pubspec.directory,
      version: pubspec.version?.canonical,
      executables: List.unmodifiable(pubspec.executables),
      isGroupingRoot: pubspec.isWorkspaceRoot,
      vetoesRegistry: pubspec.vetoesRegistry,
      publishTo: pubspec.publishTo,
      isExampleOrFixture: _isExampleOrFixture(pubspec.directory),
    ));
  }
  return NativeWorkspaceDiscovery._(
    manifests: manifests,
    sourceRoots: sourceRoots,
    notices: allNotices,
    projects: projects,
  );
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
  final parts = member.split('/');
  if (member.isEmpty ||
      member.startsWith('/') ||
      member.startsWith('\\') ||
      member.contains('\\') ||
      RegExp(r'^[A-Za-z]:').hasMatch(member) ||
      parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
    return null;
  }
  return member;
}
