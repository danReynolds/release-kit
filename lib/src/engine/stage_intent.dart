import 'dart:convert';

import '../transforms/digest.dart';
import 'canonical_json.dart';
import 'stage.dart';
import 'stage_receipt.dart';

/// Current unsolved facts, independent of command scope and availability.
/// Adapters supply authoritative roots/locks/helpers, configured candidates,
/// canonical registries and native policy. Selected versions are not intent.
/// The live reader is deliberately not restored from serialized evidence.
final class StageIntent {
  StageIntent.capture({
    required this.base,
    required Map<String, Object?> basePlan,
    required Map<String, Object?> Function() readInputs,
  }) : basePlan = _freeze(basePlan),
       inputs = _freeze(readInputs()),
       _readInputs = readInputs {
    if (this.basePlan.containsKey(planKey) ||
        this.basePlan.containsKey('dependency_inputs') ||
        _digest(this.basePlan) != base.planSha256) {
      throw ArgumentError(
        'stage intent requires its dependency-free base plan',
      );
    }
    final unit = this.basePlan['unit'];
    if (unit is! Map || !_isLabel(unit['name']) || !_isLabel(unit['version'])) {
      throw ArgumentError('stage intent has no release unit coordinates');
    }
  }

  static const planKey = 'dependency_intent';
  final StageIdentity base;
  final Map<String, Object?> basePlan;
  final Map<String, Object?> inputs;
  final Map<String, Object?> Function() _readInputs;
  String get unit => (basePlan['unit'] as Map)['name'] as String;
  String get version => (basePlan['unit'] as Map)['version'] as String;

  late final String sha256 = _digest({
    'format': 1,
    'base': base.id,
    'native_inputs': inputs,
  });

  void requireCurrent(StageIdentity actualBase) {
    if (actualBase.id != base.id ||
        CanonicalJson.encode(_readInputs()) != CanonicalJson.encode(inputs)) {
      throw StateError(
        'native stage intent changed; reauthorize current inputs',
      );
    }
  }

  /// Structural match only. The caller still authenticates native selections,
  /// provider proofs, current source and actual recorded artifact bytes.
  void requireReceipt(StageReceipt receipt) {
    final plan = receipt.plan;
    if (plan == null || plan[planKey] != sha256) {
      throw StateError('receipt does not record the requested stage intent');
    }
    final stripped = Map<String, Object?>.of(plan)
      ..remove(planKey)
      ..remove('dependency_inputs');
    final actual = receipt.identity.isGitBound
        ? StageIdentity.forPlan(
            headCommit: receipt.identity.headCommit!,
            headTree: receipt.identity.headTree!,
            resolvedPlan: stripped,
          )
        : StageIdentity.forUnboundPlan(
            runId: receipt.identity.runId!,
            resolvedPlan: stripped,
          );
    if (actual.id != base.id) {
      throw StateError('receipt intent differs from its base release inputs');
    }
  }
}

Map<String, Object?> _freeze(Map<String, Object?> value) =>
    CanonicalJson.normalize(value) as Map<String, Object?>;

String _digest(Object? value) =>
    Sha256.hex(utf8.encode(CanonicalJson.encode(value)));

bool _isLabel(Object? value) =>
    value is String &&
    value.trim().isNotEmpty &&
    !value.contains(RegExp(r'[\u0000-\u001f]'));
