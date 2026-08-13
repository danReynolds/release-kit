import 'diagnostic.dart';
import 'publish_target.dart';
import 'ref_name.dart';
import 'toml.dart';

/// The release intent declared in `release.toml`, structurally validated but
/// not yet resolved against the repository.
///
/// This layer knows nothing about packages or versions: it holds what the
/// author asked for. Native facts arrive later, when project paths are read.
class ReleaseConfig {
  ReleaseConfig._(this.units);

  /// Release units in declaration order, though order carries no meaning.
  final List<UnitConfig> units;

  /// The only schema version this build understands.
  static const supportedSchema = 2;

  static final targetNames =
      Set<String>.unmodifiable(PublishTarget.values.map((t) => t.configName));

  /// The closed, enumerable platform vocabulary, matching public asset names.
  static const supportedPlatformsList = [
    'linux-x64',
    'linux-arm64',
    'macos-arm64',
  ];

  static ReleaseConfig? parse(
    String source,
    String path,
    Diagnostics diagnostics,
  ) {
    final document = TomlDocument.parse(source, path, diagnostics);
    if (document == null) return null;
    return _Reader(document.root, path, diagnostics).run();
  }
}

class UnitConfig {
  UnitConfig({
    required this.name,
    required this.publish,
    required this.tagPattern,
    required this.projects,
    required this.location,
    this.homebrewTap,
  });

  final String name;
  final Set<PublishTarget> publish;

  /// The declared tag pattern, or null when it should be derived from the
  /// publication target's convention once package names are known.
  final String? tagPattern;

  /// `owner/homebrew-tap` when the tap is not the conventional one.
  final String? homebrewTap;

  final List<ProjectConfig> projects;
  final SourceLocation location;
}

class ProjectConfig {
  ProjectConfig({
    required this.path,
    required this.publish,
    required this.binaryPlatforms,
    required this.location,
  });

  /// Repository-relative directory, canonicalized; "." for the root.
  final String path;

  final Set<PublishTarget> publish;

  /// Empty unless standalone Dart CLI archives were explicitly requested.
  final List<String> binaryPlatforms;

  final SourceLocation location;

  bool get wantsBinaries => binaryPlatforms.isNotEmpty;
}

class _Reader {
  _Reader(this._root, this._path, this._diagnostics);

  final TomlTable _root;
  final String _path;
  final Diagnostics _diagnostics;

  static final _unitName = RegExp(r'^[a-z][a-z0-9_-]{0,62}$');

  ReleaseConfig? run() {
    if (!_schema()) return null;
    _unknownTopLevel();

    final units = _units();
    if (_diagnostics.isNotEmpty) return null;
    return ReleaseConfig._(units);
  }

  /// An optional text setting on a unit table.
  String? _unitText(TomlTable value, String key) {
    if (!value.has(key)) return null;
    final entry = value[key];
    if (entry is String) {
      if (entry.trim().isEmpty) {
        _diagnostics.add(
          'RK-CONF-037',
          '$key is empty',
          source: value.locationOf(key),
          remedy: 'give it a value or remove the line — a blank setting is '
              'not the same as an absent one',
        );
        return null;
      }
      return entry;
    }
    _diagnostics.add(
      'RK-CONF-032',
      '$key must be text',
      source: value.locationOf(key),
    );
    return null;
  }

  bool _schema() {
    final value = _root['schema'];
    if (value == null) {
      _diagnostics.add(
        'RK-CONF-001',
        'release.toml must declare its schema version',
        source: SourceLocation(_path, 1),
        remedy: 'add: schema = ${ReleaseConfig.supportedSchema}',
      );
      return false;
    }
    if (value is! int || value != ReleaseConfig.supportedSchema) {
      _diagnostics.add(
        'RK-CONF-002',
        'this rk understands schema ${ReleaseConfig.supportedSchema}, '
            'and this file declares $value',
        source: _root.locationOf('schema'),
        remedy: 'upgrade rk, or use schema ${ReleaseConfig.supportedSchema}',
      );
      return false;
    }
    return true;
  }

