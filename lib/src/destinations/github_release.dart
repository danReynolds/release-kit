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
        final extra = assets.difference(expectedAssets);
        if (missing.isEmpty && extra.isEmpty) {
          return const Inspection.exact(detail: 'published');
        }
        // Exact means equal, not subset. A release carrying assets this
        // configuration would not produce is not "what this release would put
        // there" any more than one missing assets is — and reading a superset
        // as exact would later bless a release whose notary log or formula
        // went missing, because nothing counted the extras.
        //
        // A published release cannot be edited, so this is terminal — which is
        // why it is only ever said about assets rk actually read.
        return Inspection.conflict(
          missing.isEmpty
              ? 'the published release carries ${extra.length} assets this '
                  'configuration would not produce'
              : 'the published release differs from what this configuration '
                  'would produce',
          evidence: {
            for (final name in missing) name: 'missing',
            for (final name in extra)
              name: 'not produced by this '
                  'configuration',
          },
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
    required String notesPath,
    required List<String> assetPaths,
  }) async {
    final existing = await _drafts(tag);
    if (existing == null) {
      return PublishOutcome.failed('the forge could not be read');
    }
    for (final release in existing) {
      // By id, not by tag: several drafts can carry the same tag, and the
      // porcelain delete addresses whichever one it finds first.
      final deleted = await tools.run(
        'gh',
        ['api', '-X', 'DELETE', 'repos/$repository/releases/${release.id}'],
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
    // The body is the changelog entry, from a file: one source of release
    // prose, so the notes and the CHANGELOG cannot disagree — which is what
    // `--generate-notes` (a commit-log digest) quietly did.
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
        '--notes-file',
        notesPath,
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
  /// Three answers, kept apart because they mean different things to a
  /// caller: it is not there, it is there, or rk could not find out. Read
  /// through `gh api`, whose error line carries the HTTP status — a code,
  /// where the porcelain (`gh release view`) says the same "release not
  /// found" prose for a missing release and for one it hit mid-flight, and
  /// rewords it between versions. Anything that is not a 404 is unreadable
  /// rather than absent.
  ///
  /// A 404 alone is still not absence: GitHub answers 404 for a repository
  /// the token cannot see, deliberately. Absence is concluded only once the
  /// repository has answered for itself.
  Future<_Lookup> _view(String tag) async {
    final result = await tools.run(
      'gh',
      ['api', 'repos/$repository/releases/tags/$tag'],
      workingDirectory: workingDirectory,
    );

    if (!result.ok) {
      if (result.summary.contains('(HTTP 404)')) {
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
        tag:
            decoded['tag_name'] is String ? decoded['tag_name'] as String : tag,
        isDraft: decoded['draft'] == true,
        id: '${decoded['id'] ?? tag}',
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

  /// Drafts carrying [tag], which a lookup by tag alone would not surface —
  /// the tags endpoint returns only published releases.
  ///
  /// `--paginate` walks every page. The porcelain version of this took
  /// `--limit 100`, a silent cap: draft number 101 survived the sweep and
  /// blocked the create it existed to unblock.
  Future<List<_Release>?> _drafts(String tag) async {
    final result = await tools.run(
      'gh',
      ['api', '--paginate', '--slurp', 'repos/$repository/releases'],
      workingDirectory: workingDirectory,
    );
    if (!result.ok) return null;

    try {
      // --slurp wraps the pages as one array of arrays, so the whole answer
      // decodes as a list of pages — no splicing of page boundaries, which
      // would corrupt on a body that happens to contain the boundary text.
      final decoded = jsonDecode(result.stdout);
      if (decoded is! List) return null;
      return [
        for (final page in decoded)
          if (page is List)
            for (final entry in page)
              if (entry is Map &&
                  entry['tag_name'] == tag &&
                  entry['draft'] == true)
                _Release(
                  tag: tag,
                  isDraft: true,
                  id: '${entry['id'] ?? tag}',
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
