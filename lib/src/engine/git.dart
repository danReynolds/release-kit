import 'dart:io';
import 'diagnostic.dart';
import 'timings.dart';
import 'tools.dart';

/// The repository facts a release depends on.
///
/// Read-only. rk creates a tag during an interactive release, which is a
/// record written after the operator authorised; nothing here writes.
class GitState {
  GitState({
    required this.root,
    required this.head,
    String? headTree,
    required this.branch,
    required this.isClean,
    required this.uncommitted,
    this.worktreeStatusError,
    required this.headIsPushed,
    this.hasRemote = true,
    this.aheadOfUpstream,
    required this.tags,
    this.tagObjects = const {},
    this.tagTargets = const {},
    required this.signingConfigured,
    this.tagSigningRequested = false,
    required this.originUrl,
  }) : headTree = headTree ?? head;

  /// A directory outside any Git repository: no commit, no remote, nothing
  /// uncommitted. Status and plan read such a directory as it is; stage and
  /// release refuse it ([stagingProblem]).
  GitState.none(String root)
    : this(
        root: root,
        head: '',
        headTree: '',
        branch: null,
        isClean: true,
        uncommitted: const [],
        headIsPushed: false,
        hasRemote: false,
        tags: const [],
        signingConfigured: false,
        originUrl: null,
      );

  /// Whether this source has a commit. A freshly initialized repository has
  /// no HEAD yet, and must not serialize an empty string where reports promise
  /// a full commit.
  bool get hasCommit => head.isNotEmpty;

  final String root;

  /// The commit a release would be built from.
  final String head;

  /// The full Git tree object for [head]. It is a separate stage coordinate:
  /// a commit identifies history and metadata, while the tree identifies the
  /// exact tracked bytes a stage materializes.
  final String headTree;

  final String? branch;
  final bool isClean;

  /// Paths with uncommitted changes, for naming them rather than counting.
  final List<String> uncommitted;

  /// Why Git could not say whether the worktree is clean.
  ///
  /// Null means `git status --porcelain` answered. A non-null value is never
  /// folded into an empty change list: not knowing whether release inputs are
  /// dirty is the opposite of proving that they are clean.
  final String? worktreeStatusError;

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

  /// Tag name to the object its ref names directly.
  ///
  /// For a lightweight tag this is the commit. For an annotated tag this is
  /// the tag object, whose bytes (including its signature, when present) are
  /// part of the release identity. [tagTargets] separately carries the peeled
  /// commit.
  final Map<String, String> tagObjects;

  /// Tag name to the commit it points at, peeled for annotated tags.
  ///
  /// Empty when unread — fixtures that do not care may omit it — and
  /// [tagTarget] answers null then, which callers treat as "placement
  /// unknown", never as agreement.
  final Map<String, String> tagTargets;

  /// Whether `git tag -s` would succeed, so rk can say so before asking for
  /// one rather than letting git fail with rk's name nowhere in it.
  final bool signingConfigured;

  /// Whether this repository asks for signed tags (`tag.gpgSign`).
  ///
  /// This is the project's own statement of intent, in Git's vocabulary rather
  /// than an rk setting. It is machine-local — `.git/config` is not committed —
  /// so a signed release history is treated as the same statement, and either
  /// one makes a signature required rather than incidental.
  final bool tagSigningRequested;

  /// `owner/name` for the origin remote, when it is a forge rk knows.
  final String? originUrl;

  String get shortHead => head.length > 7 ? head.substring(0, 7) : head;

  bool hasTag(String tag) => tags.contains(tag);

  /// The object stored directly in `refs/tags/[tag]`.
  String? tagObject(String tag) => tagObjects[tag];

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

  /// `show-ref --tags -d` lines into tag -> direct object.
  static Map<String, String> _tagObjects(String showRef) {
    final objects = <String, String>{};
    for (final line in showRef.split('\n')) {
      final parts = line.trim().split(' ');
      if (parts.length != 2) continue;
      final ref = parts[1];
      if (!ref.startsWith('refs/tags/') || ref.endsWith('^{}')) continue;
      objects[ref.substring('refs/tags/'.length)] = parts[0];
    }
    return objects;
  }

