import 'dart:convert';
import 'dart:io';

import '../transforms/digest.dart';
import 'assets.dart';
import 'atomic_file.dart';
import 'canonical_json.dart';
import 'diagnostic.dart';
import 'git.dart';
import 'receipt.dart';
import 'release_manifest.dart';
import 'resolve.dart';
import 'source_tree.dart';
import 'stage_plan.dart';
import 'stage_source.dart';
import 'timings.dart';
import 'unit_release.dart';

/// Increment this whenever the work a stage records changes: its names, the
/// files each writes, or the receipt's shape. The stage id hashes it, so a
/// stage another rk built is never taken for this one's.
const stageSchemaVersion = 17;

/// A stage's name: the commit and tree it is built from, the digest of its
/// plan (see `stagePlanFor`), and the schema.
final class StageId {
  StageId._(this.commit, this.tree, this.planSha256)
    : id = Sha256.hex(
        utf8.encode(
          CanonicalJson.encode({
            'head_commit': commit,
            'head_tree': tree,
            'plan_sha256': planSha256,
            'schema': stageSchemaVersion,
          }),
        ),
      );

  factory StageId.of({
    required String commit,
    required String tree,
    required Map<String, Object?> plan,
  }) => StageId._(
    commit,
    tree,
    Sha256.hex(utf8.encode(CanonicalJson.encode(plan))),
  );

  /// The id a receipt records, derived again from what it names: a receipt
  /// that names another stage is that stage's.
  factory StageId.fromJson(Object? json) {
    final map = json as Map<String, Object?>;
    return StageId._(
      map['head_commit'] as String,
      map['head_tree'] as String,
      map['plan_sha256'] as String,
    );
  }

  final String id;
  final String commit;
  final String tree;
  final String planSha256;

  Map<String, Object?> toJson() => {
    'head_commit': commit,
    'head_tree': tree,
    'id': id,
    'plan_sha256': planSha256,
  };
}

/// One unit's stage at one commit: `.rk/work/stages/<id>`, holding what a
/// release publishes and the receipt that records it.
///
/// rk trusts its own stage directory, as it trusts its own writes: a stage
/// is checked for what it publishes, not for how its directories are laid
/// out. Only a complete receipt, whose files are intact, makes them
/// reusable.
final class Stage {
  Stage({
    required String root,
    required this.id,
    required Map<String, Object?> plan,
    required this.source,
    DartSdk Function()? sdk,
  }) : path = '${Directory(root).absolute.path}/$_stages/${id.id}',
       relativePath = '$_stages/${id.id}',
       plan = CanonicalJson.normalize(plan) as Map<String, Object?>,
       _readSdk = sdk ?? DartSdk.ambient;

  final StageId id;

  /// Where the stage is, absolute for the tools that work on its files.
  final String path;

  /// Where the stage is from the repository root: what a person is shown,
  /// so a long checkout path does not wrap the id across lines.
  final String relativePath;

  /// What the stage is built from beyond its commit, recorded in the
  /// receipt so a person can read it.
  final Map<String, Object?> plan;

  /// The repository the stage is built from, read at its commit.
  final SourceTree source;

  /// The Dart SDK producers build with, read the first time one asks.
  DartSdk get sdk => _sdk ??= _readSdk();
  final DartSdk Function() _readSdk;
  DartSdk? _sdk;

  /// The receipt as this process last read or wrote it: what [check] found,
  /// with every piece of work recorded since.
  Receipt? get receipt => _receipt;
  Receipt? _receipt;

  /// A real path for [file], for the native tools that work on files.
  String pathOf(String file) => '$path/$file';

  /// [file]'s bytes, or null when it is not here.
  List<int>? readBytes(String file) {
    final handle = File(pathOf(file));
    return handle.existsSync() ? handle.readAsBytesSync() : null;
  }

  /// Places [bytes] at [file] by an atomic rename, so a crash leaves either
  /// the old bytes or the new.
  void write(String file, List<int> bytes) {
    final handle = File(pathOf(file));
    handle.parent.createSync(recursive: true);
    AtomicFile.write(handle.path, bytes);
  }

