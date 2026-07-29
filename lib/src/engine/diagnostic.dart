/// A blocking problem, carrying a stable code so it stays greppable as its
/// prose improves.
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
  });

  final String code;

  /// One sentence stating what is wrong, in the user's terms.
  final String message;

  /// Where the problem is, when it has a location.
  final SourceLocation? source;

  /// What to do about it, concretely.
  final String? remedy;

  @override
  String toString() {
    final where = source == null ? '' : ' at $source';
    return '$code$where: $message';
  }
}

/// A position in a file, one-based, for pointing a reader at a problem.
class SourceLocation {
  const SourceLocation(this.path, [this.line, this.column]);

  final String path;
  final int? line;
  final int? column;

  @override
  String toString() {
    if (line == null) return path;
    if (column == null) return '$path:$line';
    return '$path:$line:$column';
  }
}

/// Thrown when rk refuses. Carries every problem found in one pass, so a fix
/// cycle is one edit round rather than several.
class RkFailure implements Exception {
  RkFailure(this.diagnostics)
    : assert(diagnostics.isNotEmpty, 'a failure needs at least one problem');

  final List<Diagnostic> diagnostics;

  @override
  String toString() => diagnostics.map((d) => d.toString()).join('\n');
}

/// Collects problems so a caller can report all of them at once.
class Diagnostics {
  final List<Diagnostic> _found = [];

  bool get isEmpty => _found.isEmpty;
  bool get isNotEmpty => _found.isNotEmpty;
  List<Diagnostic> get found => List.unmodifiable(_found);

  void add(
    String code,
    String message, {
    SourceLocation? source,
    String? remedy,
  }) {
    _found.add(
      Diagnostic(
        code: code,
        message: message,
        source: source,
        remedy: remedy,
      ),
    );
  }

  /// Raises everything collected, or returns if nothing was found.
  void throwIfAny() {
    if (_found.isNotEmpty) throw RkFailure(found);
  }
}
