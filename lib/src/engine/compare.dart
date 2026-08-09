import 'dart:io';

import '../transforms/digest.dart';
import 'pub_ignore.dart';
import 'source_tree.dart';
import 'tools.dart';
import 'verdict.dart';

// The comparator answers in the same [Inspection] vocabulary everything else
// speaks. It had its own result type for a while — field-for-field identical —
// and the cost of a second type over one vocabulary lands on whoever maps
// between them, which in phase 5 is the release verb.

/// Compares a published package archive against the source it claims to be.
///
/// This is the pub.dev target's core primitive. Pre-act status and release,
/// post-publish confirmation, and retries all use it through the same target
/// reader rather than maintaining a second historical-verification path.
///
/// The comparison is per-file byte equality, in both directions:
///
/// - every file in the archive must byte-match the file in the tree, and a
///   file the archive carries that the tree does not have is a conflict too —
///   content was published that the named source cannot account for;
/// - every tracked file under the package directory must be in the archive,
///   because a file at the tag missing from the archive means the archive was
///   built from something else.
///
/// What it cannot check, it says: pub's own file selection (`.pubignore`) is
/// not reinterpreted here, so when one is present the missing-from-archive
/// direction is reported as not fully checkable rather than guessed at.
///
/// Acknowledged alpha boundary: file *modes* are not compared because
/// `SourceTree` does not expose them. Entry type is checked, and regular-file
/// inventory and bytes are compared in both directions.
class Comparator {
  Comparator({required this.tools});

  final Tools tools;

  /// Whether pub excludes the file at this package-relative path from every
  /// archive, whatever the tree tracks: anything hidden — a dot beginning
  /// any path segment — and `pubspec.lock`.
  ///
  /// This is pub's own rule, not rk's judgment, and it is held to by evidence
  /// in both directions. The keybay_cli 0.1.0 archive carries none of the
  /// four dotfile shapes its tag tracks; the dart-lang/args 2.5.0 archive
  /// carries none of the `.github/` workflows its repository tracks — files
  /// whose *segment*, not basename, is hidden, which is why the rule reads
  /// the whole path. An earlier version that enumerated four basenames
  /// accused that genuine release of tampering. A wrong entry here silently
  /// exempts a file from verification, which is why the rule is a frozen
  /// predicate with vectors rather than a growable set.
  static bool pubExcludes(String relativePath) =>
      relativePath.split('/').any((segment) => segment.startsWith('.')) ||
      relativePath.split('/').last == 'pubspec.lock';

  /// Compares [archive] (a `.tar.gz` as bytes) against the files under
  /// [packageDirectory] in [tree].
  Future<Inspection> compare({
    required List<int> archive,
    required SourceTree tree,
    required String packageDirectory,
  }) async {
    final scratch = Directory.systemTemp.createTempSync('rk-compare-');
    try {
      final path = '${scratch.path}/archive.tar.gz';
      File(path).writeAsBytesSync(archive);
      final extracted = Directory('${scratch.path}/contents')..createSync();

      final opened = await tools.run(
        'tar',
        ['-xzf', path, '-C', extracted.path],
      );
      if (!opened.ok) {
        return Inspection.unknown(
          'the published archive could not be opened: ${opened.summary}',
        );
      }

      return _compareExtracted(extracted, tree, packageDirectory);
    } finally {
      scratch.deleteSync(recursive: true);
    }
  }

  Inspection _compareExtracted(
    Directory extracted,
    SourceTree tree,
    String packageDirectory,
  ) {
    final prefix = packageDirectory == '.' ? '' : '$packageDirectory/';
    final evidence = <String, String>{};

    // Direction one: everything published must be accounted for by the tree.
    final inArchive = <String>{};
    for (final entry
        in extracted.listSync(recursive: true, followLinks: false)) {
      if (entry is Directory) continue;
      final relative = entry.path.substring(extracted.path.length + 1);
      if (entry is! File) {
        // pub publishes regular files, full stop. A symlink in an archive is
        // an entry the source cannot account for whatever it points at — and
        // skipping it made a dangling link invisible, so an archive carrying
        // one read as byte-identical.
        evidence[relative] = 'not a regular file — pub never publishes these';
        continue;
      }
      inArchive.add(relative);

      final atSource = tree.readBytes('$prefix$relative');
      if (atSource == null) {
        evidence[relative] = 'in the archive, not in the source';
        continue;
      }
      final published = entry.readAsBytesSync();
      if (Sha256.hex(published) != Sha256.hex(atSource)) {
        evidence[relative] = 'differs';
      }
    }

    // Direction two: everything the source has must have been published —
    // unless pub's own selection excludes it. A `.pubignore` is read and
    // applied when rk understands every pattern in it, and declared
    // unjudgeable when it does not: guessing at a pattern would silence a
    // file that is genuinely missing, which is the one direction of error
    // this comparison must never make.
    final pubignoreSource = tree.read('$prefix.pubignore');
    final pubignore =
        pubignoreSource == null ? null : PubIgnore.parse(pubignoreSource);
    final readable = pubignore == null || pubignore.isComplete;
    var unverifiable = 0;
    for (final tracked in tree.trackedFiles()) {
      if (prefix.isNotEmpty && !tracked.startsWith(prefix)) continue;
      final relative = tracked.substring(prefix.length);
      if (pubExcludes(relative)) continue;
      if (inArchive.contains(relative)) continue;
      if (pubignore != null && readable && pubignore.excludes(relative)) {
        continue;
      }
      if (pubignore != null && !readable) {
        unverifiable++;
        continue;
      }
      evidence[relative] = 'in the source, missing from the archive';
    }

    if (evidence.isNotEmpty) {
      return Inspection.conflict(
        'the published archive is not the source at this ref',
        evidence: evidence,
      );
    }
    if (unverifiable > 0) {
      // Honest partial: the archive-side check passed in full, but rk cannot
      // say whether these files were meant to be excluded or lost.
      return Inspection.unknown(
        'every published file matches, and $unverifiable tracked '
        'file${unverifiable == 1 ? '' : 's'} absent from the archive '
        'cannot be judged — the .pubignore uses patterns rk will not guess '
        'at: ${pubignore!.unsupported.join(', ')}',
      );
    }
    return Inspection.exact(
      detail: '${inArchive.length} files, byte-identical',
    );
  }
}
