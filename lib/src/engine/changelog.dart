import 'diagnostic.dart';
import 'source_tree.dart';
import 'version.dart';

/// Whether a changelog records the version being released.
///
/// rk does not parse, lint, or generate changelog content, and never edits the
/// file. It answers one question: is this version written down for the people
/// who will install it?
class Changelog {
  /// The heading rk looks for: text that, once stripped of leading `#`,
  /// punctuation, and surrounding whitespace, begins with the canonical
  /// version string.
  static bool mentions(String source, Version version) {
    for (final line in source.split('\n')) {
      final heading = _headingText(line);
      if (heading == null) continue;
      if (_beginsWithVersion(heading, version.canonical)) return true;
    }
    return false;
  }

  /// Checks the changelog beside [manifestDirectory], recording a problem when
  /// the file or the entry is missing.
  static void check({
    required SourceTree tree,
    required String manifestDirectory,
    required String packageName,
    required Version version,
    required Diagnostics diagnostics,
  }) {
    final path = manifestDirectory == '.'
        ? 'CHANGELOG.md'
        : '$manifestDirectory/CHANGELOG.md';

    final source = tree.read(path);
    if (source == null) {
      diagnostics.add(
        'RK-CHG-001',
        '"$packageName" has no changelog',
        source: SourceLocation(path),
        remedy: 'add $path with an entry for $version — it is the only place '
            'a user finds out what changed',
      );
      return;
    }

    if (!mentions(source, version)) {
      diagnostics.add(
        'RK-CHG-002',
        'the changelog has no entry for $version',
        source: SourceLocation(path, 1),
        remedy: 'add a heading beginning with $version, as in "## $version"',
      );
    }
  }

  /// The text of a Markdown heading, or null when the line is not one.
  ///
  /// Both `# 1.2.3` and a Setext-style line are common; only the ATX form is
  /// recognised, since that is what pub's own template writes.
  static String? _headingText(String line) {
    final trimmed = line.trimLeft();
    if (!trimmed.startsWith('#')) return null;
    return trimmed.replaceFirst(RegExp(r'^#+'), '').trim();
  }

  /// Whether [heading] opens with [version], allowing the punctuation people
  /// decorate a heading with — brackets, quotes, or a following dash.
  static bool _beginsWithVersion(String heading, String version) {
    final cleaned = heading.replaceFirst(RegExp(r'^[\[\("' "'" r']+'), '');
    if (!cleaned.startsWith(version)) return false;
    if (cleaned.length == version.length) return true;
    // The character after the version must end it, so 0.1.0 does not match a
    // heading for 0.1.02.
    final next = cleaned[version.length];
    return !RegExp(r'[0-9A-Za-z.\-+]').hasMatch(next);
  }
}
