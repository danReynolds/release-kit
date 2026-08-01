/// What inspecting a coordinate told rk.
///
/// `unknown` is never collapsed into `absent`: concluding "not there" from a
/// timeout is how a tool publishes something twice.
enum Verdict {
  /// Nothing is there. Concluded only from a definitive provider negative.
  absent,

  /// What is there is what this release would put there.
  exact,

  /// Something else is there.
  conflict,

  /// rk could not tell.
  unknown,
}

/// The result of an inspection, carrying why as well as what.
class Inspection {
  const Inspection(
    this.verdict, {
    this.detail,
    this.evidence = const {},
  });

  const Inspection.absent({String? detail})
      : this(Verdict.absent, detail: detail);

  const Inspection.exact({String? detail})
      : this(Verdict.exact, detail: detail);

  const Inspection.conflict(String detail,
      {Map<String, String> evidence = const {}})
      : this(Verdict.conflict, detail: detail, evidence: evidence);

  /// rk could not determine the state.
  const Inspection.unknown(String detail)
      : this(Verdict.unknown, detail: detail);

  final Verdict verdict;

  /// One line saying what rk saw.
  final String? detail;

  /// What a conflict differs on, so a human is given the evidence rather than
  /// the fact of a difference.
  final Map<String, String> evidence;

  bool get isAbsent => verdict == Verdict.absent;
  bool get isExact => verdict == Verdict.exact;
}
