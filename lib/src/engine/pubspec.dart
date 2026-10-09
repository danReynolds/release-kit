import 'package:pub_semver/pub_semver.dart' as pub;

import 'diagnostic.dart';
import 'version.dart';
import 'yaml.dart';

/// The native facts rk reads from a pubspec, and nothing else.
///
/// Everything here is owned by the manifest, never restated in `release.toml`:
/// what the package is called, what version it is at, whether it may be
/// published at all, and what it depends on.
class Pubspec {
  Pubspec({
    required this.path,
    required this.name,
    required this.version,
    required this.publishTo,
    required this.repository,
    required this.sdkConstraint,
    required this.executables,
    required this.dependencies,
    required this.devDependencies,
    required this.workspace,
    required this.nameLine,
    required this.versionLine,
    YamlMap? nativeFields,
  }) : _nativeFields = nativeFields;

  /// Repository-relative path of the manifest itself.
  final String path;
  final YamlMap? _nativeFields;

  String? stringAt(String path) {
    final parts = path.split('.');
    var map = _nativeFields;
    for (final part in parts.take(parts.length - 1)) {
      map = map?.map(part);
    }
    return map?.string(parts.last);
  }

  final String name;

  /// Null for a workspace root or any manifest that declares no version.
  final Version? version;

  /// The `publish_to` value, where `none` vetoes registry publication.
  final String? publishTo;

  /// The package's native project identity, when its pubspec declares one.
  final String? repository;

  final String? sdkConstraint;

  /// Executable names, which say `dart pub global activate` works — not that
  /// the package wants a signed binary shipped.
  final List<String> executables;

  /// Native command-to-bin-script mapping. A null value means the same name.
  Map<String, String> get executableScripts {
    final result = <String, String>{};
    for (final command in executables) {
      final node = _nativeFields?.map('executables')?[command];
      final value = node is YamlScalar ? node.value : null;
      if (node != null &&
          node is! YamlScalar &&
          !(node is YamlMap && node.entries.isEmpty)) {
        throw FormatException(
          'Executable $command must name a bin script or be null.',
        );
      }
      result[command] =
          value == null ||
              value.isEmpty ||
              (node is YamlScalar &&
                  !node.quoted &&
                  const {'null', 'Null', 'NULL', '~'}.contains(value))
          ? command
          : value;
    }
    return result;
  }

  /// Dependency name to how it is required.
  final Map<String, Dependency> dependencies;
  final Map<String, Dependency> devDependencies;

  /// Members listed by a workspace root.
  final List<String> workspace;

  final int nameLine;
  final int versionLine;

  bool get isWorkspaceRoot => workspace.isNotEmpty;
  bool get vetoesRegistry => publishTo == 'none';
  bool get declaresPubDev =>
      publishTo == null || isPubDevDestination(publishTo!);

  /// The native publication endpoint after repository and ambient Dart
  /// configuration are applied. Kept out of reports because URLs may carry
  /// credentials; the pub.dev target's readiness check compares it with its
  /// endpoint (`RK-PUB-009`).
  String effectivePublishDestination(Map<String, String> environment) =>
      canonicalPublishDestination(
        publishTo ?? environment['PUB_HOSTED_URL'] ?? 'https://pub.dev',
      );

  /// Repository-relative directory holding this manifest.
  String get directory {
    final cut = path.lastIndexOf('/');
    return cut < 0 ? '.' : path.substring(0, cut);
  }

  static Pubspec? parse(String source, String path, Diagnostics diagnostics) {
    final doc = parseYaml(source, path, diagnostics);
    if (doc == null) return null;

    final name = doc.string('name');
    if (name == null || name.isEmpty) {
      diagnostics.add(
        'RK-PKG-001',
        'this manifest declares no package name',
        source: SourceLocation(path, 1),
        remedy: 'every pubspec needs a name',
      );
      return null;
    }

    Version? version;
    final rawVersion = doc.string('version');
    if (rawVersion != null && rawVersion.isNotEmpty) {
      version = Version.parseOr(
        rawVersion,
        diagnostics,
        code: 'RK-PKG-002',
        describe: 'the version of "$name"',
        source: SourceLocation(path, doc.lineOf('version')),
      );
      if (version == null) return null;
    }

    return Pubspec(
      path: path,
      nativeFields: doc,
      name: name,
      version: version,
      publishTo: doc.string('publish_to'),
      repository: doc.string('repository'),
      sdkConstraint: doc.map('environment')?.string('sdk'),
      executables: doc.map('executables')?.keys.toList() ?? const [],
      dependencies: _dependencies(doc.map('dependencies')),
      devDependencies: _dependencies(doc.map('dev_dependencies')),
      workspace: doc.list('workspace')?.strings ?? const [],
      nameLine: doc.lineOf('name'),
      versionLine: doc.lineOf('version'),
    );
  }

