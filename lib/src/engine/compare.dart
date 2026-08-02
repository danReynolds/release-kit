import 'dart:io';

import '../transforms/digest.dart';
import 'source_tree.dart';
import 'tools.dart';
import 'verdict.dart';

/// Compares a published package archive against the source it claims to be.
///
/// This is the tool's core primitive, not a helper of the `verify` command:
/// phase 5's post-publish check and phase 7's post-flip check are the same
/// comparison against a different [SourceTree]. One engine, several wearers —
/// the lesson of the two inspectors, applied before it is re-learned.
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
class Comparator {
  Comparator({required this.tools});

  final Tools tools;

  /// Basenames pub excludes from every archive, at any depth, whatever the
  /// tree tracks.
  ///
  /// Deliberately tiny, and every entry is a claim about `dart pub publish`
  /// that a real published archive has confirmed — a wrong entry here
  /// silently exempts a file from verification. The confirmation: the
  /// keybay_cli 0.1.0 archive on pub.dev, whose tag tracks `.gitignore` at
  /// four depths, a nested `pubspec.lock`, a `.metadata`, and its
  /// `.pubignore`, and carries none of them.
  static const alwaysExcluded = {
    'pubspec.lock',
    '.pubignore',
    '.gitignore',
    '.metadata',
  };

  /// Compares [archive] (a `.tar.gz` as bytes) against the files under
  /// [packageDirectory] in [tree].
  Future<Comparison> compare({
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
        return Comparison(
          Verdict.unknown,
          detail: 'the published archive could not be opened: '
              '${opened.summary}',
        );
      }

      return _compareExtracted(extracted, tree, packageDirectory);
    } finally {
      scratch.deleteSync(recursive: true);
    }
  }

  Comparison _compareExtracted(
    Directory extracted,
    SourceTree tree,
    String packageDirectory,
  ) {
    final prefix = packageDirectory == '.' ? '' : '$packageDirectory/';
    final evidence = <String, String>{};

    // Direction one: everything published must be accounted for by the tree.
    final inArchive = <String>{};
    for (final entry in extracted.listSync(recursive: true)) {
      if (entry is! File) continue;
      final relative = entry.path.substring(extracted.path.length + 1);
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
    // unless pub's own selection excludes it, which rk does not reinterpret.
    final pubignore = tree.exists('$prefix.pubignore');
    var unverifiable = 0;
    for (final tracked in tree.trackedFiles()) {
      if (prefix.isNotEmpty && !tracked.startsWith(prefix)) continue;
      final relative = tracked.substring(prefix.length);
      if (alwaysExcluded.contains(relative.split('/').last)) continue;
      if (inArchive.contains(relative)) continue;
      if (pubignore) {
        unverifiable++;
        continue;
      }
      evidence[relative] = 'in the source, missing from the archive';
    }

    if (evidence.isNotEmpty) {
      return Comparison(
        Verdict.conflict,
        detail: 'the published archive is not the source at this ref',
        evidence: evidence,
      );
    }
    if (unverifiable > 0) {
      // Honest partial: the archive-side check passed in full, but rk cannot
      // say whether these files were meant to be excluded or lost.
      return Comparison(
        Verdict.unknown,
        detail: 'every published file matches, and $unverifiable tracked '
            'file${unverifiable == 1 ? '' : 's'} absent from the archive '
            'cannot be judged — a .pubignore is present, and rk does not '
            'reinterpret pub\'s file selection',
      );
    }
    return Comparison(
      Verdict.exact,
      detail: '${inArchive.length} files, byte-identical',
    );
  }
}

class Comparison {
  Comparison(this.verdict, {this.detail, this.evidence = const {}});

  final Verdict verdict;
  final String? detail;

  /// Per-file findings — the difference itself, not the fact of one.
  final Map<String, String> evidence;
}
