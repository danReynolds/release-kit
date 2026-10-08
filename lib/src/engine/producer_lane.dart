import 'dart:io';

import 'resolve.dart';
import 'stage_source.dart';

/// A private export of the source for one producer chain.
///
/// Producer outputs meet in the stage, at paths owned by their platform.
/// Their working files do not: Dart and other tools may create `.dart_tool`
/// or similar scratch beneath the source tree, and one lane must never clean
/// or reuse another lane's transient state. The export lives outside the
/// repository and is removed after the lane drains.
final class ProducerLaneSource {
  ProducerLaneSource._(this.path);

  /// Exports what [project]'s producers read from [source] into a new
  /// directory of its own.
  ///
  /// A project's own declared build may read anything, so it gets the whole
  /// source. A Dart build gets the files Dart reads (see
  /// [StageSourceSnapshot.dartBuildInputs]) with every package in this
  /// source, which its workspace or an override may name.
  factory ProducerLaneSource.export(
    StageSourceSnapshot source, {
    required ResolvedProject project,
  }) {
    final directory = Directory.systemTemp.createTempSync('rk-lane-');
    try {
      source.export(
        directory.path,
        only: project.buildsAssets
            ? null
            : StageSourceSnapshot.dartBuildInputs(
                project.pubspec.directory,
                packages: source.packageDirectories,
              ),
      );
    } on Object {
      directory.deleteSync(recursive: true);
      rethrow;
    }
    return ProducerLaneSource._(directory.path);
  }

  /// The repository root a producer in this lane must use.
  final String path;

  /// Removes this lane's export.
  void close() {
    final directory = Directory(path);
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  }
}