  void _unknownTopLevel() {
    const known = {'schema', 'release'};
    for (final key in _root.keys) {
      if (known.contains(key)) continue;
      _diagnostics.add(
        'RK-CONF-003',
        'unknown setting "$key"',
        source: _root.locationOf(key),
        remedy: 'release.toml holds only ${known.join(', ')}',
      );
    }
  }

  List<UnitConfig> _units() {
    final table = _root['release'];
    if (table == null) {
      _diagnostics.add(
        'RK-CONF-004',
        'release.toml declares no release units',
        source: SourceLocation(_path, 1),
        remedy: 'add a unit, as in:\n'
            '  [release.core]\n'
            '  path = "packages/keybay"\n'
            '  publish = ["pub.dev"]',
      );
      return const [];
    }
    if (table is! TomlTable) {
      _diagnostics.add(
        'RK-CONF-005',
        '"release" must hold units, as in [release.core]',
        source: _root.locationOf('release'),
      );
      return const [];
    }

    final units = <UnitConfig>[];
    for (final name in table.keys) {
      final unit = _unit(name, table[name], table.locationOf(name));
      if (unit != null) units.add(unit);
    }
    return units;
  }

  UnitConfig? _unit(String name, Object? value, SourceLocation location) {
    if (!_unitName.hasMatch(name)) {
      _diagnostics.add(
        'RK-CONF-006',
        'unit name "$name" is not usable',
        source: location,
        remedy: 'start with a lowercase letter, then lowercase letters, '
            'digits, hyphens or underscores',
      );
      return null;
    }
    if (value is! TomlTable) {
      _diagnostics.add(
        'RK-CONF-007',
        'unit "$name" must be a table, as in [release.$name]',
        source: location,
      );
      return null;
    }

    const known = {
      'tag',
      'path',
      'publish',
      'binary_platforms',
      'project',
      'homebrew_tap',
    };
    for (final key in value.keys) {
      if (known.contains(key)) continue;
      _diagnostics.add(
        'RK-CONF-008',
        'unknown setting "$key" in unit "$name"',
        source: value.locationOf(key),
        remedy: 'a unit holds ${known.join(', ')}',
      );
    }

    final rows = value['project'];
    final hasRows = rows != null;

    if (hasRows && (value.has('path') || value.has('binary_platforms'))) {
      _diagnostics.add(
        'RK-CONF-009',
        'unit "$name" declares a project inline and also as rows',
        source: location,
        remedy: 'a unit with one project uses path/publish directly; a unit '
            'with several uses [[release.$name.project]] rows — not both',
      );
      return null;
    }

    final selected = _publish(name, value, location);
    if (selected == null) return null;
    final unitPublish = <PublishTarget>{};
    final inlinePublish = <PublishTarget>{};
    for (final target in selected) {
      if (target.scope == TargetScope.unit) {
        unitPublish.add(target);
      } else if (hasRows) {
        _diagnostics.add(
          'RK-CONF-038',
          '"${target.configName}" belongs to a project in "$name"',
          source: value.locationOf('publish'),
          remedy: 'move it to the relevant [[release.$name.project]] row\n'
              'Run rk target ${target.configName} for a complete example.',
        );
      } else {
        inlinePublish.add(target);
      }
    }

    final tag = _tagPattern(name, value);
    if (value.has('tag') && !unitPublish.contains(PublishTarget.gitTag)) {
      _diagnostics.add(
        'RK-CONF-039',
        'unit "$name" declares a tag but does not publish a Git tag',
        source: value.locationOf('tag'),
        remedy: 'add "git-tag" to publish, or remove tag',
      );
    }
    for (final target in unitPublish) {
      for (final prerequisite in target.prerequisites) {
        if (unitPublish.contains(prerequisite)) continue;
        _diagnostics.add(
          'RK-CONF-024',
          '${target.configName} needs ${prerequisite.configName}',
          source: value.locationOf('publish'),
          remedy: 'add "${prerequisite.configName}", or drop '
              '"${target.configName}"\n'
              'Run rk target ${target.configName} for its requirements.',
        );
      }
    }

    final projects = <ProjectConfig>[];
    // How many rows were *attempted*, so a row that failed to parse can be
    // told apart from a row that is absent. `_project` returns null on any
    // validation failure and the row is silently dropped, so without this
    // count "rk could not read this project" becomes "this unit has no such
    // project" — the same collapse the verdicts are built to prevent.
    var attempted = 0;
    if (!hasRows) {
      attempted = 1;
      final project = _project(
        name,
        value,
        location,
        inline: true,
        inlinePublish: inlinePublish,
      );
      if (project != null) projects.add(project);
    } else if (rows is TomlArray) {
      attempted = rows.tables.length;
      for (final row in rows.tables) {
        final project = _project(name, row, row.location, inline: false);
        if (project != null) projects.add(project);
      }
    } else {
      _diagnostics.add(
        'RK-CONF-010',
        'unit "$name" has a malformed project list',
        source: location,
        remedy: 'declare each with [[release.$name.project]]',
      );
      return null;
    }

    if (projects.isEmpty) {
      _diagnostics.add(
        'RK-CONF-011',
        'unit "$name" releases nothing',
        source: location,
        remedy: 'give it a project: path and publish',
      );
      return null;
    }

    if (projects.length > 1 &&
        unitPublish.contains(PublishTarget.gitTag) &&
        tag == null) {
      _diagnostics.add(
        'RK-CONF-012',
        'unit "$name" releases several projects, so its tag cannot be derived',
        source: location,
        remedy: 'a set of packages has no canonical name — declare one, as in '
            'tag = "$name-v{version}"',
      );
      return null;
    }

    final complete = projects.length == attempted;
    if (complete &&
        unitPublish.isEmpty &&
        projects.every(
          (project) =>
              project.publish.isEmpty && project.binaryPlatforms.isEmpty,
        )) {
      _diagnostics.add(
        'RK-CONF-019',
        'unit "$name" selects no release output',
        source: location,
        remedy: 'add a publish target or binary_platforms',
      );
    }

    final homebrewProjects = projects
        .where((p) => p.publish.contains(PublishTarget.homebrew))
        .toList();
    if (complete && homebrewProjects.isNotEmpty) {
      for (final prerequisite in PublishTarget.homebrew.prerequisites) {
        if (unitPublish.contains(prerequisite)) continue;
        _diagnostics.add(
          'RK-CONF-024',
          'homebrew needs ${prerequisite.configName}',
          source: homebrewProjects.first.location,
          remedy: 'add "${prerequisite.configName}" and its prerequisites '
              'to the unit publish list, or drop "homebrew"\n'
              'Run rk target homebrew for a complete example.',
        );
      }
      for (final project in homebrewProjects) {
        if (project.binaryPlatforms.isEmpty) {
          _diagnostics.add(
            'RK-CONF-025',
            'a Homebrew project in "$name" names no binary platforms',
            source: project.location,
            remedy: 'add binary_platforms, or drop "homebrew"\n'
                'Run rk target homebrew for supported values and an example.',
          );
        }
      }
    }
    if (complete && value.has('homebrew_tap') && homebrewProjects.isEmpty) {
      _diagnostics.add(
        'RK-CONF-036',
        'unit "$name" declares homebrew_tap but does not publish to homebrew',
        source: value.locationOf('homebrew_tap'),
        remedy: 'add "homebrew" to its publish list, or remove homebrew_tap',
      );
      return null;
    }
    final homebrewTap = _unitText(value, 'homebrew_tap');
    if (homebrewTap != null &&
        (!_githubCoordinate.hasMatch(homebrewTap) ||
            homebrewTap
                .split('/')
                .any((part) => part == '.' || part == '..'))) {
      _diagnostics.add(
        'RK-CONF-040',
        'homebrew_tap must be a GitHub owner/repository',
        source: value.locationOf('homebrew_tap'),
        remedy: 'use a coordinate such as "some-org/homebrew-tools"; '
            'omit it for the conventional owner/homebrew-tap\n'
            'Run rk target homebrew for the inferred default and example.',
      );
    }

    return UnitConfig(
      name: name,
      publish: Set.unmodifiable(unitPublish),
      tagPattern: tag,
      homebrewTap: homebrewTap,
      projects: projects,
      location: location,
    );
  }

