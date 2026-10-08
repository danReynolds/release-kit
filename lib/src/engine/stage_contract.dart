import 'assets.dart';
import 'dependency_graph.dart';
import 'resolve.dart';
import 'stage_inspection.dart';
import 'stage_receipt.dart';

/// One stage producer: its receipt name, what it reads from earlier
/// producers (artifact paths or `step:` names), and what it writes.
final class StageStepContract {
  const StageStepContract(
    this.name, {
    this.inputs = const {},
    this.outputs = const {},
  });

  final String name;
  final Set<String> inputs;
  final Map<String, String> outputs;
}

final class StageContributionContract {
  const StageContributionContract({required this.step});

  final StageStepContract step;
}

/// Validates and canonically orders target-owned stage work by stable name.
///
/// Actual dependencies are resolved with the shared producer contracts by
/// [StageReceiptContract]. A target can therefore consume another producer's
/// artifact without inventing a lifecycle phase.
List<T> orderStageContributions<T>(
  Iterable<T> values,
  StageContributionContract Function(T value) contractOf,
) {
  final entries = List<T>.of(values);
  final names = <String>{};
  final outputs = <String, String>{};
  for (final entry in entries) {
    final contract = contractOf(entry);
    final name = contract.step.name;
    if (!names.add(name)) {
      throw StateError('two stage contracts claim the producer "$name"');
    }
    for (final output in contract.step.outputs.keys) {
      final previous = outputs[output];
      if (previous != null) {
        throw StateError(
          'stage artifact "$output" is produced by both "$previous" and '
          '"$name"',
        );
      }
      outputs[output] = name;
    }
  }
  entries.sort(
    (left, right) =>
        contractOf(left).step.name.compareTo(contractOf(right).step.name),
  );
  return List<T>.unmodifiable(entries);
}

typedef StageContractResolver =
    List<StageContributionContract> Function({
      required ResolvedUnit unit,
      required String? repository,
    });

/// The canonical private producer graph for one configured release unit.
///
/// It is intentionally independent of a stage directory, compiler, host, and
/// receipt. Both the receipt contract and `rk plan` consume this value, so the
/// topology a person sees cannot omit target-owned work or drift from the
/// graph a completed stage must prove.
final class StageProducerGraph {
  StageProducerGraph._({
    required List<StageStepContract> steps,
    required Map<String, Set<String>> dependencies,
  }) : steps = List<StageStepContract>.unmodifiable(steps),
       _dependencies = Map<String, Set<String>>.unmodifiable(dependencies);

  factory StageProducerGraph.forUnit({
    required Iterable<StageContributionContract> targetContributions,
    required Iterable<StageStepContract> localProducers,
  }) {
    final contributions = orderStageContributions(
      targetContributions,
      (contract) => contract,
    );
    final declared = <StageStepContract>[
      ...contributions.map((item) => item.step),
      ...localProducers,
      const StageStepContract(
        'complete-stage',
        outputs: {ReleaseAssets.manifest: 'manifest'},
      ),
    ];
    final names = declared.map((step) => step.name).toList();
    if (names.toSet().length != names.length) {
      throw StateError('two stage contracts claim the same producer name');
    }
    final outputOwners = <String, String>{};
    for (final step in declared) {
      for (final output in step.outputs.keys) {
        final previous = outputOwners[output];
        if (previous != null) {
          throw StateError(
            'stage artifact "$output" is produced by both "$previous" and '
            '"${step.name}"',
          );
        }
        outputOwners[output] = step.name;
      }
    }
    final dependencies = <String, Set<String>>{};
    for (final step in declared) {
      final needs = <String>{};
      if (step.name == 'complete-stage') {
        needs.addAll(names.where((name) => name != step.name));
      } else {
        for (final input in step.inputs) {
          final producer = input.startsWith('step:')
              ? input.substring('step:'.length)
              : outputOwners[input];
          if (producer == null) {
            throw StateError(
              'stage producer "${step.name}" needs unknown artifact '
              '"$input"',
            );
          }
          if (producer != step.name) needs.add(producer);
        }
      }
      dependencies[step.name] = Set<String>.unmodifiable(needs);
    }
    final graph = DependencyGraph<StageStepContract>(
      declared,
      idOf: (step) => step.name,
      dependenciesOf: (step) => dependencies[step.name]!,
    );
    return StageProducerGraph._(
      steps: graph.ordered(),
      dependencies: dependencies,
    );
  }

  final List<StageStepContract> steps;
  final Map<String, Set<String>> _dependencies;

  List<String> get producerNames => [for (final step in steps) step.name];

  Set<String> dependenciesOf(String producer) =>
      _dependencies[producer] ??
      (throw StateError('the stage graph has no producer "$producer"'));
}

/// The producers one resolved unit runs, in the order its receipt records
/// them. A receipt written by an rk that produced differently for the same
/// plan does not match it.
class StageReceiptContract {
  StageReceiptContract._({
    required this.unit,
    required this.repository,
    required List<StageStepContract> steps,
    required Map<String, Set<String>> dependencies,
  }) : _steps = List<StageStepContract>.unmodifiable(steps),
       _dependencies = Map<String, Set<String>>.unmodifiable(dependencies);

  factory StageReceiptContract.forUnit({
    required ResolvedUnit unit,
    required String? repository,
    required Iterable<StageContributionContract> targetContributions,
    required Iterable<StageStepContract> localProducers,
  }) {
    final graph = StageProducerGraph.forUnit(
      targetContributions: targetContributions,
      localProducers: localProducers,
    );
    return StageReceiptContract._(
      unit: unit,
      repository: repository,
      steps: graph.steps,
      dependencies: {
        for (final producer in graph.producerNames)
          producer: graph.dependenciesOf(producer),
      },
    );
  }

  final ResolvedUnit unit;
  final String? repository;
  final List<StageStepContract> _steps;
  final Map<String, Set<String>> _dependencies;

  /// Every producer name this contract expects, in canonical order — the
  /// order receipts are written in, however the work was scheduled.
  List<String> get producerNames => [for (final step in _steps) step.name];

  StageStepContract producerContract(String producer) => _steps.singleWhere(
    (step) => step.name == producer,
    orElse: () =>
        throw StateError('the stage contract has no producer "$producer"'),
  );

  Set<String> dependenciesOf(String producer) =>
      _dependencies[producer] ??
      (throw StateError('the stage contract has no producer "$producer"'));

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

    final contracts = {for (final step in _steps) step.name: step};
    for (final step in receipt.steps) {
      final contract = contracts[step.name];
      if (contract == null) continue;
      if (!_outputsMatch(step, contract)) {
        _issue(issues, '${step.name} has the wrong output inventory');
      }
    }
    return issues;
  }

  static bool _outputsMatch(StageStep step, StageStepContract contract) {
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

/// Gaps are safe because every step that depends on another names it among
/// its inputs: a recorded step whose producer is missing fails the
/// inspector's causal check, and a stale input digest fails its comparison.
/// A step that depends on none declares no inputs; the receipt's identity
/// binds it to its source.
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
