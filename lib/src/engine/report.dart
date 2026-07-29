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

  /// Whether running the same command again is safe.
  ///
  /// True unless a halt says otherwise: re-running is rk's resume, and the one
  /// case that re-running cannot fix says so explicitly. An agent reads this
  /// rather than the prose, which is the whole point of having it.
  var safeToRerun = true;

  /// Whether any step was recorded — that is, whether a run got as far as
  /// looking at the work rather than refusing the request.
  bool get hasSteps =>
      _units.values.any((u) => (u['steps'] as List).isNotEmpty);

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
    Duration? took,
  }) {
    (_entry(unit)['steps'] as List<Map<String, Object?>>).add({
      'id': id,
      'summary': summary,
      'verdict': verdict,
      if (permanent != null) 'permanent': permanent,
      if (public != null) 'public': public,
      if (needs.isNotEmpty) 'needs': needs,
      if (detail != null) 'detail': detail,
      if (took != null) 'took_ms': took.inMilliseconds,
    });
  }

  void problem(Diagnostic diagnostic) {
    _problems.add({
      'code': diagnostic.code,
      'message': diagnostic.message,
      if (diagnostic.source != null) 'source': diagnostic.source.toString(),
      if (diagnostic.remedy != null) 'remedy': diagnostic.remedy,
    });
  }

  /// The command that would advance things, as data rather than as formatting a
  /// caller would have to parse back out of prose.
  void next(String command) => _next.add(command);

  void halt(String kind, String sentence, {required bool rerunHelps}) {
    _halt = {'kind': kind, 'sentence': sentence};
    if (!rerunHelps) safeToRerun = false;
  }

  /// The document, with [exit] folded in so a caller that captured only stdout
  /// still knows how the process ended.
  String encode({required int exit}) =>
      '${const JsonEncoder.withIndent('  ').convert({
            'rk': schema,
            'command': command,
            'exit': exit,
            'safe_to_rerun': safeToRerun,
            if (_repository != null) 'repository': _repository,
            'units': _units.values.toList(),
            'problems': _problems,
            'next': _next,
            if (_halt != null) 'halt': _halt,
          })}\n';
}