  /// What this stage is, for [release]: its receipt, checked against the
  /// files it records. An interrupted stage is checked for every file, since
  /// work resumes from them; a complete one for every file [release]
  /// publishes, which must all be recorded. The stage is named by
  /// everything that decides its work, so a complete stage lacks one only
  /// when an rk change forgot to bump [stageSchemaVersion].
  StageCheck check(UnitRelease release) =>
      Timings.spanSync('inspect stage ${release.unit.name}', () {
        _receipt = null;
        if (FileSystemEntity.typeSync(path) == FileSystemEntityType.notFound) {
          return StageCheck(
            StageState.absent,
            problems: const {_receiptFile: 'no completed stage receipt exists'},
          );
        }
        final file = File(pathOf(_receiptFile));
        if (!file.existsSync()) {
          return StageCheck(
            StageState.absent,
            problems: const {
              _receiptFile: 'files without a stage receipt are not reusable',
            },
          );
        }
        final Receipt receipt;
        try {
          receipt = Receipt.parse(file.readAsStringSync());
        } on Object catch (error) {
          return StageCheck(
            StageState.unreadable,
            problems: {_receiptFile: 'stage receipt is invalid: $error'},
          );
        }
        if (receipt.stage.id != id.id) {
          return StageCheck(
            StageState.unreadable,
            receipt: receipt,
            problems: const {
              _receiptFile: 'receipt identity does not name this stage',
            },
          );
        }
        _receipt = receipt;
        if (!receipt.complete) {
          final problems = {
            _receiptFile: 'receipt records an incomplete stage',
            for (final MapEntry(key: path, value: recorded)
                in receipt.files.entries)
              if (_problem(path, recorded) case final problem?) path: problem,
          };
          return StageCheck(
            problems.length == 1 ? StageState.resumable : StageState.broken,
            receipt: receipt,
            problems: problems,
          );
        }
        final problems = <String, String>{};
        for (final artifact in release.artifacts) {
          final recorded = receipt.files[artifact.path];
          final problem = recorded == null
              ? 'missing from the completed stage'
              : _problem(artifact.path, recorded);
          if (problem != null) problems[artifact.path] = problem;
        }
        return StageCheck(
          problems.isEmpty ? StageState.complete : StageState.changed,
          receipt: receipt,
          problems: problems,
        );
      });

  /// Starts this stage again: whatever is here goes, and a receipt holding
  /// only the plan takes its place.
  void begin() {
    Stages._delete(path);
    _write(Receipt(stage: id, plan: plan));
  }

  /// Records [work]: every file it writes, as it is now, and [evidence],
  /// with [warnings] kept so a reused stage says them again. The receipt is
  /// replaced by an atomic rename.
  void record(
    Work work, {
    Map<String, Object?> evidence = const {},
    Iterable<Diagnostic> warnings = const [],
  }) {
    final progress = _receipt;
    if (progress == null || progress.complete) {
      throw StateError('only a stage in progress records work');
    }
    _write(
      progress.recording(
        work.name,
        {...evidence, ...Receipt.keeping(warnings)},
        {for (final file in work.outputs) file: _capture(file, work.name)},
      ),
    );
  }

  /// Completes the stage once every other piece of [release]'s work is
  /// recorded: writes the release manifest, then records the barrier.
  ReleaseManifest complete(UnitRelease release) {
    final manifest = ReleaseManifest.of(release, _receipt!);
    write(ReleaseAssets.manifest, utf8.encode(manifest.encode()));
    record(
      release.barrier,
      evidence: {if (_sdk case final sdk?) 'dart_sdk': sdk.toJson()},
    );
    return manifest;
  }

  /// Removes those of [files] that the receipt does not record, so the work
  /// that writes them can run again: a crash between a write and its record
  /// leaves bytes no receipt vouches for.
  void discardUnrecorded(Iterable<String> files) {
    final recorded = _receipt?.files ?? const {};
    for (final file in files) {
      if (recorded.containsKey(file)) continue;
      final handle = File(pathOf(file));
      if (FileSystemEntity.typeSync(handle.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        handle.deleteSync();
      }
    }
  }

  /// The source this stage is built from, read once into memory: the
  /// committed bytes. Producers export it into directories of their own,
  /// never the mutable worktree.
  Future<StageSourceSnapshot> captureSource() =>
      StageSourceSnapshot.capture(source, commit: id.commit);

  void _write(Receipt receipt) {
    write(_receiptFile, utf8.encode(receipt.encode()));
    _receipt = receipt;
  }

  /// [file] as it is now, remembered so a check in this process need not
  /// read it again.
  StagedFile _capture(String file, String producer) {
    final handle = File(pathOf(file));
    final stat = handle.statSync();
    final bytes = handle.readAsBytesSync();
    final captured = StagedFile(
      producer: producer,
      size: bytes.length,
      sha256: Sha256.hex(bytes),
    );
    _noteDigested(handle.path, stat, captured.sha256);
    return captured;
  }

  /// What is wrong with [file], which the receipt records as [recorded];
  /// null when it is intact.
  String? _problem(String file, StagedFile recorded) {
    final handle = File(pathOf(file));
    // Within one run rk trusts its own writes: a file this process hashed
    // to the recorded digest, and that has not moved since, is not read
    // again. A later run reads and hashes it once.
    if (_stillStands(handle.path, recorded.sha256)) return null;
    if (!handle.existsSync()) return 'receipt artifact is missing';
    try {
      final stat = handle.statSync();
      final bytes = handle.readAsBytesSync();
      final sha256 = Sha256.hex(bytes);
      final differences = [
        if (bytes.length != recorded.size) 'size',
        if (sha256 != recorded.sha256) 'sha256',
      ];
      if (differences.isEmpty) {
        _noteDigested(handle.path, stat, sha256);
        return null;
      }
      return 'artifact ${differences.join(', ')} differs from the receipt';
    } on FileSystemException catch (error) {
      return 'artifact could not be read: ${error.message}';
    }
  }

  /// One file's cheap description: what a rewrite cannot leave untouched.
  /// Change time is the kernel's to set, so a rewrite shows.
  static String _describe(FileStat stat) => [
    stat.type,
    stat.size,
    stat.mode,
    stat.modified.microsecondsSinceEpoch,
    stat.changed.microsecondsSinceEpoch,
  ].join('\u0000');

  /// How each file looked when this process last read and digested it, by
  /// absolute path, shared by every view of every stage.
  static final Map<String, String> _digested = {};

  /// Remembers that [path] digested to [sha256] — provided it held still
  /// while it was read. A file rewritten during the read is not remembered,
  /// so the next check reads it again.
  static void _noteDigested(String path, FileStat beforeReading, String sha) {
    final settled = _describe(File(path).statSync());
    if (settled != _describe(beforeReading)) return;
    _digested[path] = '$settled\u0000$sha';
  }

  static bool _stillStands(String path, String sha256) {
    final when = _digested[path];
    return when != null &&
        when == '${_describe(File(path).statSync())}\u0000$sha256';
  }

  static const _stages = '.rk/work/stages';
  static const _receiptFile = 'stage.json';
}

/// A repository's stages: one per unit at this commit, and the lock and
/// listing `rk clean` works from.
final class Stages {
  Stages(String root) : root = Directory(root).absolute.path;

