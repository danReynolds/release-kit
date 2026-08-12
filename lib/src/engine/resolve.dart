import 'release_asset.dart';
import 'config.dart';
import 'diagnostic.dart';
import 'publish_target.dart';
import 'pubspec.dart';
import 'source_tree.dart';
import 'version.dart';

/// Release intent resolved against the repository: what the author asked for,
/// joined to what the manifests say.
class Resolution {
  Resolution({required this.units, required this.tree});

  final List<ResolvedUnit> units;
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

    final taggedUnits = config.units
        .where((unit) => unit.publish.contains(PublishTarget.gitTag))
        .toList();
    final tagUnits = taggedUnits.length;
    if (tagUnits > 1) {
      final implicit = taggedUnits.where((unit) => unit.tagPattern == null);
      for (final unit in implicit) {
        diagnostics.add(
          'RK-RES-012',
          'unit "${unit.name}" needs an explicit tag pattern',
          source: unit.location,
          remedy: 'this repository tags several units; declaring '
              'tag = "${unit.name}-v{version}" keeps this unit\'s public '
              'tag namespace stable if the repository changes again',
        );
      }
    }

    final units = <ResolvedUnit>[];
    for (final declared in config.units) {
      final resolved = byUnit[declared.name] ?? const [];
      if (resolved.length != declared.projects.length) continue;
      final tags = declared.publish.contains(PublishTarget.gitTag);
      units.add(
        ResolvedUnit(
          name: declared.name,
          publish: declared.publish,
          tagPattern: tags
              ? declared.tagPattern ??
                  _derivedTagPattern(resolved.single, tagUnits > 1)
              : null,
          tagWasDeclared: declared.tagPattern != null,
          homebrewTap: declared.homebrewTap,
          projects: resolved,
          location: declared.location,
        ),
      );
    }

    for (final unit in units) {
      _checkUnitVersions(unit, diagnostics);
      _checkReleaseAssetNames(unit, diagnostics);
    }
    _rejectSharedTags(units, diagnostics);

