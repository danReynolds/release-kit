import 'dart:io';

/// The repository-local store that owns private release stages.
///
/// This boundary deliberately knows nothing about units, receipts, or public
/// targets. Cleanup must be able to remove orphaned and corrupt entries too;
/// interpreting release state belongs to status and release, not the store.
final class StageStore {
  StageStore(String repositoryRoot)
      : repositoryRoot = Directory(repositoryRoot).absolute.path;

  final String repositoryRoot;

  String get path => _join(repositoryRoot, '.rk', 'work', 'stages');

  /// Excludes cleanup from an active release that may write staged bytes.
  StageStoreLock acquireForMutation() {
    final work = _fixedDirectory(const ['.rk', 'work'], create: true)!;
    final lockPath = _join(work, 'stages.lock');
    final before = FileSystemEntity.typeSync(lockPath, followLinks: false);
    if (before != FileSystemEntityType.notFound &&
        before != FileSystemEntityType.file) {
      throw StageStoreUnsafe('stage lock is a symlink or non-file', lockPath);
    }

    final handle = File(lockPath).openSync(mode: FileMode.append);
    try {
      if (FileSystemEntity.typeSync(lockPath, followLinks: false) !=
          FileSystemEntityType.file) {
        throw StageStoreUnsafe(
          'stage lock changed into a symlink or non-file',
          lockPath,
        );
      }
      handle.lockSync(FileLock.exclusive);
      return StageStoreLock._(handle);
    } on StageStoreUnsafe {
      handle.closeSync();
      rethrow;
    } on FileSystemException {
      handle.closeSync();
      throw StageStoreBusy(lockPath);
    }
  }

  /// Inventories only immediate children of the canonical stage root.
  ///
  /// No receipt is required. A broken stage and a child symlink are still
  /// local residue an explicitly authorized clean must be able to remove.
  List<StageEntry> inventory() {
    final stages = _fixedDirectory(
      const ['.rk', 'work', 'stages'],
      create: false,
    );
    if (stages == null) return const [];

    final entries = <StageEntry>[];
    for (final entity
        in Directory(stages).listSync(followLinks: false, recursive: false)) {
      final name = _directName(stages, entity.path);
      entries.add(StageEntry(
        name: name,
        type: FileSystemEntity.typeSync(entity.path, followLinks: false),
      ));
    }
    entries.sort((left, right) => left.name.compareTo(right.name));
    return List<StageEntry>.unmodifiable(entries);
  }

  /// Deletes exactly the entries that were inventoried and still have the
  /// same no-follow entity type.
  ///
  /// The set may shrink after authorization, never grow: a stage created
  /// while a caller was deciding is not silently swept into the act. Dart's
  /// recursive deletion does not follow child links.
  bool deleteEntry(StageEntry entry) {
    _requireDirectName(entry.name);
    final stages = _fixedDirectory(
      const ['.rk', 'work', 'stages'],
      create: false,
    );
    if (stages == null) return false;
    final target = _join(stages, entry.name);
    final current = FileSystemEntity.typeSync(target, followLinks: false);
    if (current == FileSystemEntityType.notFound || current != entry.type) {
      return false;
    }
    Directory(target).deleteSync(recursive: true);
    return true;
  }

  String? _fixedDirectory(List<String> components, {required bool create}) {
    var current = repositoryRoot;
    if (FileSystemEntity.typeSync(current, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw StageStoreUnsafe(
        'repository root is a symlink or non-directory',
        current,
      );
    }
    for (final component in components) {
      current = _join(current, component);
      var type = FileSystemEntity.typeSync(current, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        if (!create) return null;
        Directory(current).createSync();
        type = FileSystemEntity.typeSync(current, followLinks: false);
      }
      if (type != FileSystemEntityType.directory) {
        throw StageStoreUnsafe(
          'stage path contains a symlink or non-directory',
          current,
        );
      }
    }
    return current;
  }

  static String _directName(String parent, String path) {
    final prefix = parent.endsWith(Platform.pathSeparator)
        ? parent
        : '$parent${Platform.pathSeparator}';
    if (!path.startsWith(prefix)) {
      throw StageStoreUnsafe('stage entry is outside its store', path);
    }
    final name = path.substring(prefix.length);
    _requireDirectName(name);
    return name;
  }

  static void _requireDirectName(String name) {
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains(r'\')) {
      throw ArgumentError('stage entry is not one direct path component');
    }
  }
}

final class StageEntry {
  const StageEntry({required this.name, required this.type});

  final String name;
  final FileSystemEntityType type;
}

final class StageStoreLock {
  StageStoreLock._(this._handle);

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

String _join(String first, String second, [String? third, String? fourth]) {
  final parts = [
    first,
    second,
    if (third != null) third,
    if (fourth != null) fourth,
  ];
  return parts.join(Platform.pathSeparator);
}
