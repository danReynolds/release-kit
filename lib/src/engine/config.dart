import 'diagnostic.dart';
import 'publish_target.dart';
import 'ref_name.dart';
import 'source_tree.dart';
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

  static final targetNames = Set<String>.unmodifiable(
    PublishTarget.values.map((t) => t.configName),
  );

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
    final root = parseToml(source, path, diagnostics);
    return root == null ? null : _Reader(root, path, diagnostics).run();
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
    this.dartDefinesFromPubspec = const [],
    this.build = const [],
    this.assets = const [],
    required this.location,
  });

  /// Repository-relative directory, canonicalized; "." for the root.
  final String path;

  final Set<PublishTarget> publish;

  /// Empty unless standalone Dart CLI archives were explicitly requested.
  final List<String> binaryPlatforms;

  /// Native manifest fields to project into Dart compile-time environment.
  final List<String> dartDefinesFromPubspec;

  /// The project's own command that builds its release assets: the program
  /// and its arguments, where `{out}` names the directory it writes to.
  /// Empty unless the project declares one.
  final List<String> build;

  /// The files [build] writes that the unit's GitHub release publishes,
  /// relative to its output directory, each under its own file name.
  final List<String> assets;

  final SourceLocation location;

  bool get wantsBinaries => binaryPlatforms.isNotEmpty;

  bool get buildsAssets => build.isNotEmpty;
}

/// The shape of a setting's value.
enum _Shape { text, texts, rows }

/// One setting `release.toml` may hold, and what it accepts.
final class _Setting {
  const _Setting(
    this.key,
    this.shape,
    this.example, {
    this.empty = false,
    this.choices,
    this.check,
    this.sameAs,
    this.hint,
  });

  final String key;
  final _Shape shape;

  /// The setting written out, for the remedy; `{unit}` is the unit's name.
  final String example;

  /// Whether an empty list is a value: `publish = []` publishes nothing.
  final bool empty;

  /// The only items it accepts: targets, platforms.
  final Iterable<String>? choices;

  /// Why a text value, or one item of a list, is refused; null when it is
  /// not.
  final String? Function(String value)? check;

  /// What no two items may share, for a list whose items may not repeat:
  /// assets are published under their file names.
  final String Function(String item)? sameAs;

  /// Where to read more, after the remedy.
  final String? hint;
}

/// What a project holds: a project row, or the unit's own table for a unit
/// of one project.
final _projectSettings = [
  const _Setting(
    'path',
    _Shape.text,
    'path = "packages/keybay"',
    check: _staysInside,
  ),
  _Setting(
    'publish',
    _Shape.texts,
    'publish = ["git-tag", "pub.dev"]',
    empty: true,
    choices: ReleaseConfig.targetNames,
    sameAs: _itself,
    hint: 'Run rk target list to see what each choice does.',
  ),
  const _Setting(
    'binary_platforms',
    _Shape.texts,
    'binary_platforms = ["macos-arm64"]',
    choices: ReleaseConfig.supportedPlatformsList,
    sameAs: _itself,
  ),
  const _Setting(
    'dart_defines_from_pubspec',
    _Shape.texts,
    'dart_defines_from_pubspec = ["app.name"]',
    empty: true,
    check: _dottedField,
    sameAs: _itself,
  ),
  const _Setting(
    'build',
    _Shape.texts,
    'build = ["tool/build.sh", "{out}"], run from the project\'s directory',
    check: _onlyOutPlaceholder,
  ),
  const _Setting(
    'assets',
    _Shape.texts,
    'assets = ["lib-macos-arm64.dylib"], relative to {out}',
    check: _insideOutput,
    sameAs: _publishedName,
  ),
];

/// What a unit holds: its project's settings, when it has one project, and
/// its own.
final _unitSettings = [
  ..._projectSettings,
  const _Setting(
    'tag',
    _Shape.text,
    'tag = "{unit}-v{version}"',
    check: _tagPattern,
  ),
  const _Setting('project', _Shape.rows, '[[release.{unit}.project]]'),
  const _Setting(
    'homebrew_tap',
    _Shape.text,
    'homebrew_tap = "some-org/homebrew-tools"; omit it for the '
        'conventional owner/homebrew-tap',
    check: _githubCoordinate,
    hint: 'Run rk target homebrew for the inferred default and example.',
  ),
];

