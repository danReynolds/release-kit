import 'diagnostic.dart';
import 'toml.dart';

/// The release intent declared in `release.toml`, structurally validated but
/// not yet resolved against the repository.
///
/// This layer knows nothing about packages or versions: it holds what the
/// author asked for. Native facts arrive later, when project paths are read.
class ReleaseConfig {
  ReleaseConfig._(this.units, this.identity);

  /// Release units in declaration order, though order carries no meaning.
  final List<UnitConfig> units;

  /// Overrides for facts rk otherwise derives from published reality.
  final IdentityConfig? identity;

  /// The only schema version this build understands.
  static const supportedSchema = 1;

  /// The channels a project may publish to.
  static const channels = {'pub.dev', 'github-release', 'homebrew'};

  /// Channels that produce per-platform binaries.
  static const platformBearingChannels = {'github-release', 'homebrew'};

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
    required this.tagPattern,
    required this.projects,
    required this.location,
  });

  final String name;

  /// The declared tag pattern, or null when it should be derived from the
  /// publication target's convention once package names are known.
  final String? tagPattern;

  final List<ProjectConfig> projects;
  final SourceLocation location;

  bool get isSingleProject => projects.length == 1;
}

class ProjectConfig {
  ProjectConfig({
    required this.path,
    required this.channels,
    required this.binaryPlatforms,
    required this.location,
  });

  /// Repository-relative directory, canonicalized; "." for the root.
  final String path;

  final Set<String> channels;

  /// Empty unless a platform-bearing channel was requested.
  final List<String> binaryPlatforms;

  final SourceLocation location;

  bool get wantsBinaries =>
      channels.any(ReleaseConfig.platformBearingChannels.contains);
}

class IdentityConfig {
  IdentityConfig({
    this.appleTeam,
    this.codeId,
    this.homebrewTap,
    this.tagSigner,
  });

  final String? appleTeam;
  final String? codeId;
  final String? homebrewTap;
  final String? tagSigner;
}

class _Reader {
  _Reader(this._root, this._path, this._diagnostics);

  final TomlTable _root;
  final String _path;
  final Diagnostics _diagnostics;

  static final _unitName = RegExp(r'^[a-z][a-z0-9_-]{0,62}$');

  ReleaseConfig? run() {
    _schema();
    _unknownTopLevel();

    final units = _units();
    final identity = _identity();

    if (_diagnostics.isNotEmpty) return null;
    return ReleaseConfig._(units, identity);
  }

  void _schema() {
    final value = _root['schema'];
    if (value == null) {
      _diagnostics.add(
        'RK-CONF-001',
        'release.toml must declare its schema version',
        source: SourceLocation(_path, 1),
        remedy: 'add: schema = ${ReleaseConfig.supportedSchema}',
      );
      return;
    }
    if (value is! int || value != ReleaseConfig.supportedSchema) {
      _diagnostics.add(
        'RK-CONF-002',
        'this rk understands schema ${ReleaseConfig.supportedSchema}, '
            'and this file declares $value',
        source: _root.locationOf('schema'),
        remedy: 'upgrade rk, or set schema = ${ReleaseConfig.supportedSchema}',
      );
    }
  }

