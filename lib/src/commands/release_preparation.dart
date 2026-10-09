import '../builds/macos_identity.dart';
import '../targets/target_module.dart';

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

  final MacIdentity? signing;
}
