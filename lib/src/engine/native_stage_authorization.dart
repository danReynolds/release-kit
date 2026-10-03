import 'release_stage.dart';
import 'resolve.dart';
import 'stage_dependencies.dart';
import 'stage_receipt.dart';

/// Native authorization injected into generic saved-stage recovery. Core owns
/// lookup, proof closure, producer ordering and transactional installation;
/// adapters own manifests, native graphs and archive interpretation.
abstract interface class NativeStageAuthority {
  Set<String> get ecosystems;

  /// Unsolved, scope-independent inputs read from current authoritative source.
  Map<String, Object?> readIntent(ResolvedUnit unit);

  /// Reauthorize frozen choices; never discover replacement versions. The
  /// result can hold transient fetch handles, which are not serialized.
  Future<AuthorizedNativeStage> authorize(
    ResolvedUnit unit,
    StageReceipt receipt,
  );
}

abstract interface class AuthorizedNativeStage {
  /// Native archive checks for outputs actually recorded in this stage.
  /// Core checks their ordinary byte/mode commitments before and after this
  /// call. Proof-only ancestors do not require their deleted payloads.
  Future<void> validateRetained(ReleaseStage stage, StageReceipt receipt);

  /// Recover only a future external import's exact selected bytes. The caller
  /// must compare the returned declaration to the original before installation.
  /// A missing already-recorded input is corruption, never a recovery request.
  Future<ExternalStageDependency> recoverExternal(
    ExternalStageDependency input,
  );
}