/// The project settings a unit with project rows keeps on the rows.
const _rowSettings = {
  'path',
  'binary_platforms',
  'dart_defines_from_pubspec',
  'build',
  'assets',
};

class _Reader {
  _Reader(this._root, this._path, this._diagnostics);

  final TomlTable _root;
  final String _path;
  final Diagnostics _diagnostics;

  static final _unitName = RegExp(r'^[a-z][a-z0-9_-]{0,62}$');

  ReleaseConfig? run() {
    final schema = _root['schema'];
    if (schema != ReleaseConfig.supportedSchema) {
      _diagnostics.add(
        'RK-CONF-002',
        schema == null
            ? 'release.toml must declare its schema version'
            : 'this rk understands schema ${ReleaseConfig.supportedSchema}, '
                  'and this file declares $schema',
        source: schema == null
            ? SourceLocation(_path, 1)
            : _root.locationOf('schema'),
        remedy: schema == null
            ? 'add: schema = ${ReleaseConfig.supportedSchema}'
            : 'upgrade rk, or use schema ${ReleaseConfig.supportedSchema}',
      );
      return null;
    }
    for (final key in _root.keys) {
      if (key == 'schema' || key == 'release') continue;
      _diagnostics.add(
        'RK-CONF-003',
        'unknown setting "$key"',
        source: _root.locationOf(key),
        remedy: 'release.toml holds only schema, release',
      );
    }
    final table = _root['release'];
    if (table is! TomlTable) {
      _diagnostics.add(
        'RK-CONF-005',
        table == null
            ? 'release.toml declares no release units'
            : '"release" must hold units, as in [release.core]',
        source: table == null
            ? SourceLocation(_path, 1)
            : _root.locationOf('release'),
        remedy: table == null
            ? 'add a unit, as in:\n'
                  '  [release.core]\n'
                  '  path = "packages/keybay"\n'
                  '  publish = ["pub.dev"]'
            : null,
      );
      return null;
    }
    final units = [
      for (final name in table.keys)
        ?_unit(name, table[name], table.locationOf(name)),
    ];
    if (_diagnostics.isEmpty) _checkTags(units);
    return _diagnostics.isEmpty ? ReleaseConfig._(units) : null;
  }

  UnitConfig? _unit(String name, Object? value, SourceLocation location) {
    if (!_unitName.hasMatch(name)) {
      _diagnostics.add(
        'RK-CONF-005',
        'unit name "$name" is not usable',
        source: location,
        remedy:
            'start with a lowercase letter, then lowercase letters, '
            'digits, hyphens or underscores',
      );
      return null;
    }
    if (value is! TomlTable) {
      _diagnostics.add(
        'RK-CONF-005',
        'unit "$name" must be a table, as in [release.$name]',
        source: location,
      );
      return null;
    }
    if (!_checkShape(value, _unitSettings, unit: name)) return null;
    final rows = value['project'] as TomlArray?;
    if (rows != null && _rowSettings.any(value.has)) {
      _rule(
        location,
        'unit "$name" declares a project inline and also as rows',
        'a unit with one project uses path/publish directly; a unit '
            'with several uses [[release.$name.project]] rows — not both',
      );
      return null;
    }

    final unitTargets = <PublishTarget>{};
    final projectTargets = <PublishTarget>{};
    for (final target in _targets(value)) {
      if (target.scope == TargetScope.unit) {
        unitTargets.add(target);
      } else if (rows == null) {
        projectTargets.add(target);
      } else {
        _diagnostics.add(
          'RK-CONF-003',
          '"${target.configName}" belongs to a project in "$name"',
          source: value.locationOf('publish'),
          remedy:
              'move it to the relevant [[release.$name.project]] row\n'
              'Run rk target ${target.configName} for a complete example.',
        );
      }
    }
    final projects = [
      if (rows == null)
        _project(name, value, projectTargets, location)
      else
        for (final row in rows.tables) _row(name, row),
    ];
    if (projects.contains(null)) return null;
    final unit = UnitConfig(
      name: name,
      publish: Set.unmodifiable(unitTargets),
      tagPattern: value['tag'] as String?,
      homebrewTap: value['homebrew_tap'] as String?,
      projects: List.unmodifiable(projects.nonNulls),
      location: location,
    );
    _checkRules(unit, value);
    return unit;
  }

