import 'config.dart';
import 'diagnostic.dart';
import 'pubspec.dart';
import 'source_tree.dart';
import 'version.dart';

/// Release intent resolved against the repository: what the author asked for,
/// joined to what the manifests say.
class Resolution {
  Resolution({
    required this.units,
    required this.identity,
    required this.tree,
  });

  final List<ResolvedUnit> units;
  final IdentityConfig? identity;
  final SourceTree tree;

  ResolvedUnit? unit(String name) {
    for (final unit in units) {
      if (unit.name == name) return unit;
    }
    return null;
  }

  /// Every project across every unit — the repository's first-party identity
  /// map, which is what lets a sibling dependency be recognised as one.
  List<ResolvedProject> get allProjects =>
      units.expand((u) => u.projects).toList();

  /// Resolves [config] against [tree], reading each project's manifest.
  static Resolution? resolve(
    ReleaseConfig config,
    SourceTree tree,
    Diagnostics diagnostics,
  ) {
    final projects = <ResolvedProject>[];
    final byUnit = <String, List<ResolvedProject>>{};

    for (final unit in config.units) {
      final list = <ResolvedProject>[];
      for (final declared in unit.projects) {
        final project = _project(unit, declared, tree, diagnostics);
        if (project != null) {
          list.add(project);
          projects.add(project);
        }
      }
      byUnit[unit.name] = list;
    }

    _rejectOverlappingPaths(projects, diagnostics);
    _rejectDuplicateNames(projects, diagnostics);

    // The convention is pub.dev's, and counts the packages the repository
    // publishes *there* — a project that never touches the registry neither
    // affects the count nor takes its naming from it.
    final registryProjects =
        projects.where((p) => p.channels.contains('pub.dev')).length;
    final publishesSeveral = registryProjects > 1;

    final units = <ResolvedUnit>[];
    for (final declared in config.units) {
      final resolved = byUnit[declared.name] ?? const [];
      if (resolved.length != declared.projects.length) continue;
      units.add(
        ResolvedUnit(
          name: declared.name,
          tagPattern: declared.tagPattern ??
              _derivedTagPattern(resolved.single, publishesSeveral),
          tagWasDeclared: declared.tagPattern != null,
          projects: resolved,
          location: declared.location,
        ),
      );
    }

    for (final unit in units) {
      _checkUnitVersions(unit, diagnostics);
      _checkOneBinaryProject(unit, diagnostics);
    }

    if (diagnostics.isNotEmpty) return null;
    return Resolution(
      units: units,
      identity: config.identity,
      tree: tree,
    );
  }

  /// pub.dev documents `v{version}` for a repository publishing one package,
  /// and a per-package prefix where it publishes several.
  static String _derivedTagPattern(
    ResolvedProject project,
    bool publishesSeveral,
  ) =>
      publishesSeveral ? '${project.pubspec.name}-v{version}' : 'v{version}';

  static ResolvedProject? _project(
    UnitConfig unit,
    ProjectConfig declared,
    SourceTree tree,
    Diagnostics diagnostics,
  ) {
    final manifestPath =
        declared.path == '.' ? 'pubspec.yaml' : '${declared.path}/pubspec.yaml';

    final source = tree.read(manifestPath);
    if (source == null) {
      diagnostics.add(
        'RK-RES-001',
        'no package at "${declared.path}"',
        source: declared.location,
        remedy: tree.exists(declared.path)
            ? 'that directory has no pubspec.yaml'
            : 'that directory does not exist in the repository',
      );
      return null;
    }

    final pubspec = Pubspec.parse(source, manifestPath, diagnostics);
    if (pubspec == null) return null;

    if (pubspec.version == null) {
      diagnostics.add(
        'RK-RES-002',
        '"${pubspec.name}" declares no version, so there is nothing to release',
        source: SourceLocation(manifestPath, pubspec.nameLine),
        remedy: pubspec.isWorkspaceRoot
            ? 'this is a workspace root, not a package — release its members '
                'instead'
            : 'add a version to the manifest',
      );
      return null;
    }

    if (pubspec.vetoesRegistry && declared.channels.contains('pub.dev')) {
      diagnostics.add(
        'RK-RES-003',
        '"${pubspec.name}" sets publish_to: none but is asked to publish to '
            'pub.dev',
        source: declared.location,
        remedy: 'the manifest\'s veto wins — drop "pub.dev" from publish, or '
            'remove publish_to from the manifest',
      );
      return null;
    }

    if (declared.wantsBinaries && pubspec.executables.isEmpty) {
      diagnostics.add(
        'RK-RES-004',
        '"${pubspec.name}" ships binaries but declares no executable',
        source: declared.location,
        remedy: 'add an executables: entry to the manifest, or drop the '
            'binary channels',
      );
      return null;
    }

    final escaping = <String>[];
    pubspec.dependencies.forEach((name, dependency) {
      if (dependency.escapesRepository) {
        escaping.add('$name -> ${dependency.describeRequirement()}');
      }
    });
    if (escaping.isNotEmpty) {
      diagnostics.add(
        'RK-DART-201',
        '"${pubspec.name}" is built from sources this repository does not '
            'contain',
        source: SourceLocation(manifestPath, pubspec.nameLine),
        remedy: 'these dependencies come from outside its own history, so a '
            'release built today and one built next month are different '
            'programs and nobody can tell which one a published artifact came '
            'from:\n  ${escaping.join('\n  ')}\n'
            'publish them, or pin them to a commit.',
      );
      return null;
    }

    if (declared.wantsBinaries && pubspec.executables.length > 1) {
      diagnostics.add(
        'RK-RES-005',
        '"${pubspec.name}" declares ${pubspec.executables.length} executables, '
            'so rk cannot tell which one to ship',
        source: SourceLocation(manifestPath, pubspec.nameLine),
        remedy: 'binary channels support one executable per project: '
            '${pubspec.executables.join(', ')}',
      );
      return null;
    }

    return ResolvedProject(
      unitName: unit.name,
      config: declared,
      pubspec: pubspec,
    );
  }

