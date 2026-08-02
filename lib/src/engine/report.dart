import 'dart:convert';

import 'diagnostic.dart';

/// The machine surface: what a run found, keyed by step id.
///
/// It is recorded by [Output] as it prints rather than assembled separately, so
/// the two surfaces cannot drift — a step a person is shown is a step a caller
/// is told about, because they are one call.
///
/// Stability is the contract. Field names and step ids are part of it, and a
/// caller that keys on them must keep working across rk versions, so nothing
/// here is derived from prose that might be reworded.
class Report {
  Report(this.command);

  /// The verb that ran, so a caller reading a captured document knows what it
  /// is looking at without being told out of band.
  final String command;

  /// Wire format version, bumped only when a key changes meaning.
  static const schema = 1;

  /// Units by name, in the order they were first mentioned.
  ///
  /// Keyed rather than "the one currently open": a step carries the name of its
  /// own unit, so looking it up cannot put a step under the wrong one, and no
  /// state has to survive between two calls for the document to come out right
  /// (CI readiness, seam 1).
  final Map<String, Map<String, Object?>> _units = {};
  final List<Map<String, Object?>> _problems = [];
  final List<String> _next = [];
  Map<String, Object?>? _repository;
  Map<String, Object?>? _halt;

  /// Whether running the same command again can do harm.
  ///
  /// Two questions, kept apart because conflating them made the flagship field
  /// wrong on the commonest halt: *is re-running safe* and *will re-running
  /// help* are different. rk's execution model — inspect, act, verify, with
  /// reality as the database — makes re-running safe in every case it has,
  /// including after a conflict, where a second run inspects and refuses
  /// again. What a conflict changes is that re-running will not fix it.
  var safeToRerun = true;

  /// Whether re-running would move the release forward.
  ///
  /// False after a halt that re-running cannot resolve — a conflict at a
  /// destination — so a caller can tell "try again" from "a human has to
  /// decide" without reading the sentence.
  var rerunHelps = true;

  /// Whether this run began changing things.
  ///
  /// The signal for whether a failure is worth recording evidence about. It is
  /// set by the act phase rather than inferred from whether a step was printed:
  /// inferring it meant no planned failure ever wrote a diagnosis, because the
  /// only path that printed steps was the offline one, which always succeeds.
  var acted = false;

  /// [uncommitted] is null when the run stopped before reading git, which is
  /// reported as absence rather than as zero — a clean tree and an unread one
  /// are different facts.
  void repository({required String name, String? branch, int? uncommitted}) {
    _repository = {
      'name': name,
      if (branch != null) 'branch': branch,
      if (uncommitted != null) 'uncommitted': uncommitted,
    };
  }

  /// Records what a unit releases. Steps name their own unit, so this may come
  /// before or after them.
  void unit({
    required String name,
    required String version,
    required String tag,
  }) {
    _entry(name)
      ..['version'] = version
      ..['tag'] = tag;
  }

  Map<String, Object?> _entry(String name) => _units.putIfAbsent(
        name,
        () => {'name': name, 'steps': <Map<String, Object?>>[]},
      );

  /// Records what `verify` proved (or could not) about one published subject
  /// of [unit] — a package at a version, later an asset.
  void verification(
    String unit,
    String subject, {
    required String verdict,
    String? id,
    String? detail,
    Map<String, String> evidence = const {},
    bool counts = true,
  }) {
    ((_entry(unit)['verifications'] ??= <Map<String, Object?>>[])
            as List<Map<String, Object?>>)
        .add({
      if (id != null) 'id': id,
      'subject': subject,
      'verdict': verdict,
      // False marks a disclosure: the subject was named as unexamined, not
      // judged. A caller folding verifications into pass/fail skips these —
      // they never claimed to be proofs.
      'counts': counts,
      if (detail != null) 'detail': detail,
      if (evidence.isNotEmpty) 'evidence': evidence,
    });
  }

  /// Records a step under its own unit, keyed by [id].
  /// [verdict] is always written, and defaults to `unknown` rather than to
  /// nothing. An omitted key invites a caller to read "no verdict" as "nothing
  /// is there", which is the one collapse rk must never make — `unknown` says
  /// rk could not tell, and that is a different instruction to a caller than
  /// `absent`.
  void step({
    required String id,
    required String unit,
    required String summary,
    String verdict = 'unknown',
    bool? permanent,
    bool? public,
    List<String> needs = const [],
    String? detail,
    Map<String, String> evidence = const {},
    Duration? took,
  }) {
    // Replace by id rather than append: a step is one fact, and recording it
    // twice — once at inspection, once after the act — gave a caller two
    // entries for one id in a document whose contract is "keyed on step id",
    // with the stale one first. The act's answer supersedes the inspection's.
    final steps = _entry(unit)['steps'] as List<Map<String, Object?>>;
    steps.removeWhere((s) => s['id'] == id);
    steps.add({
      'id': id,
      'summary': summary,
      'verdict': verdict,
      if (permanent != null) 'permanent': permanent,
      if (public != null) 'public': public,
      if (needs.isNotEmpty) 'needs': needs,
      if (detail != null) 'detail': detail,
      if (evidence.isNotEmpty) 'evidence': evidence,
      if (took != null) 'took_ms': took.inMilliseconds,
    });
  }

  void problem(Diagnostic diagnostic, {String? unit}) {
    _problems.add({
      if (unit != null) 'unit': unit,
      'code': diagnostic.code,
      'message': diagnostic.message,
      if (diagnostic.source != null) 'source': diagnostic.source.toString(),
      if (diagnostic.remedy != null) 'remedy': diagnostic.remedy,
    });
  }

  /// The command that would advance things, as data rather than as formatting a
  /// caller would have to parse back out of prose.
  void next(String command) => _next.add(command);

  /// Where the run's evidence was written, so a caller is told rather than
  /// left to guess at a path it never saw printed.
  String? diagnosis;

  /// Evidence a failed run should leave behind beside the report — native
  /// tool output, pub's validation text. The diagnosis writes these; a run
  /// that ends cleanly discards them.
  final Map<String, String> attachments = {};

  void attach(String name, String contents) => attachments[name] = contents;

  /// Records a halt. [helps] and [safe] only ever narrow: the worst answer of
  /// a run is the answer for the run.
  void halt(
    String kind,
    String sentence, {
    required bool helps,
    bool safe = true,
  }) {
    _halt = {'kind': kind, 'sentence': sentence};
    if (!helps) rerunHelps = false;
    if (!safe) safeToRerun = false;
  }

  /// The document, with [exit] folded in so a caller that captured only stdout
  /// still knows how the process ended.
  String encode({required int exit}) =>
      '${const JsonEncoder.withIndent('  ').convert({
            'rk': schema,
            'command': command,
            'exit': exit,
            'safe_to_rerun': safeToRerun,
            'rerun_helps': rerunHelps,
            if (_repository != null) 'repository': _repository,
            'units': _units.values.toList(),
            'problems': _problems,
            'next': _next,
            if (diagnosis != null) 'diagnosis': diagnosis,
            if (_halt != null) 'halt': _halt,
          })}\n';
}