  /// A project row, whose targets are its project's own.
  ProjectConfig? _row(String unit, TomlTable row) {
    if (!_checkShape(row, _projectSettings, unit: unit, row: true)) {
      return null;
    }
    final targets = <PublishTarget>{};
    for (final target in _targets(row)) {
      if (target.scope == TargetScope.project) {
        targets.add(target);
        continue;
      }
      _diagnostics.add(
        'RK-CONF-003',
        '"${target.configName}" belongs to the unit "$unit"',
        source: row.locationOf('publish'),
        remedy: 'move it to [release.$unit]',
      );
    }
    return _project(unit, row, targets, row.location);
  }

  /// The project [table] declares, its values already checked, and what its
  /// settings require of one another.
  ProjectConfig? _project(
    String unit,
    TomlTable table,
    Set<PublishTarget> publish,
    SourceLocation location,
  ) {
    List<String> texts(String key) =>
        List.unmodifiable(table[key] as List<String>? ?? const <String>[]);
    final project = ProjectConfig(
      path: _canonical(table['path'] as String? ?? '.'),
      publish: Set.unmodifiable(publish),
      binaryPlatforms: texts('binary_platforms'),
      dartDefinesFromPubspec: texts('dart_defines_from_pubspec'),
      build: texts('build'),
      assets: texts('assets'),
      location: location,
    );
    if (project.dartDefinesFromPubspec.isNotEmpty && !project.wantsBinaries) {
      _rule(
        table.locationOf('dart_defines_from_pubspec'),
        'a project of "$unit" declares dart_defines_from_pubspec without '
            'binary_platforms',
        'the fields are compiled into its binaries: add binary_platforms, '
            'or remove dart_defines_from_pubspec',
      );
      return null;
    }
    final apart = project.build.isEmpty != project.assets.isEmpty;
    if (apart || project.buildsAssets && project.wantsBinaries) {
      _rule(
        table.locationOf(project.build.isEmpty ? 'assets' : 'build'),
        apart
            ? 'a project of "$unit" declares '
                  '${project.build.isEmpty ? 'assets without a build' : 'a build without assets'}'
            : 'a project of "$unit" declares both a build and binary_platforms',
        apart
            ? 'build names the command, and assets the files it writes that '
                  'the release publishes; declare both'
            : 'rk compiles binary_platforms itself; a project releases '
                  'either those or what its own build writes',
      );
      return null;
    }
    return project;
  }

  /// RK-CONF-003 for each key [table] does not hold, and RK-CONF-005 for
  /// each value of another shape, empty, outside its choices, repeated, or
  /// refused by its check: `<key>: <why>` at the key's line, with the
  /// remedy `as in <example>`. Whether every value is one rk accepts.
  bool _checkShape(
    TomlTable table,
    List<_Setting> settings, {
    required String unit,
    bool row = false,
  }) {
    final before = _diagnostics.found.length;
    final known = {for (final setting in settings) setting.key: setting};
    for (final key in table.keys) {
      final setting = known[key];
      if (setting == null) {
        final unitLevel = row && _unitSettings.any((s) => s.key == key);
        _diagnostics.add(
          'RK-CONF-003',
          unitLevel
              ? '"$key" belongs to the unit "$unit", not to one of its projects'
              : 'unknown setting "$key" in '
                    '${row ? 'a project of "$unit"' : 'unit "$unit"'}',
          source: table.locationOf(key),
          remedy: unitLevel
              ? 'a unit releases its projects under one $key — move it up to '
                    '[release.$unit]'
              : '${row ? 'a project' : 'a unit'} holds ${known.keys.join(', ')}',
        );
        continue;
      }
      if (_refusal(setting, table[key]) case final why?) {
        _diagnostics.add(
          'RK-CONF-005',
          '$key: $why',
          source: table.locationOf(key),
          remedy: [
            'as in ${setting.example.replaceAll('{unit}', unit)}',
            ?setting.hint,
          ].join('\n'),
        );
      }
    }
    return _diagnostics.found.length == before;
  }

