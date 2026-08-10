import 'dart:io';

import 'atomic_file.dart';

/// Where a release keeps its intermediates, addressed by name.
///
/// The binary chain is the one component that produces and consumes
/// artifacts, and it used to take a `String` path and interpolate. Callers
/// name artifacts; only the workspace knows where they live — today a
/// directory under the stage, `<repo>/.rk/work/stages/<stage-id>`.
///
/// It is not authority, and existence is never sufficient evidence for reuse.
/// Trusted staged reuse is established by the content-addressed receipt in
/// `stage_receipt.dart`. Deletion fails closed, but a binary stage must be
/// retained while its public targets are only partially complete because its
/// signed and notarized bytes cannot be recreated exactly.
class Workspace {
  Workspace(this.root);

  /// The caller owns the directory layout.
  final String root;

  /// The artifact's bytes, or null when it is not here.
  List<int>? readBytes(String name) {
    final file = File(pathOf(name));
    return file.existsSync() ? file.readAsBytesSync() : null;
  }

  void write(String name, List<int> bytes) {
    // Created on first use, not at construction: a run that never produces
    // an artifact — every pub.dev-only release — leaves no directory behind.
    final file = File(pathOf(name));
    file.parent.createSync(recursive: true);
    AtomicFile.write(file.path, bytes);
  }

  bool exists(String name) => File(pathOf(name)).existsSync();

  /// A real filesystem path for [name], for the native tools — codesign,
  /// ditto, tar — that operate on files. The path is the workspace's to
  /// mint; a caller that assembles its own has re-created the seam this
  /// class closes.
  String pathOf(String name) => '$root/${_artifactName(name)}';
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
