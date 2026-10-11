import 'dart:io';

import '../builds/binary_artifact.dart';
import '../engine/tools.dart';
import '../transforms/archive.dart';
import '../transforms/digest.dart';
import 'model.dart';

/// Install one recorded release archive into a fresh, caller-owned directory.
/// Local stages and GitHub downloads use the same checksum, layout and smoke
/// check. The caller commits its installation only after this succeeds.
Future<BinaryArtifact> installArchive({
  required ArchiveReader archive,
  required String version,
  required Directory directory,
  required Tools tools,
}) async {
  directory.createSync(recursive: true);
  archive.extractTo(directory);
  final smoke = await tools.run(
    '${directory.path}/${archive.artifact.entryPoint}',
    ['--version'],
    timeout: const Duration(minutes: 2),
  );
  if (!smoke.ok || !smoke.stdout.contains(version)) {
    throw InstallationFailure.withEvidence(
      'The installed command did not report $version.',
      remedy: smoke.summary,
      evidence: smoke.transcript,
    );
  }
  return archive.artifact;
}

/// Check every entry before writing any: no links, arbitrary paths or unknown
/// bundle layouts, and the program it ships must be the one requested.
Future<ArchiveReader> decodeInstallationArchive(
  List<int> compressed,
  String command, {
  int? size,
  String? sha256,
}) async {
  if ((size != null && compressed.length != size) ||
      (sha256 != null && Sha256.hex(compressed) != sha256)) {
    throw const InstallationFailure(
      'The release archive failed its recorded checksum.',
    );
  }
  try {
    final archive = ArchiveReader.decode(compressed);
    if (archive.artifact.command != command) {
      throw const FormatException('The archive exports a different command.');
    }
    return archive;
  } on FormatException catch (error) {
    throw InstallationFailure(
      'The release archive does not match its executable layout.',
      error.message,
    );
  }
}
