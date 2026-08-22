import 'verdict.dart';
import 'version.dart';

/// Provider-independent rules for reconciling public release state.
///
/// Adapters still own coordinates, network reads, native packaging, and acts.
/// This module owns only the two rules that must not drift between them:
/// versioned artifacts are append-only, and mutable channels move forward.
abstract final class PublicReconciliation {
  /// Reconciles one already-present append-only publication.
  ///
  /// Inventory is always comparable. Adapter-normalized proofs are compared
  /// wherever both sides provide one; a known mismatch blocks. Proof values
  /// are opaque, algorithm-qualified strings such as `sha256:…`, `sha512:…`,
  /// or `etag:…`. When every expected proof is comparable, the payload is
  /// verified. Otherwise the occupied coordinate still skips, without
  /// claiming byte provenance.
  static Inspection appendOnly({
    required String label,
    required Set<String> expected,
    required Set<String> published,
    Map<String, String> expectedProofs = const {},
    Map<String, String> publishedProofs = const {},
    String occupiedDetail = 'already published',
    String verifiedDetail = 'published payload matches the staged release',
  }) {
    final differences = <String, String>{};
    for (final name in expected.difference(published)) {
      differences[name] = 'missing';
    }
    for (final name in published.difference(expected)) {
      differences[name] = 'not expected';
    }

    for (final name in expected.intersection(published)) {
      final staged = expectedProofs[name];
      final remote = publishedProofs[name];
      if (staged != null && remote != null && staged != remote) {
        differences[name] = '$remote, expected $staged';
      }
    }
    if (differences.isNotEmpty) {
      return Inspection.conflict(
        '$label differs from the intended release',
        evidence: differences,
      );
    }

    final comparedAll = expected.isNotEmpty &&
        expected.every(
          (name) =>
              expectedProofs[name] != null && publishedProofs[name] != null,
        );
    if (comparedAll) {
      return Inspection.exact(
        detail: verifiedDetail,
        evidence: {
          'comparison': 'exact',
          for (final name in expected.toList()..sort())
            name: publishedProofs[name]!,
        },
      );
    }
    return Inspection.exact(
      detail: occupiedDetail,
      evidence: const {'comparison': 'unavailable'},
    );
  }

  /// Reconciles a present mutable channel against its intended release.
  ///
  /// [payloadMatches] is stronger than parsing and wins immediately. Any
  /// other public bytes must be recognizable to the adapter and carry one
  /// canonical version before a forward update can be authorized.
  static Inspection movingChannel({
    required String label,
    required Version intendedVersion,
    required Version? publishedVersion,
    required bool payloadMatches,
    required String publishedIdentity,
    required String unrecognizedDetail,
    required Object advanceAuthority,
  }) {
    if (payloadMatches) {
      return Inspection.exact(
        detail: '$label already points at ${intendedVersion.canonical}',
        evidence: {
          'version': intendedVersion.canonical,
          'identity': publishedIdentity,
        },
        authority: advanceAuthority,
      );
    }
    if (publishedVersion == null) {
      return Inspection.conflict(
        unrecognizedDetail,
        evidence: {'public identity': publishedIdentity},
      );
    }
    if (publishedVersion < intendedVersion) {
      return Inspection.absent(
        detail: '$label points at earlier version '
            '${publishedVersion.canonical}',
        evidence: {
          'version': publishedVersion.canonical,
          'public identity': publishedIdentity,
        },
        authority: advanceAuthority,
      );
    }
    if (publishedVersion == intendedVersion) {
      return Inspection.conflict(
        '$label has different bytes for ${intendedVersion.canonical}',
        evidence: {
          'version': publishedVersion.canonical,
          'public identity': publishedIdentity,
        },
      );
    }
    return Inspection.conflict(
      '$label is already at newer version ${publishedVersion.canonical}',
      evidence: {
        'version': publishedVersion.canonical,
        'public identity': publishedIdentity,
      },
    );
  }
}
