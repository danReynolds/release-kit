/// A structured finding, carrying a stable code as its prose improves — every
/// one of them indexed in `doc/codes.md`, which `test/codes_index_test.dart`
/// keeps current. Its destination decides severity: problems block, warnings
/// do not.
///
/// Codes are `RK-<AREA>-<NNN>`, additive, and never reused for a different
/// meaning. The code is secondary in output: a reader wants the sentence and
/// the remediation.
class Diagnostic {
  const Diagnostic({
    required this.code,
    required this.message,
    this.source,
    this.remedy,
    this.evidence,
  });

  final String code;

  /// One sentence stating what is wrong, in the user's terms.
  final String message;

  /// Where the problem is, when it has a location.
  final SourceLocation? source;

  /// What to do about it, concretely.
  final String? remedy;

  /// The whole of what a native tool said, when a tool is what failed.
  ///
  /// [message] and [remedy] are what a person reads; this is what they read
  /// next, and rk is its last holder — nothing downstream can reproduce a
  /// compile that already happened. The report files it beside the document
  /// and names it on this finding, so the two correlate.
  final String? evidence;

  @override
  String toString() {
    final where = source == null ? '' : ' at $source';
    return '$code$where: $message';
  }
}

/// A position in a file, one-based, for pointing a reader at a problem.
class SourceLocation {
  const SourceLocation(this.path, [this.line]);

  final String path;
  final int? line;

  @override
  String toString() => line == null ? path : '$path:$line';
}

/// Collects problems so a caller can report all of them at once.
class Diagnostics {
  final List<Diagnostic> _found = [];

  bool get isEmpty => _found.isEmpty;
  bool get isNotEmpty => _found.isNotEmpty;
  List<Diagnostic> get found => List.unmodifiable(_found);

  /// A diagnostic built elsewhere — the guards return them ready-made.
  void report(Diagnostic diagnostic) => _found.add(diagnostic);

  void add(
    String code,
    String message, {
    SourceLocation? source,
    String? remedy,
  }) {
    _found.add(
      Diagnostic(code: code, message: message, source: source, remedy: remedy),
    );
  }
}
