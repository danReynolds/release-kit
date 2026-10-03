import 'dart:convert';

import 'canonical_json.dart';
import 'diagnostic.dart';
import 'native_dependencies.dart';
import 'release_stage.dart';
import 'stage_dependencies.dart';
import 'stage_receipt.dart';

/// Native publication policy over an already prepared, authorized stage.
/// Core maps producer IDs to public targets and owns scope and ordering.
abstract interface class NativePublication {
  Set<String> get ecosystems;

  /// Reads and validates frozen local inputs. No public read or native solve
  /// occurs until a returned check runs immediately before its public act.
  Future<List<NativePublicationCheck>> prepare(ReleaseStage stage);
}

abstract interface class NativePublicationCheck {
  String get producer;
  List<NativePublicArchiveRequirement> get requirements;
  Future<NativePublicationOutcome> verify();
}

/// A runtime occurrence whose exact staged provider bytes must be public.
/// [archive] is always recorded inside the consumer stage, including imports.
/// Native constraints and source identities remain opaque to scheduling.
final class NativePublicArchiveRequirement {
  NativePublicArchiveRequirement({
    required this.use,
    required this.archive,
    required Iterable<NativeRequirement> causes,
  }) : causes = List.unmodifiable(causes) {
    if (this.causes.isEmpty ||
        this.causes.any(
          (cause) =>
              cause.context != use.context ||
              cause.slot != use.slot ||
              cause.package != use.provider.package ||
              !cause.phases.contains(DependencyPhase.publication),
        )) {
      throw ArgumentError('public archive requirement lacks matching causes');
    }
  }

  final NativeArtifactUse use;
  final StageArtifact archive;
  final List<NativeRequirement> causes;
}

/// Public observations are invocation evidence, never replacement stage inputs.
sealed class NativePublicationOutcome {
  NativePublicationOutcome(Map<String, Object?> evidence)
    : _evidence = CanonicalJson.encode(evidence);

  final String _evidence;
  Map<String, Object?> get evidence =>
      (jsonDecode(_evidence) as Map).cast<String, Object?>();
}

final class NativePublicationReady extends NativePublicationOutcome {
  NativePublicationReady({required Map<String, Object?> evidence})
    : super(evidence);
}

final class NativePublicationBlocked extends NativePublicationOutcome {
  NativePublicationBlocked({
    required this.diagnostic,
    Map<String, Object?> evidence = const {},
  }) : super(evidence);

  final Diagnostic diagnostic;
}