  String? _tagPattern(String unit, TomlTable table) {
    if (!table.has('tag')) return null;
    final value = table['tag'];
    final location = table.locationOf('tag');
    if (value is! String) {
      _diagnostics.add(
        'RK-CONF-013',
        'the tag pattern for "$unit" must be text',
        source: location,
      );
      return null;
    }
    final placeholders = '{version}'.allMatches(value).length;
    if (placeholders != 1) {
      _diagnostics.add(
        'RK-CONF-014',
        'the tag pattern for "$unit" must contain {version} exactly once',
        source: location,
        remedy: 'as in tag = "$unit-v{version}"',
      );
      return null;
    }
    if (value.contains('{') &&
        value.replaceAll('{version}', '').contains('{')) {
      _diagnostics.add(
        'RK-CONF-015',
        'the tag pattern for "$unit" uses a placeholder rk does not have',
        source: location,
        remedy: '{version} is the only one; the rest is literal text',
      );
      return null;
    }

    // What git is handed is the pattern with a version in it, so that is what
    // is checked; every version rk accepts is itself ref-safe.
    final issue = refNameIssue(value.replaceAll('{version}', '0.0.0'));
    if (issue != null) {
      _diagnostics.add(
        'RK-CONF-033',
        'git will not accept the tag pattern for "$unit": $issue',
        source: location,
        remedy: 'a tag is a git ref, so its name follows git\'s rules',
      );
      return null;
    }
    return value;
  }