  void _unknownTopLevel() {
    const known = {'schema', 'release', 'identity'};
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

    const known = {'tag', 'path', 'publish', 'binary_platforms', 'project'};
    for (final key in value.keys) {
      if (known.contains(key)) continue;
      _diagnostics.add(
        'RK-CONF-008',
        'unknown setting "$key" in unit "$name"',
        source: value.locationOf(key),
        remedy: 'a unit holds ${known.join(', ')}',
      );
    }

    final tag = _tagPattern(name, value);
    // An omitted path means the repository root, so any project-level key —
    // not just path — marks a unit that declares its project inline.
    final inline = value.has('path') ||
        value.has('publish') ||
        value.has('binary_platforms');
    final rows = value['project'];

    if (inline && rows != null) {
      _diagnostics.add(
        'RK-CONF-009',
        'unit "$name" declares a project inline and also as rows',
        source: location,
        remedy: 'a unit with one project uses path/publish directly; a unit '
            'with several uses [[release.$name.project]] rows — not both',
      );
      return null;
    }

    final projects = <ProjectConfig>[];
    if (inline) {
      final project = _project(name, value, location);
      if (project != null) projects.add(project);
    } else if (rows is TomlArray) {
      for (final row in rows.tables) {
        final project = _project(name, row, row.location);
        if (project != null) projects.add(project);
      }
    } else if (rows != null) {
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

    if (projects.length > 1 && tag == null) {
      _diagnostics.add(
        'RK-CONF-012',
        'unit "$name" releases several projects, so its tag cannot be derived',
        source: location,
        remedy: 'a set of packages has no canonical name — declare one, as in '
            'tag = "$name-v{version}"',
      );
      return null;
    }

    return UnitConfig(
      name: name,
      tagPattern: tag,
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
    return value;
  }

  ProjectConfig? _project(
    String unit,
    TomlTable table,
    SourceLocation location,
  ) {
    const known = {'path', 'publish', 'binary_platforms'};
    for (final key in table.keys) {
      if (known.contains(key) || key == 'tag' || key == 'project') continue;
      _diagnostics.add(
        'RK-CONF-016',
        'unknown setting "$key" in a project of "$unit"',
        source: table.locationOf(key),
        remedy: 'a project holds ${known.join(', ')}',
      );
    }

    final path = _projectPath(unit, table, location);
    final channels = _channels(unit, table, location);
    if (path == null || channels == null) return null;

    final platforms = _platforms(unit, table, channels, location);
    if (platforms == null) return null;

    return ProjectConfig(
      path: path,
      channels: channels,
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
    final parts = path
        .split('/')
        .where((p) => p.isNotEmpty && p != '.')
        .toList();
    return parts.isEmpty ? '.' : parts.join('/');
  }

  Set<String>? _channels(
    String unit,
    TomlTable table,
    SourceLocation location,
  ) {
    final value = table['publish'];
    if (value == null) {
      _diagnostics.add(
        'RK-CONF-019',
        'a project in "$unit" does not say where to publish',
        source: location,
        remedy: 'add publish = ["pub.dev"]',
      );
      return null;
    }
    if (value is! List<String>) {
      _diagnostics.add(
        'RK-CONF-020',
        'publish must be a list of channels',
        source: table.locationOf('publish'),
        remedy: 'as in publish = ["pub.dev", "github-release"]',
      );
      return null;
    }
    if (value.isEmpty) {
      _diagnostics.add(
        'RK-CONF-021',
        'a project in "$unit" publishes to nothing',
        source: table.locationOf('publish'),
        remedy: 'remove the project, or give it a channel',
      );
      return null;
    }

    final seen = <String>{};
    for (final channel in value) {
      if (!ReleaseConfig.channels.contains(channel)) {
        _diagnostics.add(
          'RK-CONF-022',
          'unknown channel "$channel"',
          source: table.locationOf('publish'),
          remedy: 'rk publishes to '
              '${ReleaseConfig.channels.join(', ')}',
        );
        return null;
      }
      if (!seen.add(channel)) {
        _diagnostics.add(
          'RK-CONF-023',
          '"$channel" is listed twice',
          source: table.locationOf('publish'),
          remedy: 'publish is a set; order and repetition carry no meaning',
        );
        return null;
      }
    }

    if (seen.contains('homebrew') && !seen.contains('github-release')) {
      _diagnostics.add(
        'RK-CONF-024',
        'homebrew needs github-release, which hosts the archives it points at',
        source: table.locationOf('publish'),
        remedy: 'add "github-release", or drop "homebrew"',
      );
      return null;
    }

    return seen;
  }

  List<String>? _platforms(
    String unit,
    TomlTable table,
    Set<String> channels,
    SourceLocation location,
  ) {
    final wantsBinaries =
        channels.any(ReleaseConfig.platformBearingChannels.contains);
    final value = table['binary_platforms'];

    if (value == null) {
      if (wantsBinaries) {
        _diagnostics.add(
          'RK-CONF-025',
          'a project in "$unit" ships binaries but names no platforms',
          source: location,
          remedy: 'add binary_platforms, as in '
              '["linux-x64", "linux-arm64", "macos-arm64"]',
        );
        return null;
      }
      return const [];
    }

    if (!wantsBinaries) {
      _diagnostics.add(
        'RK-CONF-026',
        'a project in "$unit" names platforms but ships no binaries',
        source: table.locationOf('binary_platforms'),
        remedy: 'remove binary_platforms, or publish to github-release',
      );
      return null;
    }
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
      if (!supportedPlatforms.contains(platform)) {
        _diagnostics.add(
          'RK-CONF-028',
          'unknown platform "$platform"',
          source: table.locationOf('binary_platforms'),
          remedy: 'rk builds ${supportedPlatforms.join(', ')}',
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

  /// The closed, enumerable platform vocabulary, matching public asset names.
  static const supportedPlatforms = [
    'linux-x64',
    'linux-arm64',
    'macos-arm64',
  ];

  IdentityConfig? _identity() {
    final value = _root['identity'];
    if (value == null) return null;
    if (value is! TomlTable) {
      _diagnostics.add(
        'RK-CONF-030',
        '"identity" must be a table',
        source: _root.locationOf('identity'),
      );
      return null;
    }

    const known = {'apple_team', 'code_id', 'homebrew_tap', 'tag_signer'};
    for (final key in value.keys) {
      if (known.contains(key)) continue;
      _diagnostics.add(
        'RK-CONF-031',
        'unknown identity override "$key"',
        source: value.locationOf(key),
        remedy: 'identity holds ${known.join(', ')}',
      );
    }

    String? text(String key) {
      if (!value.has(key)) return null;
      final entry = value[key];
      if (entry is String) return entry;
      _diagnostics.add(
        'RK-CONF-032',
        'identity.$key must be text',
        source: value.locationOf(key),
      );
      return null;
    }

    return IdentityConfig(
      appleTeam: text('apple_team'),
      codeId: text('code_id'),
      homebrewTap: text('homebrew_tap'),
      tagSigner: text('tag_signer'),
    );
  }
}