  /// The problem an uncommitted worktree is, with the paths named.
  ///
  /// Shared for the same reason [unpushedProblem] is, and because the drift
  /// it prevents had already happened: status pluralized correctly and
  /// named up to eight files, while release said "1 paths are uncommitted"
  /// and named none — one diagnostic code, two --json payloads.
  Diagnostic? uncommittedProblem() {
    if (worktreeStatusError != null) {
      return Diagnostic(
        code: 'RK-GIT-008',
        message: 'the worktree state could not be read',
        remedy:
            '$worktreeStatusError\n'
            '`git status --porcelain` must succeed before rk can prove the '
            'release is of the committed source.',
      );
    }
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
      remedy:
          'commit first: a release is of a commit, and these are not in '
          'one: $paths',
    );
  }

  /// Why this source cannot be staged or released, or null when it can.
  ///
  /// A stage is named by the commit it is built from, so stage and release
  /// need a clean commit: uncommitted changes, a repository with no commit
  /// yet, and a directory outside Git are each refused before any work.
  Diagnostic? stagingProblem() {
    if (uncommittedProblem() case final problem?) return problem;
    if (hasCommit) return null;
    return const Diagnostic(
      code: 'RK-SRC-004',
      message: 'there is no commit to stage or release',
      remedy:
          'rk stage and rk release build from a commit: put this directory '
          'in a Git repository (git init), commit it, then run again',
    );
  }

  /// The problem an unpushed HEAD is, said with its facts: which branch,
  /// how far ahead, or that there is nowhere to push to at all. Shared by
  /// status and release so the two verbs cannot describe it differently.
  Diagnostic? unpushedProblem() {
    // With no commit there is nothing to push: [stagingProblem] says what is.
    if (!hasCommit || headIsPushed) return null;
    if (!hasRemote) {
      return Diagnostic(
        code: 'RK-GIT-003',
        message: 'this repository has no remote',
        remedy:
            'rk publishes what others can fetch, and nothing here is '
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
      message:
          '$where is ahead of origin/$branch by '
          '$ahead commit${ahead == 1 ? '' : 's'}',
      remedy:
          'a tag here would point at commits origin cannot fetch — '
          'git push',
    );
  }

  /// Reads only the origin identity for commands that do not need release
  /// preflight. This also works in an uncommitted repository or a subdirectory.
  static Future<String?> readOrigin(String root) async {
    final result = await Process.run('git', const [
      'remote',
      'get-url',
      'origin',
    ], workingDirectory: root);
    return result.exitCode == 0 ? _originSlug(result.stdout as String) : null;
  }

  /// Reads the repository's state at [root], with every question asked at
  /// once.
  ///
  /// `git status --porcelain=v2 --branch` answers HEAD, its branch, upstream
  /// and ahead count beside the uncommitted paths; one config read answers
  /// the signing key, `tag.gpgSign`, and whether a remote exists, and
  /// `git remote get-url` answers origin as git resolves it. Tags are listed apart
  /// from the peeled `show-ref`, which fails whole on one unreachable tag
  /// object: a tag rk can see but not place is RK-GIT-007, never absent.
  static Future<GitState> read(
    String root, {
    Tools tools = const SystemTools(),
  }) => Timings.span('read git state', () => _read(root, tools));

  static Future<GitState> _read(String root, Tools tools) async {
    Future<ToolResult> ask(List<String> args) => tools.run('git', [
      '--no-optional-locks',
      ...args,
    ], workingDirectory: root);
    String text(ToolResult result) => result.ok ? result.stdout.trim() : '';

    final [
      status,
      tree,
      showRef,
      tagList,
      config,
      containing,
      origin,
    ] = await Future.wait([
      // A submodule's own untracked or modified files are not this commit's
      // to commit, and no stage reads them; a moved submodule commit still
      // shows.
      ask(const [
        'status',
        '--porcelain=v2',
        '--branch',
        '-z',
        '--ignore-submodules=dirty',
      ]),
      ask(const ['rev-parse', '--verify', '--quiet', 'HEAD^{tree}']),
      ask(const ['show-ref', '--tags', '-d']),
      ask(const ['tag', '--list']),
      ask(const [
        'config',
        '--get-regexp',
        r'^(user\.signingkey|tag\.gpgsign|remote\..*\.url)$',
      ]),
      // A commit is fetchable when some remote branch contains it.
      ask(const ['branch', '-r', '--contains', 'HEAD']),
      // Read as git resolves it: an `insteadOf` alias such as `gh:owner/repo`
      // is the GitHub repository it stands for.
      ask(const ['remote', 'get-url', 'origin']),
    ]);
    final branch = _StatusV2.parse(status.ok ? status.stdout : '');
    final statusError = status.ok
        ? null
        : _toolFailure(
            status,
            fallback: 'git status exited ${status.exitCode}',
          );
    final settings = _settings(text(config));
    final showRefText = text(showRef);

    return GitState(
      root: root,
      head: branch.head,
      headTree: text(tree),
      branch: branch.name,
      isClean: statusError == null && branch.uncommitted.isEmpty,
      uncommitted: statusError == null ? branch.uncommitted : const [],
      worktreeStatusError: statusError,
      headIsPushed: text(containing).isNotEmpty,
      hasRemote: settings.keys.any(
        (key) => key.startsWith('remote.') && key.endsWith('.url'),
      ),
      aheadOfUpstream: branch.ahead,
      tags: text(
        tagList,
      ).split('\n').where((tag) => tag.trim().isNotEmpty).toList(),
      tagObjects: _tagObjects(showRefText),
      tagTargets: _tagTargets(showRefText),
      // A configured signing key, whether SSH or GPG. Inferring one from a
      // commit-signing *preference* would answer a different question, and
      // still would not prove a key exists — so rk claims only what git
      // states. Whether a release tag is signed comes from tag.gpgSign and
      // the release history; this lets rk refuse (RK-TAG-005) when signing
      // is required and no key is set.
      signingConfigured: (settings['user.signingkey'] ?? '').isNotEmpty,
      tagSigningRequested: _gitBoolean(settings['tag.gpgsign']),
      originUrl: _originSlug(text(origin)),
    );
  }

  /// `git config --get-regexp` lines into key → its last value. A key
  /// written with no value prints alone, and reads as the empty string.
  static Map<String, String> _settings(String lines) {
    final settings = <String, String>{};
    for (final line in lines.split('\n')) {
      if (line.trim().isEmpty) continue;
      final space = line.indexOf(' ');
      settings[space < 0 ? line : line.substring(0, space)] = space < 0
          ? ''
          : line.substring(space + 1).trim();
    }
    return settings;
  }

  /// Git's own reading of a boolean setting: `[tag] gpgSign` with no value
  /// is true, as are `true`, `yes`, `on`, and `1`.
  static bool _gitBoolean(String? value) =>
      value != null &&
      const {'', 'true', 'yes', 'on', '1'}.contains(value.toLowerCase());

  /// `owner/name` from either remote form, or null when it is neither.
  static String? _originSlug(String url) {
    if (url.isEmpty) return null;
    final match = RegExp(
      r'github\.com[:/]([^/]+)/(.+?)(?:\.git)?$',
    ).firstMatch(url.trim());
    if (match == null) return null;
    return '${match.group(1)}/${match.group(2)}';
  }

  static String _toolFailure(ToolResult result, {required String fallback}) {
    final stderr = result.stderr.trim();
    if (stderr.isNotEmpty) return stderr.split('\n').last.trim();
    final stdout = result.stdout.trim();
    if (stdout.isNotEmpty) return stdout.split('\n').last.trim();
    return fallback;
  }
}