  /// Reads one project. [inline] says whether [table] is the unit's own table,
  /// which also carries the unit-level keys — a distinction that matters
  /// because a `tag` there belongs to the unit, while a `tag` on a row has
  /// nowhere to belong and would otherwise be read by nobody.
  ProjectConfig? _project(
    String unit,
    TomlTable table,
    SourceLocation location, {
    required bool inline,
    Set<PublishTarget> inlinePublish = const {},
  }) {
    const known = {'path', 'publish', 'binary_platforms'};
    const unitLevel = {'tag', 'project', 'homebrew_tap'};
    for (final key in table.keys) {
      if (known.contains(key)) continue;
      if (inline && unitLevel.contains(key)) continue;
      _diagnostics.add(
        'RK-CONF-016',
        unitLevel.contains(key)
            ? '"$key" belongs to the unit "$unit", not to one of its projects'
            : 'unknown setting "$key" in a project of "$unit"',
        source: table.locationOf(key),
        remedy: unitLevel.contains(key)
            ? 'a unit releases its projects under one $key — move it up to '
                '[release.$unit]'
            : 'a project holds ${known.join(', ')}',
      );
    }

    final path = _projectPath(unit, table, location);
    final selected = inline
        ? inlinePublish
        : _publish(unit, table, location, allowMissing: true);
    if (path == null || selected == null) return null;

    if (!inline) {
      for (final target in selected) {
        if (target.scope == TargetScope.project) continue;
        _diagnostics.add(
          'RK-CONF-038',
          '"${target.configName}" belongs to the unit "$unit"',
          source: table.locationOf('publish'),
          remedy: 'move it to [release.$unit]',
        );
      }
    }

    final projectPublish =
        selected.where((target) => target.scope == TargetScope.project).toSet();
    final platforms = _platforms(unit, table, location);
    if (platforms == null) return null;

    return ProjectConfig(
      path: path,
      publish: Set.unmodifiable(projectPublish),
      binaryPlatforms: platforms,
      location: location,
    );
  }