  final String root;

  String get path => '$root/${Stage._stages}';

  final Map<String, Stage> _stages = {};

  /// [unit]'s stage at [git]'s commit, the same one each time it is asked.
  Stage of(
    ResolvedUnit unit,
    GitState git,
    SourceTree source, {
    DartSdk Function()? sdk,
  }) => _stages.putIfAbsent(unit.name, () {
    final plan = stagePlanFor(unit, git);
    return Stage(
      root: root,
      id: StageId.of(commit: git.head, tree: git.headTree, plan: plan),
      plan: plan,
      source: source,
      sdk: sdk,
    );
  });

  /// Keeps `rk clean` out while a release may write staged bytes.
  StagesLock lock() {
    final work = '$root/.rk/work';
    final RandomAccessFile handle;
    try {
      Directory(work).createSync(recursive: true);
      handle = File('$work/stages.lock').openSync(mode: FileMode.append);
    } on FileSystemException catch (error) {
      throw StageStoreUnsafe(error.message, error.path ?? work);
    }
    try {
      handle.lockSync(FileLock.exclusive);
      return StagesLock._(handle);
    } on FileSystemException {
      handle.closeSync();
      throw StageStoreBusy('$work/stages.lock');
    }
  }

  /// What is in the stages directory, broken or not, without following a
  /// link: everything an authorized clean may remove.
  List<StageEntry> list() {
    final directory = Directory(path);
    if (!directory.existsSync()) return const [];
    return [
      for (final entity in directory.listSync(followLinks: false))
        StageEntry(
          name: entity.path.substring(path.length + 1),
          type: FileSystemEntity.typeSync(entity.path, followLinks: false),
        ),
    ]..sort((left, right) => left.name.compareTo(right.name));
  }

  /// Removes [entry], when it is still what was listed: the set a person
  /// authorized may shrink, never grow.
  bool remove(StageEntry entry) {
    final target = '$path/${entry.name}';
    if (FileSystemEntity.typeSync(target, followLinks: false) != entry.type) {
      return false;
    }
    _delete(target);
    return true;
  }

  /// Deletes [path] whole. A link is unlinked, never followed: clean deletes
  /// recursively, and a link could point anywhere.
  static void _delete(String path) {
    if (FileSystemEntity.typeSync(path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return;
    }
    Directory(path).deleteSync(recursive: true);
  }
}

final class StageEntry {
  const StageEntry({required this.name, required this.type});

  final String name;
  final FileSystemEntityType type;
}

final class StagesLock {
  StagesLock._(this._handle);

  final RandomAccessFile _handle;
  var _closed = false;

  void close() {
    if (_closed) return;
    _closed = true;
    try {
      _handle.unlockSync();
    } finally {
      _handle.closeSync();
    }
  }
}

final class StageStoreBusy implements Exception {
  StageStoreBusy(this.path);

  final String path;

  @override
  String toString() => 'another rk command is using staged work at $path';
}

final class StageStoreUnsafe implements Exception {
  StageStoreUnsafe(this.message, this.path);

  final String message;
  final String path;

  @override
  String toString() => '$message: $path';
}
