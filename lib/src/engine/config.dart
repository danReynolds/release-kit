import 'diagnostic.dart';
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
  static const supportedSchema = 1;

  /// The channels a project may publish to.
  static const channels = {'pub.dev', 'github-release', 'homebrew'};

  /// The closed, enumerable platform vocabulary, matching public asset names.
  static const supportedPlatformsList = [
    'linux-x64',
    'linux-arm64',
    'macos-arm64',
  ];

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
    this.codeId,
    this.homebrewTap,
  });

  final String name;

  /// The declared tag pattern, or null when it should be derived from the
  /// publication target's convention once package names are known.
  final String? tagPattern;

  /// The macOS code identifier for this unit's binary, for the one release
  /// that has no published binary to derive it from.
  ///
  /// Per unit, not per repository: a repository with two binary units has
  /// two program identities, and a single global value would have signed
  /// both as the same program. Every release after the first derives this
  /// from the binary users already installed, so a declaration that ever
  /// disagrees with what is published is refused rather than obeyed.
  final String? codeId;

  /// `owner/homebrew-tap` when the tap is not the conventional one.
  final String? homebrewTap;

  final List<ProjectConfig> projects;
  final SourceLocation location;
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
    if (_diagnostics.isNotEmpty) return null;
    return ReleaseConfig._(units);
  }

  /// An optional text setting on a unit table.
  String? _unitText(TomlTable value, String key) {
    if (!value.has(key)) return null;
    final entry = value[key];
    if (entry is String) {
      // Empty is not the same as omitted, and for `code_id` the difference is
      // permanent: `codesign -i ""` does not refuse, it silently substitutes a
      // filename-derived default, so a blank declaration ships a signature
      // nobody chose under an identifier nobody can predict.
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
    const known = {'schema', 'release'};
    for (final key in _root.keys) {
      if (known.contains(key)) continue;
      _diagnostics.add(
        'RK-CONF-003',
        'unknown setting "$key"',
        source: _root.locationOf(key),
        // `[identity]` is named because it is the one that used to be
        // valid, and a remedy that only says what is allowed leaves an
        // operator holding a file rk wrote no path forward. Two of its
        // four settings moved and two were deleted; a remedy that named
        // none of them is how a breaking change becomes a puzzle.
        remedy: key == 'identity'
            ? 'release.toml holds only ${known.join(', ')}. [identity] is '
                'gone: code_id and homebrew_tap moved onto the unit that '
                'reads them, and apple_team and tag_signer were removed — '
                'the certificate is derived from the release users already '
                'installed, and the tag signer from git.'
            : 'release.toml holds only ${known.join(', ')}',
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
      'code_id',
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
      final project = _project(name, value, location, inline: true);
      if (project != null) projects.add(project);
    } else if (rows is TomlArray) {
      for (final row in rows.tables) {
        final project = _project(name, row, row.location, inline: false);
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

    // A setting nothing in this unit can read is refused, the same way a
    // project naming platforms it does not ship gets RK-CONF-026 two hundred
    // lines down. Both were repository-global under `[identity]`; moving
    // them onto the unit made *which* unit a choice, and in a two-unit repo
    // it is a coin flip. Put `code_id` on the wrong one and it parses
    // clean, `_declarationAgrees` never fires — there is no sign step on
    // that unit to fire it — and the binary unit's first signed release
    // falls back to the package name, permanently, with nothing said.
    final signs = projects.any(
      (p) => p.binaryPlatforms.any((platform) => platform.startsWith('macos-')),
    );
    if (!signs && value.has('code_id')) {
      _diagnostics.add(
        'RK-CONF-035',
        'unit "$name" declares code_id but signs nothing',
        source: value.locationOf('code_id'),
        remedy: 'code_id is the macOS program identity, read only when a '
            'macOS binary is signed — move it to the unit whose '
            'binary_platforms name a macos- target, or remove it',
      );
      return null;
    }
    if (value.has('homebrew_tap') &&
        !projects.any((p) => p.channels.contains('homebrew'))) {
      _diagnostics.add(
        'RK-CONF-036',
        'unit "$name" declares homebrew_tap but does not publish to homebrew',
        source: value.locationOf('homebrew_tap'),
        remedy: 'add "homebrew" to its publish list, or remove homebrew_tap',
      );
      return null;
    }

    return UnitConfig(
      name: name,
      tagPattern: tag,
      codeId: _unitText(value, 'code_id'),
      homebrewTap: _unitText(value, 'homebrew_tap'),
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
  }) {
    const known = {'path', 'publish', 'binary_platforms'};
    const unitLevel = {'tag', 'project', 'code_id', 'homebrew_tap'};
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
    final parts =
        path.split('/').where((p) => p.isNotEmpty && p != '.').toList();
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
