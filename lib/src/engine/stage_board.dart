import 'assets.dart';
import 'checklist.dart';
import 'producers.dart';
import 'resolve.dart';
import 'targets.dart';

/// What a stage is making, grouped by the target that will publish it.
///
/// The steps rk runs and the files it produces are not the same list: four
/// producers — build, sign, notarize, archive — make one macOS archive, and
/// naming each of them told the operator about rk's internals rather than
/// about their release. The rows here are the files, and a row narrates its
/// own production: it says which producer is working on it now, and when the
/// stage settles it says what that producer proved.
class StageBoard {
  StageBoard._(this.groups, this._rowOf);

  /// The rows one unit's stage will fill, in publication order.
  ///
  /// A target that publishes no file of its own — a Git tag, a Homebrew
  /// formula that ships inside the GitHub release — contributes no group.
  /// pub.dev contributes one row per package: it uploads no file rk makes,
  /// but it does validate the staged source, and that check is the most
  /// common reason a release stops later than it should have.
  factory StageBoard.forUnit(
      ResolvedUnit unit, List<TargetExpectation> targets) {
    final groups = <StageBoardGroup>[];
    final rowOf = <String, StageBoardRow>{};

    for (final target in targets) {
      final rows = <StageBoardRow>[];
      if (target.kind == 'pubDev') {
        final row = StageBoardRow('package source');
        rows.add(row);
        rowOf['pub-preflight:${target.project!.name}'] = row;
      }
      for (final artifact in target.artifacts) {
        final row = StageBoardRow(artifact);
        rows.add(row);
        if (artifact == ReleaseAssets.checksums) {
          rowOf['checksums'] = row;
        } else if (artifact == ReleaseAssets.manifest) {
          rowOf['complete-stage'] = row;
        } else if (artifact.endsWith('.rb')) {
          // Without this the formula row never completed, and `○` — added
          // because blank read as skipped — was left on the one file that
          // had in fact been produced.
          rowOf['homebrew-formula'] = row;
        }
      }
      if (rows.isNotEmpty) {
        // Production order, not alphabetical. Checksums cover the archives
        // and the manifest covers everything, so listing them first put the
        // last rows to fill at the top, where a pending mark reads as
        // skipped rather than as not yet.
        rows.sort(
            (left, right) => _rank(left.name).compareTo(_rank(right.name)));
        groups.add(StageBoardGroup(target.label, rows));
      }
    }

    // Every producer of one platform's binary reports against that
    // platform's archive: the binary itself never leaves the stage.
    if (unit.shipsBinaries) {
      final project = unit.binaryProject;
      for (final step in Checklist.localProducerSteps(unit)) {
        final platform = step.platform;
        if (platform == null) continue;
        final archive = ReleaseAssets.archiveName(
          project.executable!,
          project.version.canonical,
          platform,
        );
        for (final group in groups) {
          for (final row in group.rows) {
            if (row.name == archive) rowOf[receiptNameFor(step)] = row;
          }
        }
      }
    }

    return StageBoard._(List.unmodifiable(groups), rowOf);
  }

  static int _rank(String name) {
    if (name == ReleaseAssets.checksums) return 2;
    if (name == ReleaseAssets.manifest) return 3;
    if (name.endsWith('.rb')) return 1;
    return 0;
  }

  final List<StageBoardGroup> groups;
  final Map<String, StageBoardRow> _rowOf;

  /// The row a receipt producer reports against, when it has one. A
  /// producer whose output never reaches a target — release notes — has
  /// none, and says nothing.
  StageBoardRow? rowFor(String producer) => _rowOf[producer];

  bool get isEmpty => groups.isEmpty;
}

class StageBoardGroup {
  StageBoardGroup(this.label, Iterable<StageBoardRow> rows)
      : rows = List.unmodifiable(rows);

  final String label;
  final List<StageBoardRow> rows;
}

class StageBoardRow {
  StageBoardRow(this.name);

  final String name;

  /// What is being done to it now, while it is being done.
  String? phase;

  /// What its producers proved, once they have.
  String? note;

  StageBoardRowState state = StageBoardRowState.pending;

  void begin(String doing) {
    phase = doing;
    state = StageBoardRowState.active;
  }

  void finish({String? note}) {
    phase = null;
    state = StageBoardRowState.done;
    if (note != null) this.note = note;
  }

  void fail(String reason) {
    phase = null;
    note = reason;
    state = StageBoardRowState.failed;
  }
}

enum StageBoardRowState { pending, active, done, failed }