/// What `git status --porcelain=v2 --branch -z` says: HEAD, its branch and
/// how far it is ahead of its upstream, and every uncommitted path.
final class _StatusV2 {
  _StatusV2(this.head, this.name, this.ahead, this.uncommitted);

  factory _StatusV2.parse(String output) {
    var head = '';
    String? name;
    int? ahead;
    final uncommitted = <String>[];
    final records = output.split('\u0000');
    for (var index = 0; index < records.length; index++) {
      final record = records[index];
      if (record.startsWith('# branch.oid ')) {
        final oid = record.substring('# branch.oid '.length);
        head = oid == '(initial)' ? '' : oid;
      } else if (record.startsWith('# branch.head ')) {
        final branch = record.substring('# branch.head '.length);
        name = branch == '(detached)' ? null : branch;
      } else if (record.startsWith('# branch.ab +')) {
        ahead = int.tryParse(
          record.substring('# branch.ab +'.length).split(' ').first,
        );
      } else if (record.startsWith('1 ')) {
        uncommitted.add(_field(record, 8));
      } else if (record.startsWith('2 ')) {
        uncommitted.add(_field(record, 9));
        index++; // the path it was renamed or copied from
      } else if (record.startsWith('u ')) {
        uncommitted.add(_field(record, 10));
      } else if (record.startsWith('? ')) {
        uncommitted.add(record.substring(2));
      }
    }
    return _StatusV2(
      head,
      name,
      ahead,
      // rk's own scratch and evidence directories are not the operator's
      // uncommitted work. Counting them meant a failed release left debris
      // that made the next run refuse itself, breaking the resume.
      [
        for (final path in uncommitted)
          if (path != '.rk' && path != '.rk/' && !path.startsWith('.rk/')) path,
      ],
    );
  }

  final String head;
  final String? name;
  final int? ahead;
  final List<String> uncommitted;

  /// Everything after the first [fields] space-separated fields: the path,
  /// which may itself contain spaces.
  static String _field(String record, int fields) {
    var at = 0;
    for (var count = 0; count < fields; count++) {
      at = record.indexOf(' ', at) + 1;
      if (at == 0) return record;
    }
    return record.substring(at);
  }
}