  /// Why [value] is not one [setting] accepts, or null when it is.
  static String? _refusal(_Setting setting, Object? value) {
    switch (setting.shape) {
      case _Shape.rows:
        return value is TomlArray ? null : 'must be [[...]] rows';
      case _Shape.text:
        if (value is! String) return 'must be text';
        if (value.trim().isEmpty) return 'is empty';
        return setting.check?.call(value);
      case _Shape.texts:
        if (value is! List<String>) return 'must be a list of text';
        if (value.isEmpty && !setting.empty) return 'is empty';
        final seen = <String, String>{};
        for (final item in value) {
          if (setting.choices case final choices?
              when !choices.contains(item)) {
            return '"$item" is not one of ${choices.join(', ')}';
          }
          if (setting.check?.call(item) case final why?) return why;
          if (setting.sameAs case final same?) {
            if (seen[same(item)] case final first?) {
              return first == item
                  ? '"$item" is listed twice'
                  : '"$first" and "$item" would be published under one name';
            }
            seen[same(item)] = item;
          }
        }
        return null;
    }
  }

  /// RK-CONF-009: what a unit's settings require of one another.
  void _checkRules(UnitConfig unit, TomlTable table) {
    final name = unit.name;
    final targets = unit.publish;
    if (unit.tagPattern != null && !targets.contains(PublishTarget.gitTag)) {
      _rule(
        table.locationOf('tag'),
        'unit "$name" declares a tag but does not publish a Git tag',
        'add "git-tag" to publish, or remove tag',
      );
    }
    for (final target in targets) {
      for (final prerequisite in target.prerequisites.difference(targets)) {
        _rule(
          table.locationOf('publish'),
          '${target.configName} needs ${prerequisite.configName}',
          'add "${prerequisite.configName}", or drop "${target.configName}"\n'
              'Run rk target ${target.configName} for its requirements.',
        );
      }
    }
    if (unit.projects.length > 1 &&
        targets.contains(PublishTarget.gitTag) &&
        unit.tagPattern == null) {
      _rule(
        unit.location,
        'unit "$name" releases several projects, so its tag cannot be derived',
        'a set of packages has no canonical name — declare one, as in '
            'tag = "$name-v{version}"',
      );
    }
    final building = unit.projects.where((project) => project.buildsAssets);
    if (building.isNotEmpty && !targets.contains(PublishTarget.githubRelease)) {
      _rule(
        building.first.location,
        'unit "$name" builds release assets but does not publish a GitHub '
            'release',
        'add "github-release" and "git-tag" to its publish list: the '
            'assets are published as that release',
      );
    }
    if (targets.isEmpty &&
        unit.projects.every(
          (project) => project.publish.isEmpty && !project.wantsBinaries,
        )) {
      _rule(
        unit.location,
        'unit "$name" selects no release output',
        'add a publish target or binary_platforms',
      );
    }
    final homebrew = [
      for (final project in unit.projects)
        if (project.publish.contains(PublishTarget.homebrew)) project,
    ];
    for (final prerequisite
        in homebrew.isEmpty
            ? const <PublishTarget>{}
            : PublishTarget.homebrew.prerequisites.difference(targets)) {
      _rule(
        homebrew.first.location,
        'homebrew needs ${prerequisite.configName}',
        'add "${prerequisite.configName}" and its prerequisites to the unit '
            'publish list, or drop "homebrew"\n'
            'Run rk target homebrew for a complete example.',
      );
    }
    for (final project in homebrew) {
      if (project.wantsBinaries) continue;
      _rule(
        project.location,
        'a Homebrew project in "$name" names no binary platforms',
        'add binary_platforms, or drop "homebrew"\n'
            'Run rk target homebrew for supported values and an example.',
      );
    }
    if (homebrew.isEmpty && unit.homebrewTap != null) {
      _rule(
        table.locationOf('homebrew_tap'),
        'unit "$name" declares homebrew_tap but does not publish to homebrew',
        'add "homebrew" to its publish list, or remove homebrew_tap',
      );
    }
  }

