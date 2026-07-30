import 'dart:convert';

import '../engine/tools.dart';
import '../engine/verdict.dart';

/// Publishes a set of assets as one immutable release.
///
/// A forge cannot publish several assets at once: a release object is created,
/// then assets are uploaded to it. So rk fills a draft privately, verifies it,
/// and publishes once — an interrupted upload must never leave a permanent
/// release missing files.
///
/// The draft is a staging area, not memory: the workspace holds every artifact,
/// so a draft that is not exactly right is deleted and rebuilt rather than
/// repaired in place.
class GithubRelease {
  GithubRelease({
    required this.tools,
    required this.repository,
    required this.workingDirectory,
  });

  final Tools tools;

  /// `owner/name`.
  final String repository;

  final String workingDirectory;

  /// How the release for [tag] stands.
  ///
  /// The tag is asked about by name rather than looked for in a list. A listing
  /// is paged, and a tag missing from the page rk happened to read is not a tag
  /// that does not exist — concluding absence from it would be exactly the
  /// collapse rk must never make.
  Future<Inspection> inspect(String tag, Set<String> expectedAssets) async {
    final release = await _view(tag);
    switch (release) {
      case _NotFound():
        return const Inspection.absent();
      case _Unreadable(:final why):
        return Inspection.unknown(why);
      case _Found(:final release):
        if (release.isDraft) {
          return Inspection.absent(detail: 'a draft exists with ${release.id}');
        }
        final assets = release.assets;
        if (assets == null) {
          return const Inspection.unknown(
            'the release exists but its assets could not be listed',
          );
        }
        final missing = expectedAssets.difference(assets);
        if (missing.isEmpty) {
          return const Inspection.exact(detail: 'published');
        }
        // A published release cannot be edited, so this is terminal — which is
        // why it is only ever said about assets rk actually read.
        return Inspection.conflict(
          'the published release is missing ${missing.length} of its assets',
          evidence: {for (final name in missing) name: 'missing'},
        );
    }
  }

  /// Creates the release with every asset, published in one act.
  ///
  /// `gh release create` uploads the assets and publishes together, which is
  /// the closest a forge offers to atomicity. A draft left by an earlier
  /// interrupted run is deleted first, since the workspace holds the
  /// artifacts and a rebuilt draft is cheaper than a repaired one.
  Future<PublishOutcome> publish({
    required String tag,
    required String title,
    required List<String> assetPaths,
  }) async {
    final existing = await _drafts(tag);
    if (existing == null) {
      return PublishOutcome.failed('the forge could not be read');
    }
    for (final release in existing) {
      final deleted = await tools.run(
        'gh',
        [
          'release',
          'delete',
          tag,
          '--repo',
          repository,
          '--yes',
          '--cleanup-tag=false'
        ],
        workingDirectory: workingDirectory,
      );
      if (!deleted.ok) {
        return PublishOutcome.failed(
          'a draft (${release.id}) is in the way and could not be removed: '
          '${deleted.summary}',
        );
      }
    }

    // Past this point an act is in flight: `gh release create` uploads assets
    // and publishes in one command, so a failure part way through has already
    // put something at the forge.
    final created = await tools.run(
      'gh',
      [
        'release',
        'create',
        tag,
        ...assetPaths,
        '--repo',
        repository,
        '--title',
        title,
        '--generate-notes',
      ],
      workingDirectory: workingDirectory,
    );
    if (!created.ok) {
      return PublishOutcome.lostTrack(
        'creating the release failed part way: ${created.summary}',
        url: 'https://github.com/$repository/releases/tag/$tag',
      );
    }

    // Verify against the forge rather than trusting the command's word.
    final url = 'https://github.com/$repository/releases/tag/$tag';
    final after = await _view(tag);
    switch (after) {
      case _Found(:final release) when release.assets != null:
        final expected = assetPaths.map(_fileName).toSet();
        final missing = expected.difference(release.assets!);
        if (missing.isNotEmpty) {
          // rk has read this: the release is public, immutable, and short of
          // what it claims. Reporting it as a failure would print "nothing
          // changed", which is the opposite of true, and would send the
          // operator to retry something that cannot be retried.
          return PublishOutcome.terminal(
            'the release published without ${missing.join(', ')}',
            url: url,
            permanent: 'the release at $tag is public and cannot be edited',
          );
        }
        return PublishOutcome.published(url);
      default:
        // The create succeeded and the confirming read did not. Something
        // exists; rk cannot say it is right. Calling that a failure would send
        // an operator to fix a release that may be complete.
        return PublishOutcome.lostTrack(
          'the release was created but could not be read back to confirm its '
          'assets — re-running will inspect it',
          url: url,
        );
    }
  }

