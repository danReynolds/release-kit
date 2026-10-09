import 'assets.dart';
import 'publish_target.dart';
import 'unit_release.dart';

/// What a stage is making, grouped by its destination or local output.
///
/// The steps rk runs and the files it produces are not the same list: four
/// producers — build, sign, notarize, archive — make one macOS archive, and
/// naming each of them told the operator about rk's internals rather than
/// about their release. The rows here are the files, and a row narrates its
/// own production: it says which producer is working on it now, and when the
/// stage settles it says what that producer proved.
class StageBoard {
  StageBoard._(this.groups, this._rowsOf, this._producersOf);

  /// The rows one unit's stage will fill, in release order.
  ///
  /// A target that publishes no file of its own — a Git tag — contributes no
  /// group. A Homebrew formula is shown under Homebrew because it is private
  /// input to that destination, not a GitHub Release asset.
  /// pub.dev contributes one row per package: it uploads no file rk makes,
  /// but it does validate the staged source, and that check is the most
  /// common reason a release stops later than it should have. A formula
  /// fills its own artifact's row; release notes reach no row.
  factory StageBoard.forUnit(UnitRelease release) {
    final unit = release.unit;
    final groups = <StageBoardGroup>[];
    final rowsOf = <String, List<StageBoardRow>>{};
    final producersOf = <StageBoardRow, Set<String>>{};

    void bind(String producer, StageBoardRow row) {
      rowsOf.putIfAbsent(producer, () => <StageBoardRow>[]).add(row);
      producersOf.putIfAbsent(row, () => <String>{}).add(producer);
    }

    for (final target in release.targets) {
      final rows = <StageBoardRow>[];
      for (final artifact in target.artifacts) {
        final row = StageBoardRow('${target.id}/$artifact', artifact);
        rows.add(row);
        if (artifact == ReleaseAssets.manifest) {
          bind('complete-stage', row);
        }
      }
      if (target.preparedBy case final work?) {
        switch (work.target) {
          case PublishTarget.pubDev:
            final row = StageBoardRow(
              '${target.id}/${work.name}/source',
              'package archive',
            );
            rows.add(row);
            bind(work.name, row);
          case PublishTarget.homebrew:
            bind(
              work.name,
              rows.singleWhere(
                (row) =>
                    row.name ==
                    ReleaseAssets.formulaName(work.project!.executable!),
              ),
            );
          case _:
            break;
        }
      }
      if (rows.isNotEmpty) {
        // Production order, not alphabetical. The manifest covers everything,
        // so listing it first would put the last row to fill at the top, where
        // a pending mark reads as skipped rather than as not yet.
        rows.sort(
          (left, right) => _rank(left.name).compareTo(_rank(right.name)),
        );
        groups.add(StageBoardGroup(target.label, rows));
      }
    }

    final binaryProject = unit.binaryProject;
    final publishedArtifacts = {
      for (final target in release.targets) ...target.artifacts,
    };
    if (binaryProject != null) {
      final localRows = <StageBoardRow>[];
      for (final platform in [...binaryProject.binaryPlatforms]..sort()) {
        final publicName = ReleaseAssets.archiveName(
          binaryProject.executable!,
          binaryProject.version.canonical,
          platform,
        );
        // Named as the file is: the path inside the stage means nothing to
        // a reader, and the stage says where its archives are.
        if (!publishedArtifacts.contains(publicName)) {
          localRows.add(
            StageBoardRow('local/${binaryProject.name}/$platform', publicName),
          );
        }
      }
      if (localRows.isNotEmpty) {
        groups.add(StageBoardGroup('Local binaries', localRows));
      }
    }

    // Every producer of one platform's binary reports against that
    // platform's archive: the binary itself never leaves the stage.
    for (final work in release.work) {
      final platform = work.platform;
      final project = work.project;
      if (project == null || work.kind == StepKind.targetStage) continue;
      if (work.kind == StepKind.buildAssets) {
        // A project's own build writes every asset it declares at once.
        final built = {
          for (final declared in project.assets)
            ReleaseAssets.assetName(declared),
        };
        for (final group in groups) {
          for (final row in group.rows) {
            if (built.contains(row.name)) bind(work.name, row);
          }
        }
        continue;
      }
      if (platform == null) continue;
      final publicArchive = ReleaseAssets.archiveName(
        project.executable!,
        project.version.canonical,
        platform,
      );
      final localArchive = ReleaseAssets.archivePath(project, platform);
      for (final group in groups) {
        for (final row in group.rows) {
          if (row.name == publicArchive || row.name == localArchive) {
            bind(work.name, row);
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
  final Map<StageBoardRow, Set<String>> _producersOf;

  /// The row a receipt producer reports against, when it has one. A
  /// producer whose output never reaches a target — release notes — has
  /// none, and says nothing.
  List<StageBoardRow> rowsFor(String producer) =>
      _rowsOf[producer] ?? const <StageBoardRow>[];

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