    if (diagnostics.isNotEmpty) return null;
    return Resolution(units: units, tree: tree);
  }

  /// A sole tagged unit gets the ordinary `v{version}` convention. The
  /// prefixed fallback is used only while constructing a refused multi-unit
  /// resolution so downstream validation remains total; multi-unit success
  /// requires every tag pattern to be explicit above.
  static String _derivedTagPattern(
    ResolvedProject project,
    bool releasesSeveral,
  ) =>
      releasesSeveral ? '${project.pubspec.name}-v{version}' : 'v{version}';

  /// Two units cannot share a tag.
  ///
  /// A tag is the record that a version of a unit was released, and a GitHub
  /// release attaches to one: shared, the second unit would either fail at the
  /// tag or attach its assets to the first unit's record. Derivation cannot
  /// produce this, so it is a declaration mistake — which is where it is
  /// cheapest to say so.
  static void _rejectSharedTags(
    List<ResolvedUnit> units,
    Diagnostics diagnostics,
  ) {
    final seen = <String, ResolvedUnit>{};
    for (final unit in units) {
      // Version disagreement is already RK-RES-008. Do not ask such a unit
      // for the single version its tag would contain while accumulating the
      // rest of the repository's diagnostics.
      if (unit.projects.isEmpty ||
          !unit.projects.every(
            (project) => project.version == unit.projects.first.version,
          )) {
        continue;
      }
      final tag = unit.tag;
      if (tag == null) continue;
      final first = seen[tag];
      if (first == null) {
        seen[tag] = unit;
        continue;
      }
      diagnostics.add(
        'RK-RES-010',
        'the units "${first.name}" and "${unit.name}" would share the tag '
            '"$tag"',
        source: unit.location,
        remedy: 'give each unit a tag that names it, as in '
            'tag = "${unit.name}-v{version}"',
      );
    }
  }

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

    if (pubspec.vetoesRegistry &&
        declared.publish.contains(PublishTarget.pubDev)) {
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
    if (!pubspec.declaresPubDev &&
        declared.publish.contains(PublishTarget.pubDev)) {
      diagnostics.add(
        'RK-RES-014',
        '"${pubspec.name}" names a custom package registry but is asked to '
            'publish to pub.dev',
        source: declared.location,
        remedy: 'this rk build has no custom Dart-registry target. Remove '
            '"pub.dev" from publish; do not copy the custom URL into '
            'release.toml',
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

  /// Public names are a destination contract. Private producer paths are
  /// qualified, but two projections with the same destination-normalized
  /// filename must refuse before either producer can write a byte.
  static void _checkReleaseAssetNames(
    ResolvedUnit unit,
    Diagnostics diagnostics,
  ) {
    final seen = <String, (ResolvedProject, String, String)>{};
    for (final project in unit.projects.where((p) => p.config.wantsBinaries)) {
      for (final platform in project.binaryPlatforms) {
        final name = standaloneArchiveName(
          project.executable!,
          project.version.canonical,
          platform,
        );
        final normalized = name.toLowerCase();
        final first = seen[normalized];
        if (first == null) {
          seen[normalized] = (project, platform, name);
          continue;
        }
        diagnostics.add(
          'RK-RES-011',
          'the projects "${first.$1.name}" and "${project.name}" both '
              'contribute the release asset "$name"',
          source: project.config.location,
          remedy: 'public release filenames must be unique; change the '
              'native executable name or release these projects in separate '
              'units',
        );
      }
    }

    final formulaOwners = <String, ResolvedProject>{};
    for (final project in unit.projects.where(
      (project) => project.publish.contains(PublishTarget.homebrew),
    )) {
      final path = 'Formula/${project.executable!}.rb';
      final first = formulaOwners[path.toLowerCase()];
      if (first == null) {
        formulaOwners[path.toLowerCase()] = project;
        continue;
      }
      diagnostics.add(
        'RK-RES-013',
        'the projects "${first.name}" and "${project.name}" both publish '
            'the Homebrew path "$path"',
        source: project.config.location,
        remedy: 'one tap path can hold one formula; change the native '
            'executable name or publish these projects from separate units',
      );
    }
  }

  /// Projects in one unit are at one version.
  ///
  /// This is not a tidiness rule: a unit is released under a single tag, that
  /// tag names one version, and [ResolvedUnit.version] reads it from the
  /// projects on the strength of their agreeing. A divergence has no answer to
  /// give — not a default one — so it is refused here, before anything reads a
  /// version that would be arbitrary.
  ///
  /// It costs nothing in recovery: a partial publish leaves the manifests
  /// untouched and is resumed by re-running, which finds what is already live
  /// and does the rest. Shipping one member alone is a separate unit's job.
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
    required this.publish,
    required this.tagPattern,
    required this.tagWasDeclared,
    required this.projects,
    required this.location,
    this.homebrewTap,
  });

  final String name;
  final Set<PublishTarget> publish;

  /// Declared, or derived from the publication target's convention.
  final String? tagPattern;
  final bool tagWasDeclared;

  /// The tap when it is not the conventional one.
  final String? homebrewTap;

  final List<ResolvedProject> projects;
  final SourceLocation location;

  /// The version this unit releases at.
  ///
  /// Its projects agree on it — the resolver refuses a unit whose projects do
  /// not (RK-RES-008) — so reading the first is reading all of them. The
  /// assertion keeps that invariant next to the code that depends on it, where
  /// a unit built by hand in a test would otherwise get an arbitrary answer.
  Version get version {
    assert(
      projects.every((p) => p.version == projects.first.version),
      'a unit whose projects disagree on the version has no version',
    );
    return projects.first.version;
  }

  String? get tag => tagPattern?.replaceAll('{version}', version.canonical);

  bool get shipsBinaries => projects.any((p) => p.config.wantsBinaries);

  /// Binary-producing projects in declaration order. The project/package name
  /// is repository-unique (RK-RES-007), so it is also the stable producer id
  /// without adding a configuration concept.
  List<ResolvedProject> get binaryProjects =>
      List.unmodifiable(projects.where((p) => p.config.wantsBinaries));

  /// A project carried by a typed checklist step. Project names are unique
  /// across the resolution (RK-RES-007), so they are stable producer ids too.
  ResolvedProject project(String name) =>
      projects.firstWhere((project) => project.name == name);

  /// The tap this unit's formula goes to, declared or by Homebrew's
  /// convention. Derived twice before, and a drift there means rk inspects
  /// one tap and pushes to another.
  String tapFor(String repository) =>
      homebrewTap ?? '${repository.split('/').first}/homebrew-tap';
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
  String get producerId => name;
  Version get version => pubspec.version!;
  Set<PublishTarget> get publish => config.publish;
  List<String> get binaryPlatforms => config.binaryPlatforms;

  /// The single executable a binary channel ships, when there is one.
  String? get executable =>
      pubspec.executables.isEmpty ? null : pubspec.executables.first;

  /// A file inside this project, tree-relative — for reading through a
  /// [SourceTree], which is always rooted at the repository.
  String fileAt(String name) =>
      pubspec.directory == '.' ? name : '${pubspec.directory}/$name';

  /// This project's directory under an absolute [root] — a different rule
  /// from [fileAt], and conflating the two puts a repository-absolute path
  /// where a tree-relative one belongs.
  String directoryIn(String root) =>
      pubspec.directory == '.' ? root : '$root/${pubspec.directory}';
}
