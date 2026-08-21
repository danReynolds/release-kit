import 'dart:convert';
import 'dart:io';

import '../../engine/changelog.dart';
import '../../engine/diagnostic.dart';
import '../../engine/resolve.dart';
import '../../engine/source_tree.dart';
import '../../engine/stage_contract.dart';
import '../../engine/stage_inspection.dart';
import '../../engine/stage_receipt.dart';
import '../../engine/targets.dart';
import '../target_module.dart';

/// GitHub's private release-body contribution to the reusable stage.
///
/// The target module chooses this contribution. Its extraction and receipt
/// validation live here so the module itself remains a readable account of
/// the public target lifecycle.
TargetStage githubReleaseNotesStage({
  required ResolvedUnit unit,
  required TargetPlan target,
}) {
  final contract = StageContributionContract(
    step: StageStepContract(
      'release-notes',
      inputs: const {'step:source-snapshot'},
      outputs: const {'release-notes.md': 'notes'},
      validate: (context, step) {
        final expected = _releaseNotes(
          unit,
          SnapshotSourceTree(context.sourceRoot),
        );
        final actual = File(context.stage.resolve('release-notes.md'));
        if (expected != null &&
            actual.existsSync() &&
            actual.readAsStringSync() == expected) {
          return const [];
        }
        return const [
          StageIssue(
            StageIssueKind.invalidStructure,
            'release-notes does not match the staged changelog entry',
            path: 'stage.json',
          ),
        ];
      },
    ),
  );
  return TargetStage(
    target: target,
    contract: contract,
    prepare: (context) => _prepareReleaseNotes(context),
  );
}

Future<TargetStageOutcome> _prepareReleaseNotes(
  TargetStageContext context,
) async {
  final receiptName = context.contract.step.name;
  final source = SnapshotSourceTree(context.stage.sourceRoot);
  final notes = _releaseNotes(context.stage.unit, source);
  if (notes == null) {
    return TargetStageFailure(
      Diagnostic(
        code: 'RK-CHG-003',
        message: 'the changelog entries for ${context.stage.unit.version} '
            'could not be extracted',
        source: context.stage.unit.location,
        remedy: 'validation saw a heading for it; the file changed since, '
            'or this is a bug in rk',
      ),
    );
  }
  if (notes.isEmpty) {
    return TargetStageFailure(
      Diagnostic(
        code: 'RK-CHG-004',
        message: 'the changelog entries for ${context.stage.unit.version} '
            'are empty',
        source: context.stage.unit.location,
        remedy: 'the release body is this entry — write what changed '
            'under each ${context.stage.unit.version} heading',
      ),
    );
  }

  context.workspace.write('release-notes.md', utf8.encode(notes));
  return TargetStageSuccess(
    StageStep(
      name: receiptName,
      inputs: [StageInput.step(context.sourceStep)],
      outputs: [
        StageArtifact.capture(
          stage: context.stage.directory,
          path: 'release-notes.md',
          type: 'notes',
        ),
      ],
    ),
  );
}

String? _releaseNotes(ResolvedUnit unit, SourceTree source) {
  final entries = <({String project, String body})>[];
  for (final project in unit.projects) {
    final contents = source.read(project.fileAt('CHANGELOG.md'));
    final body =
        contents == null ? null : Changelog.entry(contents, project.version);
    if (body == null) return null;
    entries.add((project: project.name, body: body));
  }
  if (entries.length == 1) return entries.single.body;
  return entries
      .map((entry) => '## ${entry.project}\n\n${entry.body}')
      .join('\n\n');
}
