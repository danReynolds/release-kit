import 'dart:convert';
import 'dart:math';

import '../transforms/digest.dart';
import 'canonical_json.dart';
import 'stage.dart';
import 'stage_intent.dart';
import 'stage_receipt.dart';
import 'stage_store.dart';

enum StageLookupKind { found, absent, rejected, inconclusive }

final class StageLookupResult {
  const StageLookupResult._(this.kind, {this.receipt, this.message, this.path});
  final StageLookupKind kind;
  final StageReceipt? receipt;
  final String? message;
  final String? path;
}

/// Finds frozen choices without solving, adopting, writing or reading artifacts.
/// A candidate still needs native authorization and transactional adoption.
/// Only a conclusive [StageLookupKind.absent] permits a fresh solve; public
/// recovery checks may independently forbid that solve. A complete bounded
/// scan also detects conflicting choices, so no separate index is required.
final class StageLookup {
  StageLookup(
    this.store, {
    this.maxEntries = 128,
    this.maxReceiptBytes = maxStageReceiptBytes,
    this.maxTotalBytes = 32 * 1024 * 1024,
  }) {
    if (maxEntries < 1 || maxReceiptBytes < 1 || maxTotalBytes < 1) {
      throw ArgumentError('stage lookup bounds must be positive');
    }
  }

  final StageStore store;
  final int maxEntries;
  final int maxReceiptBytes;
  final int maxTotalBytes;

  /// Reads one provisional frozen reference without selecting or authorizing it.
  /// The caller must verify its receipt commitment and current source/native
  /// facts before treating it as a provider. Missing/corrupt references throw;
  /// this operation never searches for a replacement.
  StageReceipt readExact(String id, {int? maxBytes}) {
    if (maxBytes != null && maxBytes < 1) {
      throw const StageReceiptLimit(0);
    }
    final text = _readStage(
      id,
      _ReadBudget(min(maxTotalBytes, maxBytes ?? maxTotalBytes)),
    );
    if (text == null) throw StateError('the referenced stage is missing: $id');
    final receipt = StageReceipt.parse(text);
    if (receipt.identity.id != id) {
      throw StateError('referenced receipt does not name its stage directory');
    }
    return receipt;
  }

  /// [recoveryStageId] must come from separately authenticated recovery facts,
  /// never a lookup hint or a newest-receipt heuristic. It takes precedence
  /// over ordinary lookup and never falls through to another stage or absence.
  Future<StageLookupResult> find(
    StageIntent intent, {
    String? recoveryStageId,
  }) async {
    try {
      intent.requireCurrent(intent.base);
    } on Object catch (error) {
      return _problem(StageLookupKind.rejected, '$error');
    }
    final budget = _ReadBudget(maxTotalBytes);
    if (recoveryStageId != null) {
      final path = '${store.path}/$recoveryStageId/stage.json';
      try {
        final text = _readStage(recoveryStageId, budget);
        if (text == null) {
          throw StateError('the recovery-bound stage is missing');
        }
        final receipt = StageReceipt.parse(text);
        if (receipt.identity.id != recoveryStageId) {
          throw StateError(
            'recovery receipt does not name its stage directory',
          );
        }
        intent.requireReceipt(receipt);
        return StageLookupResult._(StageLookupKind.found, receipt: receipt);
      } on Object catch (error) {
        return _problem(StageLookupKind.rejected, '$error', path);
      }
    }

    final List<StageEntry> entries;
    try {
      final inventory = await store.inventoryBounded(maxEntries);
      if (!inventory.complete) {
        return _problem(
          StageLookupKind.inconclusive,
          'stage enumeration exceeds $maxEntries entries; inspect or clean obsolete stages before retrying',
          store.path,
        );
      }
      entries = inventory.entries;
    } on Object catch (error) {
      return _problem(StageLookupKind.inconclusive, '$error', store.path);
    }

    final matches = <StageReceipt>[];
    StageLookupResult? uncertainty;
    for (final entry in entries) {
      if (!_isId(entry.name)) continue;
      final path = '${store.path}/${entry.name}/stage.json';
      try {
        final text = _readStage(entry.name, budget);
        if (text == null) {
          throw const FormatException(
            'stage entry has no receipt and cannot be classified safely',
          );
        }
        final document = CanonicalJson.decodeDocument(text);
        if (document is Map && document['schema'] != stageSchemaVersion) {
          final legacy = _legacyCoordinates(document, entry.name);
          if (legacy == null) {
            throw const FormatException(
              'older receipt cannot be classified safely; use its creating RK version or inspect and clean the obsolete stage',
            );
          }
          if (legacy.unit == intent.unit && legacy.version == intent.version) {
            return _problem(
              StageLookupKind.rejected,
              'schema ${document['schema']} stage records ${intent.unit} ${intent.version}; recover public work with the RK version that created it, or explicitly clean an unpublished legacy stage before staging again',
              path,
            );
          }
          continue;
        }
        final receipt = StageReceipt.parse(text);
        if (receipt.identity.id != entry.name) {
          throw const FormatException(
            'receipt does not name its stage directory',
          );
        }
        final plan = receipt.plan;
        if (plan != null && plan.containsKey(StageIntent.planKey)) {
          final marker = plan[StageIntent.planKey];
          if (marker is! String || !_isId(marker)) {
            throw const FormatException('receipt has a malformed stage intent');
          }
        }
        if (plan?[StageIntent.planKey] == intent.sha256) {
          try {
            intent.requireReceipt(receipt);
          } on Object catch (error) {
            return _problem(StageLookupKind.rejected, '$error', path);
          }
          matches.add(receipt);
        } else if (plan == null) {
          throw const FormatException(
            'receipt lacks a frozen plan and cannot be classified safely',
          );
        } else if (!plan.containsKey(StageIntent.planKey) &&
            plan.containsKey('dependency_inputs')) {
          final unit = plan['unit'];
          if (unit is! Map ||
              !_isLabel(unit['name']) ||
              !_isLabel(unit['version'])) {
            throw const FormatException(
              'pre-intent dependency receipt lacks valid unit coordinates',
            );
          }
          if (unit['name'] == intent.unit &&
              unit['version'] == intent.version) {
            return _problem(
              StageLookupKind.rejected,
              'frozen dependencies predate intent recording; use the RK version that created the stage, or explicitly clean an unpublished stage before retrying',
              path,
            );
          }
        }
      } on Object catch (error) {
        if (error is StageReceiptLimit) {
          return _problem(
            StageLookupKind.inconclusive,
            '$error; inspect or clean obsolete stages before retrying',
            path,
          );
        }
        uncertainty ??= _problem(
          StageLookupKind.inconclusive,
          '$error; inspect this receipt or explicitly clean obsolete work before retrying',
          path,
        );
      }
    }
    if (uncertainty != null) return uncertainty;
    if (matches.length > 1) {
      return _problem(
        StageLookupKind.rejected,
        'multiple stages record the same intent; authenticated public recovery must select the exact stage, or explicitly clean unwanted unpublished stages',
        store.path,
      );
    }
    return matches.isEmpty
        ? const StageLookupResult._(StageLookupKind.absent)
        : StageLookupResult._(StageLookupKind.found, receipt: matches.single);
  }