  static Map<String, Dependency> _dependencies(YamlMap? table) {
    if (table == null) return const {};
    final result = <String, Dependency>{};
    for (final name in table.keys) {
      final nested = table.map(name);
      if (nested == null) {
        result[name] = Dependency.hosted(
          _constraint(table[name]),
          table.lineOf(name),
        );
        continue;
      }
      final path = nested.string('path');
      if (path != null) {
        result[name] = Dependency.path(path, table.lineOf(name));
        continue;
      }
      if (nested.has('git')) {
        result[name] = Dependency.git(table.lineOf(name));
        continue;
      }
      if (nested.string('sdk') case final sdk?) {
        result[name] = Dependency.sdk(sdk, table.lineOf(name));
        continue;
      }
      // A hosted dependency written the long way.
      result[name] = Dependency.hosted(
        _constraint(nested['version']),
        table.lineOf(name),
        hostedUrl:
            nested.string('hosted') ?? nested.map('hosted')?.string('url'),
      );
    }
    return result;
  }

  /// A version constraint as Pub reads it: a bare name, `~` and `null`
  /// are YAML's null, which allows any version. A quoted empty string is
  /// kept for Pub to refuse.
  static String _constraint(YamlNode? node) =>
      node is YamlScalar && (node.value.isNotEmpty || node.quoted)
      ? node.value
      : 'any';
}

String canonicalPublishDestination(String value) {
  final trimmed = value.trim();
  final uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return trimmed;
  final path = uri.path == '/' ? '' : uri.path.replaceFirst(RegExp(r'/+$'), '');
  return uri
      .replace(
        scheme: uri.scheme.toLowerCase(),
        host: uri.host.toLowerCase(),
        path: path,
      )
      .toString();
}

bool isPubDevDestination(String value) {
  final uri = Uri.tryParse(canonicalPublishDestination(value));
  return uri != null &&
      uri.scheme == 'https' &&
      uri.host == 'pub.dev' &&
      (uri.port == 0 || uri.port == 443) &&
      uri.userInfo.isEmpty &&
      uri.path.isEmpty &&
      !uri.hasQuery &&
      !uri.hasFragment;
}

enum DependencyKind { hosted, path, git, sdk }

/// How one package requires another. A path or git dependency is what makes a
/// project non-hermetic: its bytes come from somewhere the release does not
/// describe.
class Dependency {
  const Dependency._(
    this.kind,
    this.constraint,
    this.location,
    this.line, [
    this.hostedUrl,
  ]);

  const Dependency.hosted(String constraint, int line, {String? hostedUrl})
    : this._(DependencyKind.hosted, constraint, null, line, hostedUrl);

  const Dependency.path(String location, int line)
    : this._(DependencyKind.path, null, location, line);

  const Dependency.git(int line) : this._(DependencyKind.git, null, null, line);
  const Dependency.sdk(String sdk, int line)
    : this._(DependencyKind.sdk, null, sdk, line);

  final DependencyKind kind;

  /// The version constraint, for a hosted dependency.
  final String? constraint;

  /// The directory, for a path dependency.
  final String? location;
  final String? hostedUrl;

  final int line;

  /// Whether this dependency's bytes come from outside the repository's own
  /// history, which is what makes a project impossible to release
  /// reproducibly.
  bool get escapesRepository =>
      kind == DependencyKind.path || kind == DependencyKind.git;

  /// How the requirement reads, for a message about it.
  String describeRequirement() => switch (kind) {
    DependencyKind.hosted => constraint ?? 'any version',
    DependencyKind.path => 'a directory at $location',
    DependencyKind.git => 'a git repository',
    DependencyKind.sdk => 'the $location SDK',
  };

  /// Whether [version] satisfies this dependency's constraint.
  ///
  /// Uses Pub's native version semantics, including ranges and prereleases.
  /// Malformed syntax and non-hosted sources remain unknown.
  bool? satisfiedBy(Version version) {
    if (kind != DependencyKind.hosted) return null;
    final text = constraint?.trim();
    if (text == null || text.isEmpty) return null;
    try {
      return pub.VersionConstraint.parse(
        text,
      ).allows(pub.Version.parse(version.canonical));
    } on FormatException {
      return null;
    }
  }
}
