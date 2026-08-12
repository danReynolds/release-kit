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
    required this.sdkConstraint,
    required this.executables,
    required this.dependencies,
    required this.devDependencies,
    required this.workspace,
    required this.nameLine,
    required this.versionLine,
  });

  /// Repository-relative path of the manifest itself.
  final String path;

  final String name;

  /// Null for a workspace root or any manifest that declares no version.
  final Version? version;

  /// The `publish_to` value, where `none` vetoes registry publication.
  final String? publishTo;

  final String? sdkConstraint;

  /// Executable names, which say `dart pub global activate` works — not that
  /// the package wants a signed binary shipped.
  final List<String> executables;

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
  /// credentials; stage identity hashes it and release compares it opaquely.
  String effectivePublishDestination(Map<String, String> environment) =>
      canonicalPublishDestination(
        publishTo ?? environment['PUB_HOSTED_URL'] ?? 'https://pub.dev',
      );

  /// Repository-relative directory holding this manifest.
  String get directory {
    final cut = path.lastIndexOf('/');
    return cut < 0 ? '.' : path.substring(0, cut);
  }

  static Pubspec? parse(
    String source,
    String path,
    Diagnostics diagnostics,
  ) {
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
      name: name,
      version: version,
      publishTo: doc.string('publish_to'),
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
      final scalar = table.string(name);
      if (scalar != null) {
        result[name] = Dependency.hosted(scalar, table.lineOf(name));
        continue;
      }
      final nested = table.map(name);
      if (nested == null) {
        // A bare name with no constraint means "any version".
        result[name] = Dependency.hosted('any', table.lineOf(name));
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
      // A hosted dependency written the long way.
      result[name] = Dependency.hosted(
        nested.string('version') ?? 'any',
        table.lineOf(name),
      );
    }
    return result;
  }
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

enum DependencyKind { hosted, path, git }

/// How one package requires another. A path or git dependency is what makes a
/// project non-hermetic: its bytes come from somewhere the release does not
/// describe.
class Dependency {
  const Dependency._(this.kind, this.constraint, this.location, this.line);

  const Dependency.hosted(String constraint, int line)
      : this._(DependencyKind.hosted, constraint, null, line);

  const Dependency.path(String location, int line)
      : this._(DependencyKind.path, null, location, line);

  const Dependency.git(int line) : this._(DependencyKind.git, null, null, line);

  final DependencyKind kind;

  /// The version constraint, for a hosted dependency.
  final String? constraint;

  /// The directory, for a path dependency.
  final String? location;

  final int line;

  /// Whether this dependency's bytes come from outside the repository's own
  /// history, which is what makes a project impossible to release
  /// reproducibly.
  bool get escapesRepository => kind != DependencyKind.hosted;

  /// How the requirement reads, for a message about it.
  String describeRequirement() => switch (kind) {
        DependencyKind.hosted => constraint ?? 'any version',
        DependencyKind.path => 'a directory at $location',
        DependencyKind.git => 'a git repository',
      };

  /// Whether [version] satisfies this dependency's constraint.
  ///
  /// Supports the constraint forms a first-party dependency is written with:
  /// `any`, an exact version, and a caret. Anything more elaborate is reported
  /// as unknown rather than guessed at.
  bool? satisfiedBy(Version version) {
    final text = constraint?.trim();
    if (text == null || text.isEmpty) return null;
    if (text == 'any') return true;

    if (text.startsWith('^')) {
      final base = Version.tryParse(text.substring(1));
      if (base == null) return null;
      if (version < base) return false;
      // Caret allows up to the next breaking version, where a leading zero
      // makes the first non-zero component the breaking one.
      if (base.major > 0) return version.major == base.major;
      if (base.minor > 0) {
        return version.major == 0 && version.minor == base.minor;
      }
      return version.major == 0 && version.minor == 0;
    }

    final exact = Version.tryParse(text);
    if (exact != null) return version == exact;
    return null;
  }
}
