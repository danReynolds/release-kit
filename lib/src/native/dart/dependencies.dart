import 'dart:convert';

import '../../engine/diagnostic.dart';
import '../../engine/native_dependencies.dart';
import '../../engine/pubspec.dart';
import '../../engine/resolve.dart';
import '../../transforms/digest.dart';
import 'version_constraints.dart';

/// Dart's native compatibility and dependency kinds. Core sees opaque versions,
/// source identities, constraints and adapter-assigned installation slots.
final class DartDependencySemantics implements NativeDependencySemantics {
  const DartDependencySemantics();

  @override
  bool accepts(NativeRequirement requirement, NativeCandidate candidate) =>
      requirement.package == candidate.package &&
      dartConstraintAllows(requirement.constraint, candidate.version);
}

String dartRegistryIdentity(String registry) {
  final canonical = canonicalPublishDestination(registry);
  final normalized = canonical == 'https://pub.dartlang.org'
      ? 'https://pub.dev'
      : canonical;
  return 'hosted:${Sha256.hex(utf8.encode(normalized))}';
}

/// Canonical, credential-free registry for isolated native preparation.
String dartHostedRegistry(String value) {
  final canonical = canonicalPublishDestination(value);
  final normalized = canonical == 'https://pub.dartlang.org'
      ? 'https://pub.dev'
      : canonical;
  final uri = Uri.tryParse(normalized);
  if (uri == null ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.scheme != 'https' &&
          !(uri.scheme == 'http' &&
              const {'127.0.0.1', 'localhost', '::1'}.contains(uri.host)))) {
    throw const FormatException(
      'unsupported or credential-bearing native registry URL',
    );
  }
  return uri.toString().replaceFirst(RegExp(r'/$'), '');
}

NativeCandidate dartCandidate(
  ResolvedProject project, {
  String defaultRegistry = 'https://pub.dev',
}) => NativeCandidate(
  package: NativePackage(
    ecosystem: 'dart',
    source: dartRegistryIdentity(project.pubspec.publishTo ?? defaultRegistry),
    name: project.name,
  ),
  version: project.version.canonical,
  unit: project.unitName,
  project: project.name,
  producer: 'pub-archive:${project.name}',
);

List<NativeRequirement> dartRequirements(
  ResolvedProject project, {
  String? context,
  String defaultRegistry = 'https://pub.dev',
  bool publicPackage = true,
}) {
  final manifest = project.pubspec;
  final result = <NativeRequirement>[];
  void add(
    String name,
    Dependency dependency,
    String kind,
    Set<DependencyPhase> phases,
  ) {
    // SDK, Git and path inputs do not match hosted release candidates. Their
    // native handling/refusal remains separate from package artifact selection.
    if (dependency.kind != DependencyKind.hosted || phases.isEmpty) return;
    final constraint = dependency.constraint ?? 'any';
    final requirement = NativeRequirement(
      context: context ?? project.name,
      owner: project.name,
      slot: name,
      consumer: project.name,
      package: NativePackage(
        ecosystem: 'dart',
        source: dartRegistryIdentity(dependency.hostedUrl ?? defaultRegistry),
        name: name,
      ),
      constraint: constraint,
      kind: kind,
      location: SourceLocation(manifest.path, dependency.line),
      phases: phases,
    );
    try {
      validateDartConstraint(constraint);
    } on FormatException catch (error) {
      throw InvalidNativeRequirement(requirement, '$error');
    }
    result.add(requirement);
  }

  manifest.dependencies.forEach(
    (name, dependency) => add(name, dependency, 'runtime', {
      // Pub's root dev requirement takes precedence for private preparation.
      // The published runtime requirement still describes ordinary consumers.
      if (!manifest.devDependencies.containsKey(name))
        DependencyPhase.preparation,
      if (publicPackage) DependencyPhase.publication,
    }),
  );
  manifest.devDependencies.forEach(
    (name, dependency) =>
        add(name, dependency, 'development', {DependencyPhase.preparation}),
  );
  return List.unmodifiable(result);
}
