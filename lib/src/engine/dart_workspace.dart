import 'diagnostic.dart';
import 'pubspec.dart';
import 'source_tree.dart';

/// The Dart packages `rk init` can propose, and why any other could not be
/// read: in Git every tracked manifest, and otherwise the root manifest and
/// its workspace members.
final class DartWorkspaceDiscovery {
  DartWorkspaceDiscovery._(this.projects, this.notices);

  factory DartWorkspaceDiscovery(
    SourceTree tree, {
    bool trackedManifests = false,
  }) {
    final notices = <String>[];
    final read = <String, Pubspec?>{};
    Pubspec? pubspec(String path) => read.putIfAbsent(path, () {
      final source = tree.read(path);
      if (source == null) {
        notices.add(
          '$path is ${trackedManifests ? 'tracked but not on disk' : 'discovered but missing'}',
        );
        return null;
      }
      final diagnostics = Diagnostics();
      final parsed = Pubspec.parse(source, path, diagnostics);
      if (parsed == null) {
        notices.add(
          '$path could not be parsed: '
          '${diagnostics.found.map((item) => item.message).join('; ')}',
        );
      }
      return parsed;
    });

    final manifests = trackedManifests
        ? [
            for (final path in tree.trackedFiles())
              if (path == 'pubspec.yaml' || path.endsWith('/pubspec.yaml'))
                path,
          ]
        : [if (tree.exists('pubspec.yaml')) 'pubspec.yaml'];
    if (!trackedManifests && manifests.isNotEmpty) {
      for (final raw in pubspec('pubspec.yaml')?.workspace ?? const []) {
        final member = _safeMember(raw);
        if (member == null) {
          notices.add('workspace member "$raw" is not a safe relative path');
        } else if (!tree.exists('$member/pubspec.yaml')) {
          notices.add(
            '$member/pubspec.yaml is declared by the workspace but is missing',
          );
        } else {
          manifests.add('$member/pubspec.yaml');
        }
      }
    }
    return DartWorkspaceDiscovery._(
      List.unmodifiable([for (final path in manifests..sort()) ?pubspec(path)]),
      List.unmodifiable(notices),
    );
  }

  final List<Pubspec> projects;
  final List<String> notices;
}

/// Whether [directory] is by convention an example or a test fixture, which
/// `rk init` does not propose.
bool isExampleOrFixture(String directory) {
  if (directory == '.') return false;
  const conventional = {
    'example',
    'examples',
    'fixture',
    'fixtures',
    'peer-fixtures',
    'test',
    'tests',
  };
  return directory
      .split('/')
      .map((part) => part.toLowerCase())
      .any(conventional.contains);
}

String? _safeMember(String raw) {
  final member = raw.trim().replaceFirst(RegExp(r'/+$'), '');
  return relativeSegments(member) == null ? null : member;
}
