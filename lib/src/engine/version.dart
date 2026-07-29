import 'diagnostic.dart';

/// A version under the frozen grammar: SemVer 2.0.0 over Dart's
/// three-component form.
///
/// The canonical string — including build metadata — is coordinate identity.
/// SemVer precedence does not make two different coordinate strings the same
/// coordinate, so [compareTo] orders versions while [canonical] identifies
/// them.
class Version implements Comparable<Version> {
  Version._({
    required this.major,
    required this.minor,
    required this.patch,
    required this.prerelease,
    required this.build,
    required this.canonical,
  });

  final int major;
  final int minor;
  final int patch;

  /// Dot-separated prerelease identifiers, empty when there are none.
  final List<String> prerelease;

  /// Dot-separated build identifiers, empty when there are none. Build
  /// metadata is part of identity but not of precedence.
  final List<String> build;

  /// The exact string this version was parsed from, which must already have
  /// been canonical.
  final String canonical;

  bool get isPrerelease => prerelease.isNotEmpty;

  /// Parses [input], or returns null if it is not canonical under the grammar.
  ///
  /// Rejected rather than normalized: whitespace, a leading `v`, omitted
  /// components, and leading zeros in a numeric component.
  static Version? tryParse(String input) {
    if (input.isEmpty || input != input.trim()) return null;

    var rest = input;
    List<String> build = const [];
    final plus = rest.indexOf('+');
    if (plus >= 0) {
      final raw = rest.substring(plus + 1);
      rest = rest.substring(0, plus);
      build = raw.split('.');
      if (build.any((id) => !_isBuildIdentifier(id))) return null;
    }

    List<String> prerelease = const [];
    final dash = rest.indexOf('-');
    if (dash >= 0) {
      final raw = rest.substring(dash + 1);
      rest = rest.substring(0, dash);
      prerelease = raw.split('.');
      if (prerelease.any((id) => !_isPrereleaseIdentifier(id))) return null;
    }

    final parts = rest.split('.');
    if (parts.length != 3) return null;
    final numbers = <int>[];
    for (final part in parts) {
      final value = _parseNumeric(part);
      if (value == null) return null;
      numbers.add(value);
    }

    return Version._(
      major: numbers[0],
      minor: numbers[1],
      patch: numbers[2],
      prerelease: List.unmodifiable(prerelease),
      build: List.unmodifiable(build),
      canonical: input,
    );
  }

  /// Parses [input] or records why it could not be, under [code].
  static Version? parseOr(
    String input,
    Diagnostics diagnostics, {
    required String code,
    required String describe,
    SourceLocation? source,
  }) {
    final version = tryParse(input);
    if (version != null) return version;
    diagnostics.add(
      code,
      '$describe is not a valid version: "$input"',
      source: source,
      remedy: 'use major.minor.patch, such as 1.2.3, with no leading "v" '
          'and no leading zeros',
    );
    return null;
  }

  /// A decimal component with no leading zero unless it is exactly `0`.
  static int? _parseNumeric(String part) {
    if (part.isEmpty) return null;
    for (final unit in part.codeUnits) {
      if (unit < 0x30 || unit > 0x39) return null;
    }
    if (part.length > 1 && part.startsWith('0')) return null;
    return int.parse(part);
  }

  static bool _isBuildIdentifier(String id) =>
      id.isNotEmpty && id.codeUnits.every(_isIdentifierChar);

  static bool _isPrereleaseIdentifier(String id) {
    if (id.isEmpty) return false;
    if (!id.codeUnits.every(_isIdentifierChar)) return false;
    // A purely numeric identifier is compared numerically, so it may not
    // carry a leading zero.
    final numeric = id.codeUnits.every((u) => u >= 0x30 && u <= 0x39);
    if (numeric && id.length > 1 && id.startsWith('0')) return false;
    return true;
  }

  static bool _isIdentifierChar(int unit) =>
      (unit >= 0x30 && unit <= 0x39) || // 0-9
      (unit >= 0x41 && unit <= 0x5a) || // A-Z
      (unit >= 0x61 && unit <= 0x7a) || // a-z
      unit == 0x2d; // -

  /// SemVer precedence. Build metadata is ignored, per the spec.
  @override
  int compareTo(Version other) {
    var result = major.compareTo(other.major);
    if (result != 0) return result;
    result = minor.compareTo(other.minor);
    if (result != 0) return result;
    result = patch.compareTo(other.patch);
    if (result != 0) return result;

    // A prerelease has lower precedence than the release it precedes.
    if (prerelease.isEmpty && other.prerelease.isEmpty) return 0;
    if (prerelease.isEmpty) return 1;
    if (other.prerelease.isEmpty) return -1;

    for (var i = 0; i < prerelease.length && i < other.prerelease.length; i++) {
      result = _compareIdentifiers(prerelease[i], other.prerelease[i]);
      if (result != 0) return result;
    }
    return prerelease.length.compareTo(other.prerelease.length);
  }

  static int _compareIdentifiers(String a, String b) {
    final aNumeric = a.codeUnits.every((u) => u >= 0x30 && u <= 0x39);
    final bNumeric = b.codeUnits.every((u) => u >= 0x30 && u <= 0x39);
    if (aNumeric && bNumeric) return int.parse(a).compareTo(int.parse(b));
    // Numeric identifiers always have lower precedence than alphanumeric.
    if (aNumeric) return -1;
    if (bNumeric) return 1;
    return a.compareTo(b);
  }

  bool operator >(Version other) => compareTo(other) > 0;
  bool operator <(Version other) => compareTo(other) < 0;
  bool operator >=(Version other) => compareTo(other) >= 0;
  bool operator <=(Version other) => compareTo(other) <= 0;

  /// Coordinate identity: the exact string, not precedence.
  @override
  bool operator ==(Object other) =>
      other is Version && other.canonical == canonical;

  @override
  int get hashCode => canonical.hashCode;

  @override
  String toString() => canonical;
}
