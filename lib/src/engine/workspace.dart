import 'dart:io';

/// Where a release keeps its intermediates, addressed by name.
///
/// This is CI seam 3, placed where it earns its keep: the binary chain is the
/// one component that produces and consumes artifacts, and it used to take a
/// `String` path and interpolate — the interface existed once before, around
/// a two-file diagnosis writer, and was deleted for abstracting the wrong
/// thing. Callers name artifacts; only the workspace knows where they live.
/// Locally that is a directory; in CI it becomes the run's artifact store
/// without the chain changing.
///
/// It is a cache, not memory: keyed by release and commit (the caller builds
/// the key), never seeded from a different run, and deleting it is always
/// safe — everything here can be rebuilt, and the only artifacts a re-run
/// may reuse are those an external authority can re-verify (a signed binary,
/// a notarized zip), which is checked at inspection, not assumed from
/// existence.
abstract interface class Workspace {
  /// The artifact's bytes, or null when it is not here.
  List<int>? readBytes(String name);

  /// Re-reads [name] from its [pathOf] location after a native tool wrote
  /// there. A directory workspace has nothing to do; a memory one pulls the
  /// spilled file back in, so the two stay interchangeable to the chain.
  void ingest(String name);

  void write(String name, List<int> bytes);

  bool exists(String name);

  /// A real filesystem path for [name], for the native tools — codesign,
  /// ditto, tar — that operate on files. The path is the workspace's to
  /// mint; a caller that assembles its own has re-created the seam this
  /// interface closes.
  String pathOf(String name);
}

/// A directory under `.rk/work/`.
class DirectoryWorkspace implements Workspace {
  DirectoryWorkspace(this.root);

  /// `<repo>/.rk/work/<tag>-<shortHead>`, typically.
  final String root;

  @override
  List<int>? readBytes(String name) {
    final file = File(pathOf(name));
    return file.existsSync() ? file.readAsBytesSync() : null;
  }

  @override
  void write(String name, List<int> bytes) {
    // Created on first use, not at construction: a run that never produces
    // an artifact — every pub.dev-only release — leaves no directory behind.
    final file = File(pathOf(name));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
  }

  @override
  void ingest(String name) {
    // The file already lives at pathOf; nothing to move.
  }

  @override
  bool exists(String name) => File(pathOf(name)).existsSync();

  @override
  String pathOf(String name) {
    if (name.split('/').contains('..')) {
      throw ArgumentError('artifact names stay inside the workspace: $name');
    }
    return '$root/$name';
  }
}

/// In memory, for tests — with real temp files minted only when a native
/// tool genuinely needs a path.
///
/// Interchangeable with [DirectoryWorkspace] on purpose, including for a
/// file a native tool wrote at [pathOf] that nothing has ingested yet: the
/// directory workspace sees it, so this one must too. When it did not, the
/// reuse branch that consults `exists` before any ingest was unreachable
/// under the memory workspace — and therefore under every test.
class MemoryWorkspace implements Workspace {
  MemoryWorkspace();

  final Map<String, List<int>> _artifacts = {};
  Directory? _spill;

  File? _spilled(String name) {
    final spill = _spill;
    if (spill == null) return null;
    final file = File('${spill.path}/$name');
    return file.existsSync() ? file : null;
  }

  @override
  List<int>? readBytes(String name) =>
      _artifacts[name] ?? _spilled(name)?.readAsBytesSync();

  @override
  void write(String name, List<int> bytes) => _artifacts[_guard(name)] = bytes;

  @override
  void ingest(String name) {
    final file = _spilled(name);
    if (file != null) _artifacts[name] = file.readAsBytesSync();
  }

  @override
  bool exists(String name) =>
      _artifacts.containsKey(name) || _spilled(name) != null;

  @override
  String pathOf(String name) {
    final spill = _spill ??= Directory.systemTemp.createTempSync('rk-ws-');
    final file = File('${spill.path}/${_guard(name)}')
      ..parent.createSync(recursive: true);
    final bytes = _artifacts[name];
    if (bytes != null) file.writeAsBytesSync(bytes);
    return file.path;
  }

  static String _guard(String name) {
    if (name.split('/').contains('..')) {
      throw ArgumentError('artifact names stay inside the workspace: $name');
    }
    return name;
  }

  /// What was written, by name — the assertion surface.
  Iterable<String> get names => _artifacts.keys;
}
