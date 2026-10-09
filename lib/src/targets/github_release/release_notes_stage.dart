import 'dart:convert';

import '../../engine/changelog.dart';
import '../../engine/diagnostic.dart';
import '../../engine/resolve.dart';
import '../../engine/source_tree.dart';
import '../../engine/unit_release.dart';
import '../../output/output.dart';
import '../target_module.dart';

/// Stages GitHub's private release body: the changelog entries for the
/// release, extracted from the commit the stage names, and recorded and
/// verified like any other output.
///
/// It lives here so the module itself remains a readable account of the
/// public target lifecycle.
Future<Produced> prepareReleaseNotes(StageRun run, Work work) async {
  final unit = run.unit;
  final notes = _releaseNotes(unit, run.source);
  if (notes == null) {
    run.output.problem(
      Diagnostic(
        code: 'RK-CHG-003',
        message:
            'the changelog entries for ${unit.version} '
            'could not be extracted',
        source: unit.location,
        remedy:
            'validation saw a heading for it; the file changed since, '
            'or this is a bug in rk',
      ),
    );
    return const Produced.failed(HaltKind.beforeActing);
  }
  if (notes.isEmpty) {
    run.output.problem(
      Diagnostic(
        code: 'RK-CHG-004',
        message:
            'the changelog entries for ${unit.version} '
            'are empty',
        source: unit.location,
        remedy:
            'the release body is this entry — write what changed '
            'under each ${unit.version} heading',
      ),
    );
    return const Produced.failed(HaltKind.beforeActing);
  }

  run.stage.write(work.outputs.single, utf8.encode(notes));
  return const Produced();
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