  /// RK-CONF-009, for several tagged units: each names its tag, or a unit
  /// added later would change the tags the others already have.
  void _checkTags(List<UnitConfig> units) {
    final tagged = [
      for (final unit in units)
        if (unit.publish.contains(PublishTarget.gitTag)) unit,
    ];
    if (tagged.length < 2) return;
    for (final unit in tagged.where((unit) => unit.tagPattern == null)) {
      _rule(
        unit.location,
        'unit "${unit.name}" needs an explicit tag pattern',
        'this repository tags several units; declaring '
            'tag = "${unit.name}-v{version}" keeps this unit\'s public tag '
            'namespace stable if the repository changes again',
      );
    }
  }

  void _rule(SourceLocation at, String message, String remedy) =>
      _diagnostics.add('RK-CONF-009', message, source: at, remedy: remedy);

  /// The targets [table] publishes to, its names already checked.
  static Iterable<PublishTarget> _targets(TomlTable table) => [
    for (final name in table['publish'] as List<String>? ?? const <String>[])
      PublishTarget.named(name)!,
  ];

  static String _canonical(String path) {
    final parts = path
        .split('/')
        .where((p) => p.isNotEmpty && p != '.')
        .toList();
    return parts.isEmpty ? '.' : parts.join('/');
  }
}

String _itself(String item) => item;

String? _staysInside(String path) => path.startsWith('/') || path.contains('..')
    ? '"$path" leaves the repository; paths are relative to its root and '
          'stay inside it'
    : null;

String? _dottedField(String field) =>
    RegExp(
      r'^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*$',
    ).hasMatch(field)
    ? null
    : '"$field" is not a dotted pubspec field name';

String? _onlyOutPlaceholder(String argument) => argument.isEmpty
    ? 'an argument is empty'
    : argument.replaceAll('{out}', '').contains(RegExp(r'[{}]'))
    ? '"$argument" uses a placeholder rk does not have; {out}, the '
          'directory the build writes to, is the only one'
    : null;

String? _insideOutput(String asset) {
  final name = asset.split('/').last;
  if (relativeSegments(asset) == null) {
    return '"$asset" is not a file inside the build\'s output; name it '
        'relative to {out}, as in "assets/$name"';
  }
  if (name.toLowerCase() == 'release-manifest.json') {
    return '"$asset" would be published as $name, which is rk\'s own';
  }
  if (name.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
    return '"$asset" cannot be published under a name with a control '
        'character';
  }
  return null;
}

/// An asset is published under its file name, which GitHub compares
/// without case.
String _publishedName(String asset) => asset.split('/').last.toLowerCase();

String? _tagPattern(String pattern) {
  if ('{version}'.allMatches(pattern).length != 1) {
    return 'must contain {version} exactly once';
  }
  if (pattern.replaceAll('{version}', '').contains('{')) {
    return 'uses a placeholder rk does not have; {version} is the only one, '
        'and the rest is literal text';
  }
  // What git is handed is the pattern with a version in it, so that is what
  // is checked; every version rk accepts is itself ref-safe.
  final issue = refNameIssue(pattern.replaceAll('{version}', '0.0.0'));
  return issue == null
      ? null
      : 'git will not accept it: $issue; a tag is a git ref, so its name '
            'follows git\'s rules';
}

String? _githubCoordinate(String tap) =>
    RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$').hasMatch(tap) &&
        !tap.split('/').any((part) => part == '.' || part == '..')
    ? null
    : 'must be a GitHub owner/repository';
