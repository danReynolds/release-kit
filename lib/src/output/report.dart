import 'dart:convert';
import 'dart:io';

import '../engine/canonical_json.dart';
import '../engine/diagnostic.dart';
import '../engine/unit_release.dart';
import '../engine/verdict.dart';
import 'output.dart' show HaltKind;

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

  /// Wire format version, bumped whenever the serialized contract changes.
  static const schema = 12;

  /// Units by name, in the order they were first mentioned.
  ///
  /// Keyed rather than "the one currently open": a step carries the name of its
  /// own unit, so looking it up cannot put a step under the wrong one, and no
  /// state has to survive between two calls for the document to come out right
  /// (CI readiness, seam 1).
  final Map<String, Map<String, Object?>> _units = {};
  final List<Map<String, Object?>> _problems = [];
  final List<Map<String, Object?>> _warnings = [];
  final List<String> _next = [];
  Map<String, Object?>? _repository;
  final Map<String, Object> _sections = {};
  Map<String, Object?>? _halt;

  /// Whether re-running would move the release forward.
  ///
  /// False after a halt that re-running cannot resolve — a conflict at a
  /// destination — so a caller can tell "try again" from "a human has to
  /// decide" without reading the sentence.
  var rerunHelps = true;

  /// Whether this run began changing things.
  ///
  /// The signal for whether a failure is worth recording evidence about. It is
  /// set by the act phase rather than inferred from whether a step was
  /// printed: inferring it meant no planned failure ever wrote a diagnosis,
  /// because a read-only path that printed steps always succeeded.
  var acted = false;

  /// Whether this run began acting on a public target: what a crash says
  /// may have had an effect. The stage a release builds first is private.
  var actedPublicly = false;

  /// Whether this run changed a public target, as the read after each act
  /// found it: what a halt says changed. Set in one place, the release
  /// loop, so lanes publishing side by side agree whichever ends first.
  var publicChanged = false;

  /// Whether this run changed what its halt speaks of: for stage and
  /// release, a public target; for init, clean and use, the files they
  /// write.
  bool get changedWhatHaltsSpeakOf => switch (command) {
    'stage' || 'release' => actedPublicly,
    _ => acted,
  };

  /// [uncommitted] is null when the run stopped before reading git, which is
  /// reported as absence rather than as zero — a clean tree and an unread one
  /// are different facts.
  void repository({
    required String name,
    String? branch,
    int? uncommitted,
    String? head,
    String? remote,
    String? sourceBinding,
    String? sourceComparison,
  }) {
    // remote is null-when-absent rather than absent-when-absent: an
    // absent key and a null value are a parser fork forty repos would
    // otherwise each decide alone.
    _repository = {
      'name': name,
      if (branch != null) 'branch': branch,
      if (head != null) 'head': head,
      'remote': remote,
      if (sourceBinding != null) 'source_binding': sourceBinding,
      if (sourceComparison != null) 'source_comparison': sourceComparison,
      if (uncommitted != null) 'uncommitted': uncommitted,
    };
  }

  /// Records what a unit releases. Steps name their own unit, so this may come
  /// before or after them.
  void unit({
    required String name,
    required String version,
    required String? tag,
  }) {
    _entry(name)
      ..['version'] = version
      ..['tag'] = tag;
  }

  Map<String, Object?> _entry(String name) => _units.putIfAbsent(
    name,
    () => {'name': name, 'steps': <Map<String, Object?>>[]},
  );

  /// Records what a run found at [step], under its own unit.
  ///
  /// [verdict] is always written, and defaults to `unknown` rather than to
  /// nothing. An omitted key invites a caller to read "no verdict" as "nothing
  /// is there", which is the one collapse rk must never make — `unknown` says
  /// rk could not tell, and that is a different instruction to a caller than
  /// `absent`.
  void step(
    Step step, {
    Verdict verdict = Verdict.unknown,
    String? detail,
    Map<String, String> evidence = const {},
    String? action,
  }) {
    // Replace by id rather than append: a step is one fact, and recording it
    // twice — once at inspection, once after the act — gave a caller two
    // entries for one id in a document whose contract is "keyed on step id",
    // with the stale one first. The act's answer supersedes the inspection's.
    final steps = _entry(step.unit)['steps'] as List<Map<String, Object?>>;
    steps.removeWhere((s) => s['id'] == step.id);
    steps.add({
      'id': step.id,
      'kind': step.kind.name,
      'target': ?step.target?.wireName,
      'summary': step.summary,
      'verdict': verdict.name,
      'permanent': step.isPermanent,
      'public': step.isPublic,
      if (step.needs.isNotEmpty)
        'needs': [for (final need in step.needs) need.id],
      'detail': ?detail,
      if (evidence.isNotEmpty) 'evidence': evidence,
      'action': ?action,
    });
  }

  /// Records one target-oriented status observation, [entry], under [unit],
  /// in place of any recorded under its id. It carries the same four-way
  /// verdict as its step.
  void target(String unit, Map<String, Object?> entry) {
    final targets =
        _entry(unit).putIfAbsent('targets', () => <Map<String, Object?>>[])
            as List<Map<String, Object?>>;
    targets.removeWhere((target) => target['id'] == entry['id']);
    targets.add(entry);
  }

  void problem(Diagnostic diagnostic, {String? unit, String? target}) {
    _problems.add(_record(diagnostic, unit: unit, target: target));
  }

  void warning(Diagnostic diagnostic, {String? unit, String? target}) {
    _warnings.add(_record(diagnostic, unit: unit, target: target));
  }

  /// Stable warning facts disclosed to this unit, including repository-wide
  /// warnings, for the disclosure that travels with the yes. Each distinct
  /// fact is listed once; evidence is its content, not an attachment's
  /// incidental name.
  List<Map<String, Object?>> warningEvidenceFor(String unit) {
    final unique = <String, Map<String, Object?>>{};
    for (final warning in _warnings) {
      if (warning['unit'] != null && warning['unit'] != unit) continue;
      final value = <String, Object?>{
        ...warning,
        if (warning['evidence'] case final String name)
          'evidence': attachments[name] ?? name,
      };
      unique[CanonicalJson.encode(value)] = Map.unmodifiable(value);
    }
    final keys = unique.keys.toList()..sort();
    return List.unmodifiable([for (final key in keys) unique[key]!]);
  }

  /// Files a finding's own account of what failed beside the document, and
  /// names it on the finding so the two correlate rather than being matched
  /// by eye.
  ///
  /// Counted, not coded: three platforms failing the same way in one run
  /// carry the same RK code, and a name built from the code alone would keep
  /// one of the three and silently drop the other two.
  Map<String, Object?> _record(
    Diagnostic diagnostic, {
    String? unit,
    String? target,
  }) {
    final entry = _diagnostic(diagnostic, unit: unit, target: target);
    final evidence = diagnostic.evidence;
    if (evidence != null) {
      final name = 'tool-output/${++_kept}-${diagnostic.code}.txt';
      attachments[name] = evidence;
      entry['evidence'] = name;
    }
    return entry;
  }

  int _kept = 0;

  static Map<String, Object?> _diagnostic(
    Diagnostic diagnostic, {
    String? unit,
    String? target,
  }) => {
    if (unit != null) 'unit': unit,
    if (target != null) 'target': target,
    'code': diagnostic.code,
    'message': diagnostic.message,
    if (diagnostic.source != null) 'source': diagnostic.source.toString(),
    if (diagnostic.remedy != null) 'remedy': diagnostic.remedy,
  };

  /// The command that would advance things, as data rather than as formatting a
  /// caller would have to parse back out of prose.
  void next(String command) => _next.add(command);

  /// Where the run's evidence was written, so a caller is told rather than
  /// left to guess at a path it never saw printed.
  String? diagnosis;

  /// Evidence and artifacts that travel with the document — native tool
  /// output, pub's validation text, a proposed config. The diagnosis writes
  /// them beside the report on a failed run, and `encode` carries them, so a
  /// --json caller is never told "the text exists somewhere you cannot see".
  final Map<String, String> attachments = {};

  void attach(String name, String contents) => attachments[name] = contents;

  /// What one command reports beside its units, by [key]: `init`'s
  /// proposal, what `clean` found and removed, `plan`'s release graph,
  /// `use`'s installations, or `target`'s release choices. The document
  /// keeps them in that order, whichever came first.
  void section(String key, Object value) {
    assert(_sectionOrder.contains(key), 'no report section $key');
    _sections[key] = value;
  }

  static const _sectionOrder = [
    'init',
    'cleanup',
    'plan',
    'installations',
    'release_choices',
  ];

  /// Whether a halt sentence has been recorded, so a generic late halt can
  /// yield to a specific one already diagnosed.
  bool get halted => _halt != null;

  /// Records a halt. Re-running only ever stops helping: the worst answer
  /// of a run is the answer for the run. Re-running is safe by construction
  /// — the same inspection precedes every act — so the document does not
  /// carry a field that could only ever say so.
  void halt(HaltKind kind) {
    _halt = {'kind': kind.name, 'sentence': kind.sentence};
    if (!kind.rerunHelps) rerunHelps = false;
  }

  /// Whether a run that did not end cleanly leaves its evidence behind.
  ///
  /// `rk plan` is an unusually strict read-only surface: even an rk bug must
  /// not make its "nothing changed" contract false. Other commands keep a
  /// crash because its stack is otherwise lost, and an ordinary failure only
  /// after the run began acting: a refusal before that has said everything
  /// it knows, and copying it would fill `.rk/diagnosis` with typos.
  bool keepsDiagnosis({required bool crashed}) =>
      command != 'plan' && (acted || crashed);

  /// Writes this document, its attachments and any [crash] under
  /// `<root>/.rk/diagnosis/<stamp>/`, and says where.
  ///
  /// rk never reads it back. That is what keeps it honest: nothing rk
  /// decides later can depend on a file a person is free to delete, so the
  /// directory never becomes the state store rk does not have.
  String writeDiagnosis(
    String root, {
    required String stamp,
    required int exit,
    String? crash,
  }) {
    final at = '$root/.rk/diagnosis/$stamp';
    for (final MapEntry(key: name, value: contents) in {
      'run.json': encode(exit: exit),
      ...attachments,
      'crash.txt': ?crash,
    }.entries) {
      File('$at/$name')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(contents);
    }
    return diagnosis = at;
  }

  /// The document, with [exit] folded in so a caller that captured only stdout
  /// still knows how the process ended.
  String encode({required int exit}) {
    final document = {
      'rk': schema,
      'command': command,
      'observed_at': DateTime.now().toUtc().toIso8601String(),
      'exit': exit,
      'rerun_helps': rerunHelps,
      'repository': ?_repository,
      for (final key in _sectionOrder) key: ?_sections[key],
      'units': _units.values.toList(),
      'problems': _problems,
      'warnings': _warnings,
      'next': _next,
      if (attachments.isNotEmpty) 'attachments': attachments,
      'diagnosis': ?diagnosis,
      'halt': ?_halt,
    };
    return '${const JsonEncoder.withIndent('  ').convert(document)}\n';
  }
}