  String? _projectPath(
    String unit,
    TomlTable table,
    SourceLocation location,
  ) {
    // An omitted path means the repository root, where release.toml lives.
    if (!table.has('path')) return '.';
    final value = table['path'];
    if (value is! String || value.isEmpty) {
      _diagnostics.add(
        'RK-CONF-017',
        'a project path in "$unit" must be text',
        source: table.locationOf('path'),
        remedy: 'as in path = "packages/keybay"',
      );
      return null;
    }
    if (value.startsWith('/') || value.contains('..')) {
      _diagnostics.add(
        'RK-CONF-018',
        'the project path "$value" leaves the repository',
        source: table.locationOf('path'),
        remedy: 'paths are relative to the repository root and stay inside it',
      );
      return null;
    }
    return _canonical(value);
  }

  static String _canonical(String path) {
    final parts =
        path.split('/').where((p) => p.isNotEmpty && p != '.').toList();
    return parts.isEmpty ? '.' : parts.join('/');
  }

  Set<PublishTarget>? _publish(
    String unit,
    TomlTable table,
    SourceLocation location, {
    bool allowMissing = true,
  }) {
    final value = table['publish'];
    if (value == null) {
      if (allowMissing) return const {};
      _diagnostics.add(
        'RK-CONF-019',
        'unit "$unit" does not say where to publish',
        source: location,
        remedy: 'add publish with at least one target',
      );
      return null;
    }
    if (value is! List<String>) {
      _diagnostics.add(
        'RK-CONF-020',
        'publish must be a list of targets',
        source: table.locationOf('publish'),
        remedy: 'as in publish = ["git-tag", "pub.dev"]',
      );
      return null;
    }

    final names = <String>{};
    final selected = <PublishTarget>{};
    for (final name in value) {
      final target = PublishTarget.named(name);
      if (target == null) {
        _diagnostics.add(
          'RK-CONF-022',
          'unknown target "$name"',
          source: table.locationOf('publish'),
          remedy: 'rk publishes to ${ReleaseConfig.targetNames.join(', ')}\n'
              'Run rk target list to see what each choice does.',
        );
        return null;
      }
      if (!names.add(name)) {
        _diagnostics.add(
          'RK-CONF-023',
          '"$name" is listed twice',
          source: table.locationOf('publish'),
          remedy: 'publish is a set; order and repetition carry no meaning',
        );
        return null;
      }
      selected.add(target);
    }
    return selected;
  }

  List<String>? _platforms(
    String unit,
    TomlTable table,
    SourceLocation location,
  ) {
    final value = table['binary_platforms'];
    if (value == null) return const [];
    if (value is! List<String> || value.isEmpty) {
      _diagnostics.add(
        'RK-CONF-027',
        'binary_platforms must be a non-empty list',
        source: table.locationOf('binary_platforms'),
      );
      return null;
    }

    final seen = <String>{};
    for (final platform in value) {
      if (!ReleaseConfig.supportedPlatformsList.contains(platform)) {
        _diagnostics.add(
          'RK-CONF-028',
          'unknown platform "$platform"',
          source: table.locationOf('binary_platforms'),
          remedy:
              'rk builds ${ReleaseConfig.supportedPlatformsList.join(', ')}',
        );
        return null;
      }
      if (!seen.add(platform)) {
        _diagnostics.add(
          'RK-CONF-029',
          '"$platform" is listed twice',
          source: table.locationOf('binary_platforms'),
        );
        return null;
      }
    }
    return value;
  }
}

final RegExp _githubCoordinate = RegExp(
  r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$',
);