  static void _rejectOverlappingPaths(
    List<ResolvedProject> projects,
    Diagnostics diagnostics,
  ) {
    for (var i = 0; i < projects.length; i++) {
      for (var j = i + 1; j < projects.length; j++) {
        final a = projects[i].config.path;
        final b = projects[j].config.path;
        final nested = a == b || a.startsWith('$b/') || b.startsWith('$a/');
        if (!nested) continue;
        diagnostics.add(
          'RK-RES-006',
          a == b
              ? '"$a" is declared twice'
              : 'the projects "$a" and "$b" contain one another',
          source: projects[j].config.location,
          remedy: 'each project is its own directory, declared once',
        );
      }
    }
  }

  static void _rejectDuplicateNames(
    List<ResolvedProject> projects,
    Diagnostics diagnostics,
  ) {
    final seen = <String, ResolvedProject>{};
    for (final project in projects) {
      final name = project.pubspec.name;
      final first = seen[name];
      if (first == null) {
        seen[name] = project;
        continue;
      }
      diagnostics.add(
        'RK-RES-007',
        'the package "$name" is declared by two projects',
        source: project.config.location,
        remedy: 'both "${first.config.path}" and "${project.config.path}" '
            'resolve to the same package',
      );
    }
  }

  /// One project per unit may ship binaries.
  ///
  /// Several would share a release, a checksums file, and a formula, with no
  /// way to tell whose asset is whose — and their steps would collide. A
  /// second binary product belongs in a unit of its own.
  static void _checkOneBinaryProject(
    ResolvedUnit unit,
    Diagnostics diagnostics,
  ) {
    final shipping =
        unit.projects.where((p) => p.config.wantsBinaries).toList();
    if (shipping.length < 2) return;
    diagnostics.add(
      'RK-RES-009',
      '${shipping.length} projects in "${unit.name}" ship binaries',
      source: unit.location,
      remedy: 'they would share one release and one set of asset names: '
          '${shipping.map((p) => p.name).join(', ')}. Give each its own unit.',
    );
  }

  /// Projects in one unit normally move together. They are not required to be
  /// identical — after a partial publish they cannot be — but a divergence at
  /// rest is far more likely a mistake than an intent, so it is surfaced.
  static void _checkUnitVersions(ResolvedUnit unit, Diagnostics diagnostics) {
    if (unit.projects.length < 2) return;
    final versions = unit.projects.map((p) => p.version.canonical).toSet();
    if (versions.length == 1) return;
    diagnostics.add(
      'RK-RES-008',
      'the projects in "${unit.name}" are at different versions: '
          '${versions.join(', ')}',
      source: unit.location,
      remedy: 'a unit releases its projects together — align the manifests, '
          'or split them into units of their own',
    );
  }
}

class ResolvedUnit {
  ResolvedUnit({
    required this.name,
    required this.tagPattern,
    required this.tagWasDeclared,
    required this.projects,
    required this.location,
  });

  final String name;

  /// Declared, or derived from the publication target's convention.
  final String tagPattern;
  final bool tagWasDeclared;

  final List<ResolvedProject> projects;
  final SourceLocation location;

  /// The version this unit releases at: its projects', which agree.
  Version get version => projects.first.version;

  String get tag => tagPattern.replaceAll('{version}', version.canonical);

  String tagFor(Version version) =>
      tagPattern.replaceAll('{version}', version.canonical);

  bool get shipsBinaries => projects.any((p) => p.config.wantsBinaries);
}

class ResolvedProject {
  ResolvedProject({
    required this.unitName,
    required this.config,
    required this.pubspec,
  });

  final String unitName;
  final ProjectConfig config;
  final Pubspec pubspec;

  String get name => pubspec.name;
  Version get version => pubspec.version!;
  Set<String> get channels => config.channels;
  List<String> get binaryPlatforms => config.binaryPlatforms;

  /// The single executable a binary channel ships, when there is one.
  String? get executable =>
      pubspec.executables.isEmpty ? null : pubspec.executables.first;
}
