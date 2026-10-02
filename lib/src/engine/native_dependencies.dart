import 'diagnostic.dart';

/// Native identities are opaque to scheduling. Source is a credential-free
/// adapter identity, not a URL that core should fetch or interpret.
final class NativePackage {
  const NativePackage({
    required this.ecosystem,
    required this.source,
    required this.name,
  });

  final String ecosystem;
  final String source;
  final String name;

  @override
  bool operator ==(Object other) =>
      other is NativePackage &&
      other.ecosystem == ecosystem &&
      other.source == source &&
      other.name == name;

  @override
  int get hashCode => Object.hash(ecosystem, source, name);

  Map<String, Object?> toJson() => {
    'ecosystem': ecosystem,
    'source': source,
    'name': name,
  };
}

enum DependencyPhase { preparation, publication }

/// One occurrence in a native resolution context. [slot] is adapter-owned:
/// Dart uses one slot per name; another ecosystem may install two occurrences
/// at different versions. Core never merges them just because names match.
final class NativeRequirement {
  NativeRequirement({
    required this.context,
    required this.owner,
    required this.slot,
    required this.consumer,
    required this.package,
    required this.constraint,
    required this.kind,
    required this.location,
    required Iterable<DependencyPhase> phases,
  }) : phases = Set.unmodifiable(phases);

  final String context;

  /// The configured root whose producer consumes this entire native context.
  /// This remains the app for app -> hosted bridge -> staged core.
  final String owner;
  final String slot;
  final String consumer;
  final NativePackage package;
  final String constraint;
  final String kind;
  final SourceLocation location;
  final Set<DependencyPhase> phases;

  Map<String, Object?> toJson() => {
    'context': context,
    'owner': owner,
    'slot': slot,
    'consumer': consumer,
    'package': package.toJson(),
    'constraint': constraint,
    'kind': kind,
    'location': {'path': location.path, 'line': location.line},
    'phases': [
      for (final phase in DependencyPhase.values)
        if (phases.contains(phase)) phase.name,
    ],
  };
}

final class InvalidNativeRequirement implements Exception {
  const InvalidNativeRequirement(this.requirement, this.detail);
  final NativeRequirement requirement;
  final String detail;
}

/// A configured provider, not proof that a package has been built or published.
final class NativeCandidate {
  const NativeCandidate({
    required this.package,
    required this.version,
    required this.unit,
    required this.project,
    required this.producer,
  });

  final NativePackage package;
  final String version;
  final String unit;
  final String project;
  final String producer;

  Map<String, Object?> toJson() => {
    'package': package.toJson(),
    'version': version,
    'unit': unit,
    'project': project,
    'producer': producer,
  };
}

abstract interface class NativeDependencySemantics {
  bool accepts(NativeRequirement requirement, NativeCandidate candidate);
}

/// A source-only choice. A null candidate means native resolution is still
/// required, never that a compatible public version is known to exist.
final class NativeCandidateSelection {
  NativeCandidateSelection._(this.requirements, this.candidate);
  final List<NativeRequirement> requirements;
  final NativeCandidate? candidate;

  Map<String, Object?> toJson() => {
    'requirements': [
      for (final requirement in requirements) requirement.toJson(),
    ],
    'candidate': candidate?.toJson(),
    'resolution': candidate == null
        ? 'native_resolution_required'
        : 'candidate_requires_native_validation',
  };
}

/// Select only among the caller's eligible scope. Compatibility is conjunctive
/// across all incoming requirements sharing the native context and slot.
/// Native solving still validates the entire resulting graph afterward.
List<NativeCandidateSelection> selectNativeCandidates({
  required Iterable<NativeRequirement> requirements,
  required Iterable<NativeCandidate> candidates,
  required NativeDependencySemantics semantics,
  required DependencyPhase phase,
}) {
  final groups = <(String, String), List<NativeRequirement>>{};
  for (final requirement in requirements) {
    if (!requirement.phases.contains(phase)) continue;
    (groups[(requirement.context, requirement.slot)] ??= []).add(requirement);
  }
  final available = candidates.toList();
  return List.unmodifiable([
    for (final group in groups.values)
      NativeCandidateSelection._(
        List.unmodifiable(group),
        _candidateFor(group, available, semantics),
      ),
  ]);
}

NativeCandidate? _candidateFor(
  List<NativeRequirement> requirements,
  List<NativeCandidate> candidates,
  NativeDependencySemantics semantics,
) {
  final matches = candidates
      .where(
        (candidate) => requirements.every(
          (requirement) =>
              requirement.package == candidate.package &&
              semantics.accepts(requirement, candidate),
        ),
      )
      .toList();
  if (matches.length > 1) {
    throw StateError(
      'multiple configured providers satisfy native slot ${requirements.first.context}/${requirements.first.slot}',
    );
  }
  return matches.singleOrNull;
}
