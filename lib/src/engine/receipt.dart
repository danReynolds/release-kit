import 'dart:convert';

import 'canonical_json.dart';
import 'diagnostic.dart';
import 'stage.dart';
import 'timings.dart';
import 'verdict.dart';

/// What a stage holds: the plan it is built from, the evidence of each piece
/// of work recorded so far, and every file that work wrote.
///
/// rk writes it by an atomic rename after each piece of work, so a crash
/// leaves the previous one. Keys are written sorted, so the record reads the
/// same however the lanes that filled it interleaved.
final class Receipt {
  Receipt({
    required this.stage,
    required Map<String, Object?> plan,
    Map<String, Map<String, Object?>> producers = const {},
    Map<String, StagedFile> files = const {},
  }) : plan = Map.unmodifiable(plan),
       producers = Map.unmodifiable(producers),
       files = Map.unmodifiable(files);

  /// The work that completes a stage, recorded last.
  static const barrier = 'complete-stage';

  /// rk's own record, read as plain JSON. A receipt another rk wrote says
  /// so by its schema, which is the message a reader can act on.
  factory Receipt.parse(String document) =>
      Timings.timeTally('parse stage receipt', () {
        final json = jsonDecode(document) as Map<String, Object?>;
        if (json['schema'] != stageSchemaVersion) {
          throw FormatException(
            'unsupported stage schema: ${json['schema']}; the recorded stage '
            'must be recovered with the RK version that created it',
          );
        }
        return Receipt(
          stage: StageId.fromJson(json['stage']),
          plan: json['plan'] as Map<String, Object?>,
          producers: {
            for (final MapEntry(:key, :value)
                in (json['producers'] as Map<String, Object?>).entries)
              key: value as Map<String, Object?>,
          },
          files: {
            for (final MapEntry(:key, :value)
                in (json['files'] as Map<String, Object?>).entries)
              key: StagedFile.fromJson(value),
          },
        );
      });

  final StageId stage;

  /// What the stage is built from, recorded before any work; the stage id is
  /// its digest.
  final Map<String, Object?> plan;

  /// Each recorded piece of work's evidence, by its name: signing
  /// identities, notarization results, smoke tests, warnings.
  final Map<String, Map<String, Object?>> producers;

  /// Every recorded file, by its path in the stage.
  final Map<String, StagedFile> files;

  /// Whether the barrier was recorded: completion is that fact, not a second
  /// flag that could disagree with it.
  bool get complete => producers.containsKey(barrier);

  /// This receipt with [producer] recorded, with [evidence] and [files].
  Receipt recording(
    String producer,
    Map<String, Object?> evidence,
    Map<String, StagedFile> files,
  ) => Receipt(
    stage: stage,
    plan: plan,
    producers: {
      ...producers,
      producer: CanonicalJson.normalize(evidence) as Map<String, Object?>,
    },
    files: {...this.files, ...files},
  );

  /// The warnings [producer] recorded, which a reused stage says again:
  /// Pub's validation warnings must not pass unseen because the stage that
  /// found them was built by an earlier run.
  List<Diagnostic> warnings(String producer) => [
    for (final warning in producers[producer]?[_warnings] as List? ?? const [])
      if (warning case {
        'code': final String code,
        'message': final String message,
      })
        Diagnostic(
          code: code,
          message: message,
          remedy: warning['remedy'] as String?,
        ),
  ];

  /// [warnings] as the evidence that keeps them.
  static Map<String, Object?> keeping(Iterable<Diagnostic> warnings) => {
    if (warnings.isNotEmpty)
      _warnings: [
        for (final warning in warnings)
          {
            'code': warning.code,
            'message': warning.message,
            'remedy': ?warning.remedy,
          },
      ],
  };

  static const _warnings = 'rk_warnings';

  Map<String, Object?> toJson() => {
    'schema': stageSchemaVersion,
    'stage': stage.toJson(),
    'plan': plan,
    'producers': producers,
    'files': {
      for (final MapEntry(:key, :value) in files.entries) key: value.toJson(),
    },
  };

  String encode() => '${CanonicalJson.encode(toJson())}\n';
}

/// One file a piece of work wrote, as it was when it was recorded.
final class StagedFile {
  const StagedFile({
    required this.producer,
    required this.size,
    required this.sha256,
  });

  factory StagedFile.fromJson(Object? json) {
    final map = json as Map<String, Object?>;
    return StagedFile(
      producer: map['producer'] as String,
      size: map['size'] as int,
      sha256: map['sha256'] as String,
    );
  }

  /// The work that wrote it.
  final String producer;
  final int size;
  final String sha256;

  Map<String, Object?> toJson() => {
    'producer': producer,
    'sha256': sha256,
    'size': size,
  };
}

/// What a stage is, as [Stage.check] finds it.
enum StageState {
  /// No receipt: there is nothing to reuse.
  absent,

  /// Interrupted, and every file it recorded intact: work resumes after it.
  resumable,

  /// Interrupted, and a file it recorded changed: it starts again.
  broken,

  /// The barrier is recorded, and every file the release publishes is
  /// recorded and intact.
  complete,

  /// The barrier is recorded, and a file the release publishes is missing
  /// or changed: bytes the operator may have reviewed no longer hold.
  changed,

  /// The receipt cannot be read: it is malformed, from another rk, or names
  /// another stage.
  unreadable,
}

/// One check of a stage against the release it is for.
final class StageCheck {
  StageCheck(
    this.state, {
    this.receipt,
    Map<String, String> problems = const {},
  }) : problems = Map.unmodifiable(problems);

  final StageState state;

  /// The receipt found, when one could be read; one that names another
  /// stage is shown, never used.
  final Receipt? receipt;

  /// What is wrong, by path in the stage: `stage.json` for the receipt.
  final Map<String, String> problems;

  bool get reusable => state == StageState.complete;

  /// Each problem as one line, `path: what`.
  List<String> get lines => [
    for (final MapEntry(:key, :value) in problems.entries) '$key: $value',
  ];

  /// The barrier's verdict, shared by status and release. A missing or
  /// interrupted stage is ordinary work. One that once completed and no
  /// longer validates is a conflict: publication must not silently replace
  /// bytes the operator may already have reviewed.
  Inspection get asInspection => switch (state) {
    StageState.complete => Inspection.exact(
      detail: 'staged and validated',
      evidence: {'stage id': receipt!.stage.id},
    ),
    StageState.absent ||
    StageState.resumable => Inspection.absent(detail: lines.join('; ')),
    StageState.broken ||
    StageState.changed ||
    StageState.unreadable => Inspection.conflict(
      lines.join('; '),
      evidence: {
        for (final (index, line) in lines.indexed)
          'stage issue ${index + 1}': line,
      },
    ),
  };
}
