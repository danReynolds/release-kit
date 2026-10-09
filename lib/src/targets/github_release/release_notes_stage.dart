import 'dart:convert';

import '../../engine/changelog.dart';
import '../../engine/diagnostic.dart';
import '../../engine/resolve.dart';
import '../../engine/source_tree.dart';
import '../../engine/stage_contract.dart';
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
  // The notes are extracted from the commit the stage names; their bytes are
  // recorded and verified like any other output.
  const contract = StageStepContract(
    'release-notes',
    outputs: {'release-notes.md': 'notes'},
  );
  return TargetStage(
    target: target,
    contract: contract,
    planLabel: 'release notes',
    prepare: (context) => _prepareReleaseNotes(context),
  );
}

Future<TargetStageOutcome> _prepareReleaseNotes(
  TargetStageContext context,
) async {
  final receiptName = context.contract.name;
  final notes = _releaseNotes(context.stage.unit, context.source);
  if (notes == null) {
    return TargetStageFailure(
      Diagnostic(
        code: 'RK-CHG-003',
        message:
            'the changelog entries for ${context.stage.unit.version} '
            'could not be extracted',
        source: context.stage.unit.location,
        remedy:
            'validation saw a heading for it; the file changed since, '
            'or this is a bug in rk',
      ),
    );
  }
  if (notes.isEmpty) {
    return TargetStageFailure(
      Diagnostic(
        code: 'RK-CHG-004',
        message:
            'the changelog entries for ${context.stage.unit.version} '
            'are empty',
        source: context.stage.unit.location,
        remedy:
            'the release body is this entry — write what changed '
            'under each ${context.stage.unit.version} heading',
      ),
    );
  }

  context.workspace.write('release-notes.md', utf8.encode(notes));
  return TargetStageSuccess(
    StageStep(
      name: receiptName,
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
    final body = contents == null
        ? null
        : Changelog.entry(contents, project.version);
    if (body == null) return null;
    entries.add((project: project.name, body: body));
  }
  if (entries.length == 1) return entries.single.body;
  return entries
      .map((entry) => '## ${entry.project}\n\n${entry.body}')
      .join('\n\n');
}
