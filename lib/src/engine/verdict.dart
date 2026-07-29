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
    this.actedBefore = false,
  });

  const Inspection.absent({String? detail})
    : this(Verdict.absent, detail: detail);

  const Inspection.exact({String? detail})
    : this(Verdict.exact, detail: detail);

  const Inspection.conflict(String detail, {Map<String, String> evidence = const {}})
    : this(Verdict.conflict, detail: detail, evidence: evidence);

  /// rk could not determine the state.
  ///
  /// [actedBefore] separates the two shapes an operator must tell apart: rk
  /// never wrote and the world is unchanged, or rk wrote and lost the
  /// response, so the next run must classify what it finds.
  const Inspection.unknown(String detail, {bool actedBefore = false})
    : this(Verdict.unknown, detail: detail, actedBefore: actedBefore);

  final Verdict verdict;

  /// One line saying what rk saw.
  final String? detail;

  /// What a conflict differs on, so a human is given the evidence rather than
  /// the fact of a difference.
  final Map<String, String> evidence;

  final bool actedBefore;

  bool get isAbsent => verdict == Verdict.absent;
  bool get isExact => verdict == Verdict.exact;
  bool get halts => verdict == Verdict.conflict || verdict == Verdict.unknown;
}
