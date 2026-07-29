import 'dart:io';

/// The repository facts a release depends on.
///
/// Read-only. rk creates a tag during an interactive release, which is a
/// record written after the operator authorised; nothing here writes.
class GitState {
  GitState({
    required this.root,
    required this.head,
    required this.branch,
    required this.isClean,
    required this.uncommitted,
    required this.headIsPushed,
    required this.tags,
    required this.signingConfigured,
  });

  final String root;

  /// The commit a release would be built from.
  final String head;

  final String? branch;
  final bool isClean;

  /// Paths with uncommitted changes, for naming them rather than counting.
  final List<String> uncommitted;

  /// Whether [head] exists on the remote. A tag on a commit nobody can fetch
  /// points at nothing for everyone else.
  final bool headIsPushed;

  final List<String> tags;

  /// Whether `git tag -s` would succeed, so rk can say so before asking for
  /// one rather than letting git fail with rk's name nowhere in it.
  final bool signingConfigured;

  String get shortHead => head.length > 7 ? head.substring(0, 7) : head;

  bool hasTag(String tag) => tags.contains(tag);

  /// Tags matching a pattern's literal prefix and suffix around the version.
  List<String> tagsMatching(String pattern) {
    final parts = pattern.split('{version}');
    if (parts.length != 2) return const [];
    final [prefix, suffix] = parts;
    return tags
        .where((t) => t.startsWith(prefix) && t.endsWith(suffix))
        .toList();
  }

  /// The version part of [tag] under [pattern], or null when it does not
  /// match.
  static String? versionIn(String tag, String pattern) {
    final parts = pattern.split('{version}');
    if (parts.length != 2) return null;
    final [prefix, suffix] = parts;
    if (!tag.startsWith(prefix) || !tag.endsWith(suffix)) return null;
    final end = tag.length - suffix.length;
    if (end <= prefix.length) return null;
    return tag.substring(prefix.length, end);
  }

  static String _run(String root, List<String> args) {
    final result = Process.runSync('git', args, workingDirectory: root);
    if (result.exitCode != 0) return '';
    return (result.stdout as String).trim();
  }

  static GitState read(String root) {
    final status = _run(root, const ['status', '--porcelain']);
    final uncommitted = status
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .map((l) => l.length > 3 ? l.substring(3) : l)
        .toList();

    final head = _run(root, const ['rev-parse', 'HEAD']);

    // A commit is fetchable when some remote branch contains it.
    final contains = _run(root, ['branch', '-r', '--contains', head]);

    final branch = _run(root, const ['rev-parse', '--abbrev-ref', 'HEAD']);

    final format = _run(root, const ['config', '--get', 'gpg.format']);
    final signingKey = _run(root, const ['config', '--get', 'user.signingkey']);

    return GitState(
      root: root,
      head: head,
      branch: branch.isEmpty || branch == 'HEAD' ? null : branch,
      isClean: uncommitted.isEmpty,
      uncommitted: uncommitted,
      headIsPushed: contains.trim().isNotEmpty,
      tags: _run(root, const ['tag', '--list'])
          .split('\n')
          .where((t) => t.trim().isNotEmpty)
          .toList(),
      // An SSH signing key is what this fleet uses; a GPG key works too, and
      // git reports neither unless one is configured.
      signingConfigured: signingKey.isNotEmpty ||
          (format.isEmpty && _run(root, const ['config', '--get', 'user.email'])
              .isNotEmpty &&
              _hasGpgDefault(root)),
    );
  }

  static bool _hasGpgDefault(String root) =>
      _run(root, const ['config', '--get', 'commit.gpgsign']) == 'true';
}
