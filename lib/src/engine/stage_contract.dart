import 'assets.dart';
import 'resolve.dart';
import 'stage.dart';
import 'stage_inspection.dart';
import 'stage_receipt.dart';

enum StageContributionPhase {
  beforeArtifacts,
  afterArtifacts,
}

typedef StageStepContractValidator = Iterable<StageIssue> Function(
  StageContractContext context,
  StageStep step,
);

final class StageStepContract {
  const StageStepContract(
    this.name, {
    this.inputs = const {},
    this.outputs = const {},
    this.validate,
  });

  final String name;
  final Set<String> inputs;
  final Map<String, String> outputs;
  final StageStepContractValidator? validate;
}

final class StageContributionContract {
  const StageContributionContract({required this.phase, required this.step});

  final StageContributionPhase phase;
  final StageStepContract step;
}

/// Orders the fixed target-owned stage work by position and stable name.
///
/// Built-in targets do not form a dependency graph: their only real ordering
/// boundary is whether work happens before or after shared artifact producers.
/// Duplicate producer and output claims are still refused fail-closed.
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
  for (final entry in entries) {
    final contract = contractOf(entry);
    for (final input in contract.step.inputs) {
      final producer = input.startsWith('step:')
          ? input.substring('step:'.length)
          : outputs[input];
      if (producer != null && names.contains(producer)) {
        throw StateError(
          'target stage producer "${contract.step.name}" depends on target '
          'producer "$producer"; use a shared artifact boundary instead',
        );
      }
    }
  }
  entries.sort((left, right) {
    final leftContract = contractOf(left);
    final rightContract = contractOf(right);
    final position = leftContract.phase.index.compareTo(
      rightContract.phase.index,
    );
    return position != 0
        ? position
        : leftContract.step.name.compareTo(rightContract.step.name);
  });
  return List<T>.unmodifiable(entries);
}

final class StageContractContext {
  const StageContractContext({
    required this.unit,
    required this.repository,
    required this.sourceRoot,
    required this.stage,
    required this.receipt,
  });

  final ResolvedUnit unit;
  final String? repository;
  final String sourceRoot;
  final StageDirectory stage;
  final StageReceipt receipt;
}

typedef StageContractResolver = List<StageContributionContract> Function({
  required ResolvedUnit unit,
  required String? repository,
  required String sourceRoot,
});

/// The exact receipt shape one resolved unit is allowed to trust.
///
/// [StageInspector] proves that recorded bytes and dependency digests agree.
/// This contract supplies the semantic half of that proof: every configured
/// producer is present, in the order rk can resume, with the filenames,
/// inputs, and evidence its operation owns. A canonical JSON document is not
/// trusted merely because all of its hashes agree with itself.
class StageReceiptContract {
  StageReceiptContract._({
    required this.unit,
    required this.repository,
    required this.sourceRoot,
    required List<StageStepContract> steps,
  }) : _steps = List<StageStepContract>.unmodifiable(steps);

  factory StageReceiptContract.forUnit({
    required ResolvedUnit unit,
    required String? repository,
    required String sourceRoot,
    required Iterable<StageContributionContract> targetContributions,
    required Iterable<StageStepContract> localProducers,
  }) {
    final contributions = orderStageContributions(
      targetContributions,
      (contract) => contract,
    );
    final steps = <StageStepContract>[
      const StageStepContract('source-snapshot'),
    ];
    steps.addAll(contributions
        .where((item) => item.phase == StageContributionPhase.beforeArtifacts)
        .map((item) => item.step));

    // The producer pipeline is declared once, beside the checklist that
    // derives it — the caller passes it here the same way targets pass
    // their contributions.
    steps.addAll(localProducers);

    steps.addAll(contributions
        .where((item) => item.phase == StageContributionPhase.afterArtifacts)
        .map((item) => item.step));

    steps.add(const StageStepContract(
      'complete-stage',
      outputs: {ReleaseAssets.manifest: 'manifest'},
    ));
    final names = steps.map((step) => step.name).toList();
    if (names.toSet().length != names.length) {
      throw StateError('two stage contracts claim the same producer name');
    }
    final outputOwners = <String, String>{};
    for (final step in steps) {
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
    return StageReceiptContract._(
      unit: unit,
      repository: repository,
      sourceRoot: sourceRoot,
      steps: steps,
    );
  }

  final ResolvedUnit unit;
  final String? repository;
  final String sourceRoot;
  final List<StageStepContract> _steps;

  /// Every producer name this contract expects, in canonical order — the
  /// order receipts are written in, however the work was scheduled.
  List<String> get producerNames => [for (final step in _steps) step.name];

  List<StageIssue> validate(StageDirectory stage, StageReceipt receipt) {
    final issues = <StageIssue>[];
    final names = receipt.steps.map((step) => step.name).toList();
    final expected = _steps.map((step) => step.name).toList();
    // A complete receipt records the whole pipeline exactly. An in-progress
    // receipt records what has finished so far — contract order with gaps,
    // because concurrent platform lanes finish at their own pace.
    final sequenceOk = receipt.complete
        ? _sameList(names, expected)
        : _isOrderedSubsequence(
            names, expected.take(expected.length - 1).toList());
    if (!sequenceOk) {
      _issue(
        issues,
        'receipt producer sequence is ${names.join(', ')}; expected '
        '${expected.join(', ')}',
      );
    }

    final contracts = {for (final step in _steps) step.name: step};
    final context = StageContractContext(
      unit: unit,
      repository: repository,
      sourceRoot: sourceRoot,
      stage: stage,
      receipt: receipt,
    );
    for (final step in receipt.steps) {
      final contract = contracts[step.name];
      if (contract == null) continue;
      if (step.name != 'source-snapshot' &&
          step.name != 'complete-stage' &&
          !_sameSet(
            step.inputs.map((input) => input.name).toSet(),
            contract.inputs,
          )) {
        _issue(issues, '${step.name} has the wrong producer inputs');
      }
      if (!_outputsMatch(step, contract)) {
        _issue(issues, '${step.name} has the wrong output inventory');
      }
      if (contract.validate case final validate?) {
        issues.addAll(validate(context, step));
      }
    }
    return issues;
  }

  static bool _outputsMatch(StageStep step, StageStepContract contract) {
    if (step.name == 'source-snapshot') return true;
    final actual = {
      for (final output in step.outputs) output.path: output.type
    };
    if (!contract.outputs.entries.every(
      (entry) => actual[entry.key] == entry.value,
    )) {
      return false;
    }
    return actual.entries
        .every((entry) => contract.outputs[entry.key] == entry.value);
  }

  static void _issue(List<StageIssue> issues, String message) {
    issues.add(StageIssue(
      StageIssueKind.invalidStructure,
      message,
      path: 'stage.json',
    ));
  }
}

bool _isPrefix(List<String> prefix, List<String> whole) =>
    prefix.length <= whole.length &&
    List.generate(prefix.length, (index) => prefix[index] == whole[index])
        .every((same) => same);

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

bool _sameSet(Set<String> left, Set<String> right) =>
    left.length == right.length && left.containsAll(right);
