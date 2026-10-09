/// What inspecting a coordinate told rk.
///
/// `unknown` is never collapsed into `absent`: concluding "not there" from a
/// timeout is how a tool publishes something twice.
enum Verdict {
  /// The intended public state is not there. For a mutable channel, a
  /// recognized older value may be present and carry compare-and-swap
  /// authority for one forward update.
  absent,

  /// The target is complete under its reconciliation policy.
  ///
  /// Evidence distinguishes verified equality from an occupied append-only
  /// coordinate whose historical comparison is unavailable.
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
    this.authority,
    this.sourceMismatch,
    this.releasedFrom,
    this.recoversWithoutStage = false,
  });

  const Inspection.absent({
    String? detail,
    Map<String, String> evidence = const {},
    Object? authority,
  }) : this(
         Verdict.absent,
         detail: detail,
         evidence: evidence,
         authority: authority,
       );

  /// This observation, which can finish from public inputs alone.
  Inspection recovering({Object? authority}) => Inspection(
    verdict,
    detail: detail,
    evidence: evidence,
    authority: authority ?? this.authority,
    sourceMismatch: sourceMismatch,
    releasedFrom: releasedFrom,
    recoversWithoutStage: true,
  );

  const Inspection.exact({
    String? detail,
    Map<String, String> evidence = const {},
    Object? authority,
    String? releasedFrom,
  }) : this(
         Verdict.exact,
         detail: detail,
         evidence: evidence,
         authority: authority,
         releasedFrom: releasedFrom,
       );

  const Inspection.conflict(
    String detail, {
    Map<String, String> evidence = const {},
    Object? authority,
    SourceBindingMismatch? sourceMismatch,
  }) : this(
         Verdict.conflict,
         detail: detail,
         evidence: evidence,
         authority: authority,
         sourceMismatch: sourceMismatch,
       );

  /// rk could not determine the state.
  const Inspection.unknown(String detail, {String? releasedFrom})
    : this(Verdict.unknown, detail: detail, releasedFrom: releasedFrom);

  final Verdict verdict;

  /// One line saying what rk saw.
  final String? detail;

  /// Provider evidence supporting a complete answer, or the fields a conflict
  /// differs on, so callers receive the proof rather than only the verdict.
  final Map<String, String> evidence;

  /// Provider-owned authority for an act based on this exact observation.
  ///
  /// This is deliberately process-local rather than report data. An adapter
  /// may use it to prove that the public base it is about to mutate is still
  /// the one this inspection authorized.
  final Object? authority;

  /// A public release that is valid for an earlier source while the current
  /// source still declares the same version. This is typed because core must
  /// not recover release semantics by parsing a provider evidence map.
  final SourceBindingMismatch? sourceMismatch;

  /// The earlier commit a release tag names: exact when nothing the unit
  /// releases has changed since it, unknown when rk could not compare the
  /// two. Either way the version was released from there, not from this
  /// commit, so nothing this commit stages belongs under that tag. Typed for
  /// the same reason as [sourceMismatch].
  final String? releasedFrom;

  /// Whether the target can be published from authenticated public inputs
  /// once the local stage is gone, as a moving channel may: a formula
  /// rendered from the digests of a release already public. Typed for the
  /// same reason as [sourceMismatch].
  final bool recoversWithoutStage;

  bool get isAbsent => verdict == Verdict.absent;
  bool get isExact => verdict == Verdict.exact;
}

final class SourceBindingMismatch {
  const SourceBindingMismatch({
    required this.releasedCommit,
    required this.currentCommit,
  });

  final String releasedCommit;
  final String currentCommit;
}
