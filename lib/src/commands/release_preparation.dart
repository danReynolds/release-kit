import '../targets/target_module.dart';
import '../transforms/macos.dart';

/// The exact private inputs authorization and publication receive.
///
/// A reusable stage recovers the same signing identity from its receipt; a
/// newly prepared stage carries the identity selected before producers ran.
final class PreparedRelease {
  PreparedRelease({
    required Iterable<TargetClaim> claims,
    required this.signing,
  }) : claims = List.unmodifiable(claims);

  final List<TargetClaim> claims;

  final ReleaseSigningContext? signing;
}

/// Signing continuity frozen before stage production and recorded in it.
final class ReleaseSigningContext {
  const ReleaseSigningContext({
    required this.publishedRequirement,
    required this.firstIdentity,
    required this.certificateName,
    required this.codeId,
    this.identity,
    this.certificateSha256,
    this.designatedRequirement,
  });

  final String? publishedRequirement;
  final bool firstIdentity;
  final String certificateName;
  final String codeId;

  /// Present only while producing a new stage. Reuse needs recorded facts,
  /// not live keychain state.
  final SigningIdentity? identity;
  final String? certificateSha256;
  final String? designatedRequirement;

  String? get firstCertificate => firstIdentity ? certificateName : null;

  bool sameRecordedIdentity(ReleaseSigningContext other) =>
      publishedRequirement == other.publishedRequirement &&
      firstIdentity == other.firstIdentity &&
      certificateName == other.certificateName &&
      certificateSha256 == other.certificateSha256 &&
      designatedRequirement == other.designatedRequirement &&
      codeId == other.codeId;
}