  String? _readStage(String id, _ReadBudget budget) {
    final path = store.receiptPath(id);
    if (path == null) return null;
    final allowance = min(maxReceiptBytes, budget.remaining);
    return StageReceiptStore.readDocument(
      path,
      maxBytes: allowance,
      consume: budget.consume,
    );
  }
}

StageLookupResult _problem(
  StageLookupKind kind,
  String message, [
  String? path,
]) => StageLookupResult._(kind, message: message, path: path);

bool _isId(String value) => RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

bool _isLabel(Object? value) =>
    value is String &&
    value.trim().isNotEmpty &&
    !value.contains(RegExp(r'[\u0000-\u001f]'));

final class _ReadBudget {
  _ReadBudget(this.remaining);
  int remaining;
  void consume(int count) => remaining = max(0, remaining - count);
}

/// Historical classification only, never identity migration or adoption. The
/// schema-12 hash formula is checked with its original schema constant. A
/// completed legacy plan can identify unrelated work without reading artifacts.
({String unit, String version})? _legacyCoordinates(Map document, String id) {
  if (document['schema'] != 12) return null;
  final stage = document['stage'];
  final steps = document['steps'];
  if (stage is! Map || steps is! List || steps.isEmpty || stage['id'] != id) {
    return null;
  }
  if (document.length != 3 ||
      stage.length != 5 ||
      !stage.keys.toSet().containsAll({
        'id',
        'head_commit',
        'head_tree',
        'run_id',
        'plan_sha256',
      })) {
    return null;
  }
  // Validate historical shape without constructing a current-schema identity.
  final parsedSteps = steps.map(StageStep.fromJson).toList();
  if (parsedSteps.map((step) => step.name).toSet().length != steps.length) {
    return null;
  }
  final artifacts = parsedSteps.expand((step) => step.outputs).toList();
  if (artifacts.map((artifact) => artifact.path).toSet().length !=
      artifacts.length) {
    return null;
  }
  final last = steps.last;
  if (last is! Map ||
      last['name'] != 'complete-stage' ||
      last['evidence'] is! Map) {
    return null;
  }
  final plan = (last['evidence'] as Map)['release_plan'];
  if (plan is! Map || _digest(plan) != stage['plan_sha256']) return null;
  final Map<String, Object?> coordinates;
  if (stage['head_commit'] is String &&
      stage['head_tree'] is String &&
      stage['run_id'] == null) {
    final commit = stage['head_commit'] as String;
    final tree = stage['head_tree'] as String;
    if (!RegExp(r'^(?:[0-9a-f]{40}|[0-9a-f]{64})$').hasMatch(commit) ||
        !RegExp(r'^(?:[0-9a-f]{40}|[0-9a-f]{64})$').hasMatch(tree) ||
        commit.length != tree.length) {
      return null;
    }
    coordinates = {
      'schema': 12,
      'head_commit': stage['head_commit'],
      'head_tree': stage['head_tree'],
      'plan_sha256': stage['plan_sha256'],
    };
  } else if (stage['head_commit'] == null &&
      stage['head_tree'] == null &&
      stage['run_id'] is String) {
    final run = stage['run_id'] as String;
    if (run.trim().isEmpty || run.contains(RegExp(r'[\u0000-\u001f]'))) {
      return null;
    }
    coordinates = {
      'schema': 12,
      'source': 'unbound',
      'run_id': stage['run_id'],
      'plan_sha256': stage['plan_sha256'],
    };
  } else {
    return null;
  }
  if (_digest(coordinates) != id) return null;
  final unit = plan['unit'];
  if (unit is! Map || !_isLabel(unit['name']) || !_isLabel(unit['version'])) {
    return null;
  }
  return (unit: unit['name'] as String, version: unit['version'] as String);
}

String _digest(Object? value) =>
    Sha256.hex(utf8.encode(CanonicalJson.encode(value)));
