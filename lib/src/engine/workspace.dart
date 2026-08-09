import 'dart:io';

import 'atomic_file.dart';

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
/// It is not authority, and existence is never sufficient evidence for reuse.
/// Trusted staged reuse is established by the content-addressed receipt in
/// `stage_receipt.dart`. Deletion fails closed, but a binary stage must be
/// retained while its public targets are only partially complete because its
/// signed and notarized bytes cannot be recreated exactly.
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

/// A directory-backed workspace.
class DirectoryWorkspace implements Workspace {
  DirectoryWorkspace(this.root);

  /// The caller owns the directory layout. New release stages use
  /// `<repo>/.rk/work/stages/<stage-id>`.
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
    AtomicFile.write(file.path, bytes);
  }

  @override
  void ingest(String name) {
    // The file already lives at pathOf; nothing to move.
    _artifactName(name);
  }

  @override
  bool exists(String name) => File(pathOf(name)).existsSync();

  @override
  String pathOf(String name) => '$root/${_artifactName(name)}';
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
    name = _guard(name);
    final spill = _spill;
    if (spill == null) return null;
    final file = File('${spill.path}/$name');
    return file.existsSync() ? file : null;
  }

  @override
  List<int>? readBytes(String name) =>
      _artifacts[_guard(name)] ?? _spilled(name)?.readAsBytesSync();

  @override
  void write(String name, List<int> bytes) => _artifacts[_guard(name)] = bytes;

  @override
  void ingest(String name) {
    name = _guard(name);
    final file = _spilled(name);
    if (file != null) _artifacts[name] = file.readAsBytesSync();
  }

  @override
  bool exists(String name) =>
      _artifacts.containsKey(_guard(name)) || _spilled(name) != null;

  @override
  String pathOf(String name) {
    final spill = _spill ??= Directory.systemTemp.createTempSync('rk-ws-');
    final file = File('${spill.path}/${_guard(name)}')
      ..parent.createSync(recursive: true);
    final bytes = _artifacts[name];
    if (bytes != null) file.writeAsBytesSync(bytes);
    return file.path;
  }

  static String _guard(String name) => _artifactName(name);

  /// What was written, by name — the assertion surface.
  Iterable<String> get names => _artifacts.keys;
}

String _artifactName(String name) {
  final parts = name.split('/');
  final drive = RegExp(r'^[A-Za-z]:');
  if (name.isEmpty ||
      name.startsWith('/') ||
      name.startsWith('\\') ||
      name.contains('\\') ||
      name.contains('\u0000') ||
      drive.hasMatch(name) ||
      parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
    throw ArgumentError('artifact names stay inside the workspace: $name');
  }
  return name;
}
