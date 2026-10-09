import 'stage_inspection.dart';
import 'stage_receipt.dart';
import 'unit_release.dart';

/// The private producer graph for one configured release unit: its
/// release's work, in order, and what each piece reads first.
///
/// It is independent of a stage directory, compiler, host and receipt. Both
/// the receipt contract and `rk plan` consume it, so the topology a person
/// sees cannot drift from the graph a completed stage must prove.
final class StageProducerGraph {
  StageProducerGraph.forWork(Iterable<Work> work)
    : steps = List<Work>.unmodifiable(work),
      _dependencies = {
        for (final step in work)
          step.name: {for (final input in step.inputs) input.name},
      };

  final List<Work> steps;
  final Map<String, Set<String>> _dependencies;

  List<String> get producerNames => [for (final step in steps) step.name];

  Set<String> dependenciesOf(String producer) =>
      _dependencies[producer] ??
      (throw StateError('the stage graph has no producer "$producer"'));

  /// Whether [receipt] records these producers, in order, with the outputs
  /// each one writes. Reads no files.
  List<StageIssue> validateDeclarations(StageReceipt receipt) {
    final issues = <StageIssue>[];
    final names = receipt.steps.map((step) => step.name).toList();
    final expected = producerNames;
    // A complete receipt records the whole pipeline exactly. An in-progress
    // receipt records what has finished so far — contract order with gaps,
    // because concurrent platform lanes finish at their own pace.
    final sequenceOk = receipt.complete
        ? _sameList(names, expected)
        : _isOrderedSubsequence(
            names,
            expected.take(expected.length - 1).toList(),
          );
    if (!sequenceOk) {
      _issue(
        issues,
        'receipt producer sequence is ${names.join(', ')}; expected '
        '${expected.join(', ')}',
      );
    }

    final contracts = {for (final step in steps) step.name: step};
    for (final step in receipt.steps) {
      final contract = contracts[step.name];
      if (contract == null) continue;
      if (!_outputsMatch(step, contract)) {
        _issue(issues, '${step.name} has the wrong output inventory');
      }
    }
    return issues;
  }

  static bool _outputsMatch(StageStep step, Work contract) {
    final actual = {
      for (final output in step.outputs) output.path: output.type,
    };
    if (!contract.outputs.entries.every(
      (entry) => actual[entry.key] == entry.value,
    )) {
      return false;
    }
    return actual.entries.every(
      (entry) => contract.outputs[entry.key] == entry.value,
    );
  }

  static void _issue(List<StageIssue> issues, String message) {
    issues.add(
      StageIssue(StageIssueKind.invalidStructure, message, path: 'stage.json'),
    );
  }
}

bool _isPrefix(List<String> prefix, List<String> whole) =>
    prefix.length <= whole.length &&
    List.generate(
      prefix.length,
      (index) => prefix[index] == whole[index],
    ).every((same) => same);

/// Gaps are safe because rk records a producer only after the producers it
/// depends on were recorded, and trusts its own writes; every recorded output
/// is checked before an interrupted stage resumes. A step that depends on
/// none declares no inputs; the receipt's identity binds it to its source.
bool _isOrderedSubsequence(List<String> names, List<String> whole) {
  var at = 0;
  for (final name in names) {
    at = whole.indexOf(name, at);
    if (at < 0) return false;
    at += 1;
  }
  return true;
}

bool _sameList(List<String> left, List<String> right) =>
    left.length == right.length && _isPrefix(left, right);
