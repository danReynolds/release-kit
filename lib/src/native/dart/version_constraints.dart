import 'package:pub_semver/pub_semver.dart' as pub;

/// Keep Pub semantics behind the native boundary. Other adapters can use their
/// own constraints without importing Dart version rules into shared machinery.
bool dartConstraintAllows(String constraint, String version) =>
    pub.VersionConstraint.parse(constraint).allows(pub.Version.parse(version));

void validateDartConstraint(String constraint) =>
    pub.VersionConstraint.parse(constraint);
