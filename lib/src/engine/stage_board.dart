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
        final row = StageBoardRow('staged source');
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
        }
      }
      if (rows.isNotEmpty) groups.add(StageBoardGroup(target.label, rows));
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

  final List<StageBoardGroup> groups;
  final Map<String, StageBoardRow> _rowOf;

  /// The row a receipt producer reports against, when it has one. A
  /// producer whose output never reaches a target — release notes — has
  /// none, and says nothing.
  StageBoardRow? rowFor(String producer) => _rowOf[producer];

  bool get isEmpty => groups.isEmpty;

  /// The block a terminal shows while the stage fills, one line per row.
  ///
  /// The mark leads so the trailing column stays free for what the row has
  /// to say, and so nothing shifts sideways when the block settles.
  List<String> liveLines(String frame) => [
        for (final group in groups) ...[
          '    ${group.label}',
          for (final row in group.rows)
            _line(
              switch (row.state) {
                StageBoardRowState.pending => ' ',
                StageBoardRowState.active => frame,
                StageBoardRowState.done => '✓',
                StageBoardRowState.failed => '✗',
              },
              row.name,
              row.phase ?? (row.state == StageBoardRowState.done ? '' : ''),
            ),
        ],
      ];

  static String _line(String mark, String name, String note) {
    final label = '      $name';
    final padded = label.length >= 46 ? label : label.padRight(46);
    return note.isEmpty ? '$mark $label' : '$mark $padded $note';
  }
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
