import 'dart:convert';
import 'dart:io';

import '../destinations/homebrew.dart';
import 'assets.dart';
import 'changelog.dart';
import 'resolve.dart';
import 'stage.dart';
import 'stage_inspection.dart';
import 'stage_receipt.dart';

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
    required List<_ContractStep> steps,
  }) : _steps = List<_ContractStep>.unmodifiable(steps);

  factory StageReceiptContract.forUnit({
    required ResolvedUnit unit,
    required String? repository,
    required String sourceRoot,
  }) {
    final steps = <_ContractStep>[
      const _ContractStep('source-snapshot'),
    ];

    final packages = unit.projects
        .where((project) => project.channels.contains('pub.dev'))
        .toList()
      ..sort((left, right) => left.name.compareTo(right.name));
    for (final project in packages) {
      steps.add(_ContractStep(
        'pub-preflight:${project.name}',
        inputs: const {'step:source-snapshot'},
      ));
    }

    if (unit.shipsBinaries) {
      final project = unit.binaryProject;
      final executable = project.executable!;
      if (project.channels.contains('github-release')) {
        steps.add(const _ContractStep(
          'release-notes',
          inputs: {'step:source-snapshot'},
          outputs: {'release-notes.md': 'notes'},
        ));
      }

      final platforms = [...project.binaryPlatforms]..sort();
      for (final platform in platforms) {
        final binary = '$platform/$executable';
        if (platform.startsWith('macos-')) {
          steps.add(_ContractStep(
            'sign:$platform',
            inputs: const {'step:source-snapshot'},
            outputs: {binary: 'executable'},
          ));
          steps.add(_ContractStep(
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
          steps.add(_ContractStep(
            'build:$platform',
            inputs: const {'step:source-snapshot'},
            outputs: {binary: 'executable'},
          ));
        }
        steps.add(_ContractStep(
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
      steps.add(_ContractStep(
        'checksums',
        inputs: archives,
        outputs: const {ReleaseAssets.checksums: 'checksums'},
      ));
      if (project.channels.contains('homebrew')) {
        steps.add(_ContractStep(
          'homebrew-formula',
          inputs: archives,
          outputs: {
            ReleaseAssets.formulaName(executable): 'formula',
          },
        ));
      }
    }

    steps.add(const _ContractStep(
      'complete-stage',
      outputs: {ReleaseAssets.manifest: 'manifest'},
    ));
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
  final List<_ContractStep> _steps;

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
    }

    _validateNotes(stage, receipt, issues);
    _validateFormula(stage, receipt, issues);
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

  static _ContractStep? _macBuildContract(String name) {
    if (!name.startsWith('build:macos-')) return null;
    final platform = name.substring('build:'.length);
    return _ContractStep(
      name,
      inputs: const {'step:source-snapshot'},
      // The exact executable name is checked by the corresponding sign
      // contract once the transient unsigned build is replaced.
      outputPrefix: '$platform/',
      outputType: 'executable',
    );
  }

  static bool _outputsMatch(StageStep step, _ContractStep contract) {
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
    if (step.name.startsWith('pub-preflight:')) {
      if (!_sameMap(
        step.evidence,
        const {
          'publish_dry_run': 'passed',
          'consumer_resolve': 'passed',
        },
      )) {
        _issue(issues, '${step.name} does not prove both package preflights');
      }
      return;
    }

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

  void _validateNotes(
    StageDirectory stage,
    StageReceipt receipt,
    List<StageIssue> issues,
  ) {
    final step =
        receipt.steps.where((item) => item.name == 'release-notes').firstOrNull;
    if (step == null) return;
    final project = unit.binaryProject;
    final changelog = File('$sourceRoot/${project.fileAt('CHANGELOG.md')}');
    final expected = changelog.existsSync()
        ? Changelog.entry(changelog.readAsStringSync(), project.version)
        : null;
    final actual = File(stage.resolve('release-notes.md'));
    if (expected == null ||
        !actual.existsSync() ||
        actual.readAsStringSync() != expected) {
      _issue(issues, 'release-notes does not match the staged changelog entry');
    }
  }

  void _validateFormula(
    StageDirectory stage,
    StageReceipt receipt,
    List<StageIssue> issues,
  ) {
    final formulaStep = receipt.steps
        .where((item) => item.name == 'homebrew-formula')
        .firstOrNull;
    if (formulaStep == null) return;
    final repository = this.repository;
    if (repository == null) {
      _issue(issues, 'homebrew-formula has no repository identity');
      return;
    }
    final project = unit.binaryProject;
    final archives = {
      for (final step in receipt.steps.where(
        (item) => item.name.startsWith('archive:'),
      ))
        step.name.substring('archive:'.length): PlatformAsset(
          name: step.outputs.single.path,
          sha256: step.outputs.single.sha256,
        ),
    };
    final expected = HomebrewFormula.render(
      className: HomebrewFormula.classNameFor(project.executable!),
      description: 'Released by rk',
      homepage: 'https://github.com/$repository',
      version: project.version.canonical,
      repository: repository,
      tag: unit.tag,
      executable: project.executable!,
      assets: archives,
    );
    final actual = File(
      stage.resolve(ReleaseAssets.formulaName(project.executable!)),
    );
    if (!actual.existsSync() || actual.readAsStringSync() != expected) {
      _issue(issues, 'homebrew-formula does not match the staged archives');
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

class _ContractStep {
  const _ContractStep(
    this.name, {
    this.inputs = const {},
    this.outputs = const {},
    this.optionalOutputs = const {},
    this.outputPrefix,
    this.outputType,
  });

  final String name;
  final Set<String> inputs;
  final Map<String, String> outputs;
  final Map<String, String> optionalOutputs;
  final String? outputPrefix;
  final String? outputType;
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
