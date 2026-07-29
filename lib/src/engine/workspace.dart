import 'dart:io';

/// Where a run keeps what it produces, addressed by name.
///
/// Named rather than pathed on purpose (CI readiness, seam 3): locally this is
/// a directory under the repository, and in CI it is the run's artifact store.
/// A caller that builds paths would have to be rewritten for the second case,
/// so no caller builds paths.
abstract interface class Workspace {
  /// Stores [contents] under [name], replacing anything already there.
  void put(String name, String contents);

  /// Where [name] ended up, in whatever terms this workspace can be spoken
  /// about — a path locally — so rk can tell an operator where to look.
  String describe(String name);
}

/// A workspace under `.rk/` in the repository.
class DirectoryWorkspace implements Workspace {
  DirectoryWorkspace(this.root);

  /// The repository root; `.rk` is created beneath it on first write.
  final String root;

  @override
  void put(String name, String contents) {
    final file = File(describe(name));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
  }

  @override
  String describe(String name) => '$root/.rk/$name';
}

/// A workspace that keeps everything in memory, for tests and for a dry run
/// that must produce nothing on disk.
class MemoryWorkspace implements Workspace {
  final Map<String, String> entries = {};

  @override
  void put(String name, String contents) => entries[name] = contents;

  @override
  String describe(String name) => 'memory:$name';
}