  /// Asks the forge about one tag.
  ///
  /// Three answers, kept apart because they mean different things to a caller:
  /// it is not there, it is there, or rk could not find out. `gh` distinguishes
  /// the first from the third by message rather than by exit code, so that is
  /// what is read — and anything unrecognised is unreadable rather than absent.
  Future<_Lookup> _view(String tag) async {
    final result = await tools.run(
      'gh',
      [
        'release',
        'view',
        tag,
        '--repo',
        repository,
        '--json',
        'tagName,isDraft,name,assets',
      ],
      workingDirectory: workingDirectory,
    );

    if (!result.ok) {
      final said = result.summary.toLowerCase();
      if (said.contains('release not found') ||
          said.contains('no release found')) {
        // gh says exactly this whether the release is missing from a
        // repository rk can read or the repository itself cannot be seen — a
        // typo in the origin, a private repo, an expired token. Absence is
        // what lets a release proceed, so it is only concluded once the
        // repository has answered for itself.
        return await _repositoryIsReadable()
            ? const _NotFound()
            : _Unreadable(
                'the repository $repository could not be read, so rk cannot '
                'tell whether $tag is released',
              );
      }
      return _Unreadable('the forge could not be read: ${result.summary}');
    }

    try {
      final decoded = jsonDecode(result.stdout);
      if (decoded is! Map) {
        return const _Unreadable('the forge answered something unreadable');
      }
      final assets = decoded['assets'];
      return _Found(_Release(
        tag: decoded['tagName'] is String ? decoded['tagName'] as String : tag,
        isDraft: decoded['isDraft'] == true,
        id: decoded['name'] is String && (decoded['name'] as String).isNotEmpty
            ? decoded['name'] as String
            : tag,
        // Null rather than empty when the field is missing or malformed: no
        // assets and no answer about assets are different facts.
        assets: assets is List
            ? {
                for (final asset in assets)
                  if (asset is Map && asset['name'] is String)
                    asset['name'] as String,
              }
            : null,
      ));
    } on Object catch (error) {
      return _Unreadable('the forge answered something unreadable: $error');
    }
  }

  /// Whether the forge will tell rk about the repository at all.
  Future<bool> _repositoryIsReadable() async {
    final result = await tools.run(
      'gh',
      ['repo', 'view', repository, '--json', 'name'],
      workingDirectory: workingDirectory,
    );
    return result.ok;
  }

  /// Drafts carrying [tag], which a lookup by tag alone would not surface.
  Future<List<_Release>?> _drafts(String tag) async {
    final result = await tools.run(
      'gh',
      [
        'release',
        'list',
        '--repo',
        repository,
        '--limit',
        '100',
        '--json',
        'tagName,isDraft,name',
      ],
      workingDirectory: workingDirectory,
    );
    if (!result.ok) return null;

    try {
      final decoded = jsonDecode(result.stdout);
      if (decoded is! List) return null;
      return [
        for (final entry in decoded)
          if (entry is Map &&
              entry['tagName'] == tag &&
              entry['isDraft'] == true)
            _Release(
              tag: tag,
              isDraft: true,
              id: entry['name'] is String &&
                      (entry['name'] as String).isNotEmpty
                  ? entry['name'] as String
                  : tag,
              assets: null,
            ),
      ];
    } on Object {
      return null;
    }
  }

  static String _fileName(String path) {
    final cut = path.lastIndexOf('/');
    return cut < 0 ? path : path.substring(cut + 1);
  }
}

class _Release {
  _Release({
    required this.tag,
    required this.isDraft,
    required this.id,
    required this.assets,
  });

  final String tag;
  final bool isDraft;
  final String id;

  /// Asset names, or null when rk could not read them.
  final Set<String>? assets;
}

/// What asking the forge about one tag produced.
sealed class _Lookup {
  const _Lookup();
}

class _NotFound extends _Lookup {
  const _NotFound();
}

class _Found extends _Lookup {
  const _Found(this.release);
  final _Release release;
}

class _Unreadable extends _Lookup {
  const _Unreadable(this.why);
  final String why;
}

/// How an act at the forge ended.
///
/// Three outcomes rather than two: an act that succeeded but could not be
/// confirmed is neither. Reporting it as failure sends an operator to fix
/// something that may be finished, and reporting it as success claims knowledge
/// rk does not have.
class PublishOutcome {
  const PublishOutcome._(
    this.url,
    this.problem,
    this.confirmed, {
    this.permanent,
  });

  const PublishOutcome.published(String url) : this._(url, null, true);

  /// Nothing was put anywhere.
  const PublishOutcome.failed(String problem) : this._(null, problem, false);

  /// Something may exist that rk could not read back, so the next run must
  /// inspect rather than assume.
  const PublishOutcome.lostTrack(String problem, {String? url})
      : this._(url, problem, false);

  /// rk read back what it did and it is wrong, and it cannot be taken back.
  const PublishOutcome.terminal(
    String problem, {
    required String url,
    required String permanent,
  }) : this._(url, problem, false, permanent: permanent);

  final String? url;
  final String? problem;

  /// Whether rk read back what it did.
  final bool confirmed;

  /// What is already public and cannot be undone, stated before any remedy.
  final String? permanent;

  bool get ok => confirmed;

  /// An effect may exist that rk could not verify.
  bool get mayHaveActed => !confirmed && url != null;

  /// Re-running cannot resolve this.
  bool get isTerminal => permanent != null;
}
