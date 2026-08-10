import 'dart:convert';
import 'dart:io';

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
    this.optionalOutputs = const {},
    this.outputPrefix,
    this.outputType,
    this.validate,
  });

  final String name;
  final Set<String> inputs;
  final Map<String, String> outputs;
  final Map<String, String> optionalOutputs;
  final String? outputPrefix;
  final String? outputType;
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
    final claimed = {
      ...contract.step.outputs.keys,
      ...contract.step.optionalOutputs.keys,
    };
    for (final output in claimed) {
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

    if (unit.shipsBinaries) {
      final project = unit.binaryProject;
      final executable = project.executable!;
      final platforms = [...project.binaryPlatforms]..sort();
      for (final platform in platforms) {
        final binary = '$platform/$executable';
        if (platform.startsWith('macos-')) {
          steps.add(StageStepContract(
            'sign:$platform',
            inputs: const {'step:source-snapshot'},
            outputs: {binary: 'executable'},
          ));
          steps.add(StageStepContract(
            'notarize:$platform',
            inputs: {binary},
            outputs: {
              ReleaseAssets.notaryResultName(
                executable,
                project.version.canonical,
                platform,
              ): 'notary',
              ReleaseAssets.notaryLogName(
                executable,
                project.version.canonical,
                platform,
              ): 'notary',
            },
            optionalOutputs: {'$platform/$executable.zip': 'notary-input'},
          ));
        } else {
          steps.add(StageStepContract(
            'build:$platform',
            inputs: const {'step:source-snapshot'},
            outputs: {binary: 'executable'},
          ));
        }
        steps.add(StageStepContract(
          'archive:$platform',
          inputs: {binary},
          outputs: {
            ReleaseAssets.archiveName(
              executable,
              project.version.canonical,
              platform,
            ): 'archive',
          },
        ));
      }

      final archives = {
        for (final platform in platforms)
          ReleaseAssets.archiveName(
            executable,
            project.version.canonical,
            platform,
          ),
      };
      steps.add(StageStepContract(
        'checksums',
        inputs: archives,
        outputs: const {ReleaseAssets.checksums: 'checksums'},
      ));
    }

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
      for (final output in {
        ...step.outputs.keys,
        ...step.optionalOutputs.keys,
      }) {
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

  List<StageIssue> validate(StageDirectory stage, StageReceipt receipt) {
    final issues = <StageIssue>[];
    final names = receipt.steps.map((step) => step.name).toList();
    final expected = _steps.map((step) => step.name).toList();
    final sequenceOk = receipt.complete
        ? _sameList(names, expected)
        : _validProgress(names, expected.take(expected.length - 1).toList());
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
      final contract = contracts[step.name] ?? _macBuildContract(step.name);
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
      _validateEvidence(stage, step, issues);
      if (contract.validate case final validate?) {
        issues.addAll(validate(context, step));
      }
    }
    return issues;
  }

  static bool _validProgress(List<String> actual, List<String> finalNames) {
    if (_isPrefix(actual, finalNames)) return true;
    if (actual.isEmpty || !actual.last.startsWith('build:macos-')) return false;
    final platform = actual.last.substring('build:'.length);
    final index = actual.length - 1;
    return index < finalNames.length &&
        finalNames[index] == 'sign:$platform' &&
        _isPrefix(actual.take(index).toList(), finalNames);
  }

  static StageStepContract? _macBuildContract(String name) {
    if (!name.startsWith('build:macos-')) return null;
    final platform = name.substring('build:'.length);
    return StageStepContract(
      name,
      inputs: const {'step:source-snapshot'},
      // The exact executable name is checked by the corresponding sign
      // contract once the transient unsigned build is replaced.
      outputPrefix: '$platform/',
      outputType: 'executable',
    );
  }

  static bool _outputsMatch(StageStep step, StageStepContract contract) {
    if (step.name == 'source-snapshot') return true;
    if (contract.outputPrefix != null) {
      return step.outputs.length == 1 &&
          step.outputs.single.path.startsWith(contract.outputPrefix!) &&
          step.outputs.single.type == contract.outputType;
    }
    final actual = {
      for (final output in step.outputs) output.path: output.type
    };
    if (!contract.outputs.entries.every(
      (entry) => actual[entry.key] == entry.value,
    )) {
      return false;
    }
    final allowed = {...contract.outputs, ...contract.optionalOutputs};
    return actual.entries.every((entry) => allowed[entry.key] == entry.value);
  }

  static void _validateEvidence(
    StageDirectory stage,
    StageStep step,
    List<StageIssue> issues,
  ) {
    if (step.name.startsWith('build:') || step.name.startsWith('sign:')) {
      final smoke = step.evidence['smoke'];
      final status = smoke is Map ? smoke['status'] : null;
      final reason = smoke is Map ? smoke['reason'] : null;
      if (status != 'passed' &&
          !(status == 'not-executed' &&
              reason is String &&
              reason.isNotEmpty)) {
        _issue(issues, '${step.name} has invalid smoke-test evidence');
      }
    }

    if (step.name.startsWith('notarize:')) {
      final notary = step.evidence['notary'];
      final result = step.outputs
          .where((output) => output.path.endsWith('.notary-result.json'))
          .firstOrNull;
      final log = step.outputs
          .where((output) => output.path.endsWith('.notary-log.json'))
          .firstOrNull;
      final submission = notary is Map ? notary['submission_id'] : null;
      if (notary is! Map ||
          notary['status'] != 'Accepted' ||
          submission is! String ||
          submission.isEmpty ||
          result == null ||
          log == null ||
          notary['result_sha256'] != result.sha256 ||
          notary['log_sha256'] != log.sha256 ||
          !_acceptedNotaryFile(stage, result.path, submission)) {
        issues.add(StageIssue(
          StageIssueKind.invalidNotary,
          '${step.name} has invalid Accepted-submission evidence',
          path: 'stage.json',
        ));
      }
    }

    if (step.name == 'checksums') {
      final checksums = step.evidence['checksums'];
      final expected = {
        for (final input in step.inputs) input.name: input.sha256
      };
      final output = step.outputs.firstOrNull;
      if (checksums is! Map ||
          !_sameMap(checksums, expected) ||
          output == null ||
          !_checksumFileMatches(stage, output.path, expected)) {
        issues.add(const StageIssue(
          StageIssueKind.invalidChecksums,
          'checksums evidence does not exactly bind every archive input',
          path: 'SHA256SUMS',
        ));
      }
    }
  }

  static bool _acceptedNotaryFile(
    StageDirectory stage,
    String path,
    String submission,
  ) {
    try {
      final decoded = jsonDecode(File(stage.resolve(path)).readAsStringSync());
      return decoded is Map &&
          decoded['status'] == 'Accepted' &&
          decoded['id'] == submission;
    } on Object {
      return false;
    }
  }

  static bool _checksumFileMatches(
    StageDirectory stage,
    String path,
    Map<String, String> expected,
  ) {
    try {
      final found = <String, String>{};
      for (final line in File(stage.resolve(path)).readAsLinesSync()) {
        if (line.isEmpty) continue;
        final match =
            RegExp(r'^([0-9a-f]{64})  ([^/\\\u0000]+)$').firstMatch(line);
        if (match == null || found.containsKey(match.group(2))) return false;
        found[match.group(2)!] = match.group(1)!;
      }
      return _sameMap(found, expected);
    } on Object {
      return false;
    }
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

bool _sameList(List<String> left, List<String> right) =>
    left.length == right.length && _isPrefix(left, right);

bool _sameSet(Set<String> left, Set<String> right) =>
    left.length == right.length && left.containsAll(right);

bool _sameMap(Map left, Map right) =>
    left.length == right.length &&
    left.entries.every((entry) => right[entry.key] == entry.value);
