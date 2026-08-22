import 'assets.dart';
import 'checklist.dart';
import 'producers.dart';
import 'resolve.dart';
import 'targets.dart';
import '../targets/target_module.dart';

/// What a stage is making, grouped by its destination or local output.
///
/// The steps rk runs and the files it produces are not the same list: four
/// producers — build, sign, notarize, archive — make one macOS archive, and
/// naming each of them told the operator about rk's internals rather than
/// about their release. The rows here are the files, and a row narrates its
/// own production: it says which producer is working on it now, and when the
/// stage settles it says what that producer proved.
class StageBoard {
  StageBoard._(
    this.groups,
    this._rowsOf,
    this._progressRows,
    this._producersOf,
  );

  /// The rows one unit's stage will fill, in release order.
  ///
  /// A target that publishes no file of its own — a Git tag — contributes no
  /// group. A Homebrew formula is shown under Homebrew because it is private
  /// input to that destination, not a GitHub Release asset.
  /// pub.dev contributes one row per package: it uploads no file rk makes,
  /// but it does validate the staged source, and that check is the most
  /// common reason a release stops later than it should have.
  factory StageBoard.forUnit(
    ResolvedUnit unit,
    List<TargetPlan> targets,
    List<TargetStage> targetStages,
  ) {
    final groups = <StageBoardGroup>[];
    final rowsOf = <String, List<StageBoardRow>>{};
    final progressRows = <String, StageBoardRow>{};
    final producersOf = <StageBoardRow, Set<String>>{};

    void bind(String producer, StageBoardRow row) {
      rowsOf.putIfAbsent(producer, () => <StageBoardRow>[]).add(row);
      producersOf.putIfAbsent(row, () => <String>{}).add(producer);
    }

    for (final target in targets) {
      final rows = <StageBoardRow>[];
      for (final artifact in target.artifacts) {
        final row = StageBoardRow('${target.step.id}/$artifact', artifact);
        rows.add(row);
        if (artifact == ReleaseAssets.manifest) {
          bind('complete-stage', row);
        }
      }
      for (final stage in targetStages.where(
        (stage) => stage.target.step.id == target.step.id,
      )) {
        final outputBindings = <String>{};
        for (final view in stage.progress) {
          final output = view.output;
          if (output != null &&
              !stage.contract.step.outputs.containsKey(output)) {
            throw StateError(
              '${stage.contract.step.name} progress binds undeclared output '
              '$output',
            );
          }
          if (output != null && !outputBindings.add(output)) {
            throw StateError(
              '${stage.contract.step.name} binds output $output twice',
            );
          }
          final row = view.artifact == null
              ? StageBoardRow(
                  '${target.step.id}/${stage.contract.step.name}/${view.id}',
                  view.label!,
                )
              : rows.singleWhere(
                  (row) => row.name == view.artifact,
                  orElse: () => throw StateError(
                    '${stage.contract.step.name} binds undeclared artifact '
                    '${view.artifact}',
                  ),
                );
          if (!rows.contains(row)) rows.add(row);
          bind(stage.contract.step.name, row);
          progressRows['${stage.contract.step.name}/${view.id}'] = row;
        }
      }
      if (rows.isNotEmpty) {
        // Production order, not alphabetical. The manifest covers everything,
        // so listing it first would put the last row to fill at the top, where
        // a pending mark reads as skipped rather than as not yet.
        rows.sort(
            (left, right) => _rank(left.name).compareTo(_rank(right.name)));
        groups.add(StageBoardGroup(target.label, rows));
      }
    }

    final binaryProject = unit.binaryProject;
    final publishedArtifacts = {
      for (final target in targets) ...target.artifacts,
    };
    if (binaryProject != null) {
      final localRows = <StageBoardRow>[];
      for (final platform in [...binaryProject.binaryPlatforms]..sort()) {
        final publicName = ReleaseAssets.archiveName(
          binaryProject.executable!,
          binaryProject.version.canonical,
          platform,
        );
        if (!publishedArtifacts.contains(publicName)) {
          localRows.add(StageBoardRow(
            'local/${binaryProject.name}/$platform',
            ReleaseAssets.archivePath(binaryProject, platform),
          ));
        }
      }
      if (localRows.isNotEmpty) {
        groups.add(StageBoardGroup('Local binaries', localRows));
      }
    }

    // Every producer of one platform's binary reports against that
    // platform's archive: the binary itself never leaves the stage.
    for (final step in Checklist.localProducerSteps(unit)) {
      final platform = step.platform;
      final projectName = step.project;
      if (platform == null || projectName == null) continue;
      final project = unit.project(projectName);
      final publicArchive = ReleaseAssets.archiveName(
        project.executable!,
        project.version.canonical,
        platform,
      );
      final localArchive = ReleaseAssets.archivePath(project, platform);
      for (final group in groups) {
        for (final row in group.rows) {
          if (row.name == publicArchive || row.name == localArchive) {
            bind(receiptNameFor(step), row);
          }
        }
      }
    }

    return StageBoard._(
      List.unmodifiable(groups),
      Map.unmodifiable({
        for (final entry in rowsOf.entries)
          entry.key: List<StageBoardRow>.unmodifiable(entry.value),
      }),
      Map.unmodifiable(progressRows),
      Map.unmodifiable({
        for (final entry in producersOf.entries)
          entry.key: Set<String>.unmodifiable(entry.value),
      }),
    );
  }

  static int _rank(String name) {
    if (name == ReleaseAssets.manifest) return 3;
    return 0;
  }

  final List<StageBoardGroup> groups;
  final Map<String, List<StageBoardRow>> _rowsOf;
  final Map<String, StageBoardRow> _progressRows;
  final Map<StageBoardRow, Set<String>> _producersOf;

  /// The row a receipt producer reports against, when it has one. A
  /// producer whose output never reaches a target — release notes — has
  /// none, and says nothing.
  List<StageBoardRow> rowsFor(String producer) =>
      _rowsOf[producer] ?? const <StageBoardRow>[];

  StageBoardRow? progressRow(String producer, String id) =>
      _progressRows['$producer/$id'];

  Set<String> producersFor(StageBoardRow row) =>
      _producersOf[row] ?? const <String>{};

  bool get isEmpty => groups.isEmpty;
}

class StageBoardGroup {
  StageBoardGroup(this.label, Iterable<StageBoardRow> rows)
      : rows = List.unmodifiable(rows);

  final String label;
  final List<StageBoardRow> rows;
}

class StageBoardRow {
  StageBoardRow(this.id, this.name);

  final String id;
  final String name;
}
