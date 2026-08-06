import 'dart:io';
import 'diagnostic.dart';

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
    this.hasRemote = true,
    this.aheadOfUpstream,
    required this.tags,
    this.tagTargets = const {},
    required this.signingConfigured,
    required this.originUrl,
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

  /// Whether any remote is configured at all — "not pushed" and "nowhere to
  /// push to" call for different instructions.
  final bool hasRemote;

  /// Commits HEAD is ahead of its upstream, or null when there is no
  /// upstream to measure against.
  final int? aheadOfUpstream;

  final List<String> tags;

  /// Tag name to the commit it points at, peeled for annotated tags.
  ///
  /// Empty when unread — fixtures that do not care may omit it — and
  /// [tagTarget] answers null then, which callers treat as "placement
  /// unknown", never as agreement.
  final Map<String, String> tagTargets;

  /// Whether `git tag -s` would succeed, so rk can say so before asking for
  /// one rather than letting git fail with rk's name nowhere in it.
  final bool signingConfigured;

  /// `owner/name` for the origin remote, when it is a forge rk knows.
  final String? originUrl;

  String get shortHead => head.length > 7 ? head.substring(0, 7) : head;

  bool hasTag(String tag) => tags.contains(tag);

  /// The commit [tag] points at, or null when rk has not read it.
  String? tagTarget(String tag) => tagTargets[tag];

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

  /// `show-ref --tags -d` lines into tag → commit.
  ///
  /// An annotated tag appears twice: once as the tag object, once peeled with
  /// a `^{}` suffix pointing at the commit. The peeled entry wins, because the
  /// question rk asks is "what source does this tag name", and that is the
  /// commit — a lightweight tag has only the one entry, already the commit.
  static Map<String, String> _tagTargets(String showRef) {
    final targets = <String, String>{};
    for (final line in showRef.split('\n')) {
      final parts = line.trim().split(' ');
      if (parts.length != 2) continue;
      final sha = parts[0];
      var ref = parts[1];
      if (!ref.startsWith('refs/tags/')) continue;
      ref = ref.substring('refs/tags/'.length);
      if (ref.endsWith('^{}')) {
        targets[ref.substring(0, ref.length - 3)] = sha;
      } else {
        targets.putIfAbsent(ref, () => sha);
      }
    }
    return targets;
  }

  static String _run(String root, List<String> args) {
    final result = Process.runSync('git', args, workingDirectory: root);
    if (result.exitCode != 0) return '';
    return (result.stdout as String).trim();
  }

  /// Paths from `git status --porcelain`, which prefixes every line with two
  /// status columns and a space.
  ///
  /// Read without trimming the whole output first: a worktree-only change is
  /// reported as `" M path"`, so trimming the block ate the first line's
  /// leading column and rk named a file that does not exist — `ackages/...`.
  /// That is the commonest shape this list has, since it is what an
  /// uncommitted edit looks like.
  static List<String> _uncommittedIn(String porcelain) => porcelain
      .split('\n')
      .where((line) => line.trim().isNotEmpty)
      // rk's own scratch and evidence directories are not the operator's
      // uncommitted work. Counting them meant a failed release left debris
      // that made the next run refuse itself, breaking the resume.
      .map((line) => line.length > 3 ? line.substring(3) : line.trim())
      .where((path) => path != '.rk/' && !path.startsWith('.rk/'))
      .toList();

  /// The problem an uncommitted worktree is, with the paths named.
  ///
  /// Shared for the same reason [unpushedProblem] is, and because the drift
  /// it prevents had already happened: status pluralized correctly and
  /// named up to eight files, while release said "1 paths are uncommitted"
  /// and named none — one diagnostic code, two --json payloads.
  Diagnostic? uncommittedProblem() {
    if (isClean) return null;
    // Named, not counted: the ellipsis costs more characters than the path
    // it hides until the list is genuinely long.
    final paths = uncommitted.length <= 8
        ? uncommitted.join(', ')
        : '${uncommitted.take(8).join(', ')} '
            '…and ${uncommitted.length - 8} more';
    return Diagnostic(
      code: 'RK-GIT-001',
      message: uncommitted.length == 1
          ? '1 path is uncommitted'
          : '${uncommitted.length} paths are uncommitted',
      remedy: 'a release is of a commit, and these are not in one: $paths',
    );
  }

  /// The problem an unpushed HEAD is, said with its facts: which branch,
  /// how far ahead, or that there is nowhere to push to at all. Shared by
  /// status and release so the two verbs cannot describe it differently.
  Diagnostic? unpushedProblem() {
    if (headIsPushed) return null;
    if (!hasRemote) {
      return Diagnostic(
        code: 'RK-GIT-003',
        message: 'this repository has no remote',
        remedy: 'rk publishes what others can fetch, and nothing here is '
            'fetchable yet. git remote add origin <url>, then '
            'git push -u origin ${branch ?? 'main'}',
      );
    }
    final where = branch == null ? shortHead : '$branch ($shortHead)';
    final ahead = aheadOfUpstream;
    if (ahead == null) {
      return Diagnostic(
        code: 'RK-GIT-003',
        message: '$where has no upstream on origin',
        remedy: 'git push -u origin ${branch ?? 'HEAD'}',
      );
    }
    return Diagnostic(
      code: 'RK-GIT-003',
      message: '$where is ahead of origin/$branch by '
          '$ahead commit${ahead == 1 ? '' : 's'}',
      remedy: 'a tag here would point at commits origin cannot fetch — '
          'git push',
    );
  }

  static GitState read(String root) {
    final result = Process.runSync('git', const ['status', '--porcelain'],
        workingDirectory: root);
    final uncommitted = result.exitCode == 0
        ? _uncommittedIn(result.stdout as String)
        : const <String>[];

    final head = _run(root, const ['rev-parse', 'HEAD']);

    // A commit is fetchable when some remote branch contains it.
    final contains = _run(root, ['branch', '-r', '--contains', head]);

    final branch = _run(root, const ['rev-parse', '--abbrev-ref', 'HEAD']);

    final signingKey = _run(root, const ['config', '--get', 'user.signingkey']);

    return GitState(
      root: root,
      head: head,
      branch: branch.isEmpty || branch == 'HEAD' ? null : branch,
      isClean: uncommitted.isEmpty,
      uncommitted: uncommitted,
      headIsPushed: contains.trim().isNotEmpty,
      hasRemote: _run(root, const ['remote']).trim().isNotEmpty,
      aheadOfUpstream: int.tryParse(
          _run(root, const ['rev-list', '--count', '@{upstream}..HEAD'])),
      tags: _run(root, const ['tag', '--list'])
          .split('\n')
          .where((t) => t.trim().isNotEmpty)
          .toList(),
      tagTargets: _tagTargets(_run(root, const ['show-ref', '--tags', '-d'])),
      // A configured signing key, whether SSH or GPG. Inferring one from a
      // commit-signing *preference* would answer a different question, and
      // still would not prove a key exists — so rk claims only what git
      // states, and signs or does not accordingly.
      signingConfigured: signingKey.isNotEmpty,
      originUrl: _originSlug(_run(root, const ['remote', 'get-url', 'origin'])),
    );
  }

  /// `owner/name` from either remote form, or null when it is neither.
  static String? _originSlug(String url) {
    if (url.isEmpty) return null;
    final match = RegExp(r'github\.com[:/]([^/]+)/(.+?)(?:\.git)?$')
        .firstMatch(url.trim());
    if (match == null) return null;
    return '${match.group(1)}/${match.group(2)}';
  }
}
