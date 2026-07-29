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
  Future<Inspection> inspect(String tag, Set<String> expectedAssets) async {
    final listed = await _list();
    if (listed == null) {
      return const Inspection.unknown('the forge could not be read');
    }

    final matching = listed.where((r) => r.tag == tag).toList();
    if (matching.isEmpty) return const Inspection.absent();

    if (matching.length > 1) {
      return Inspection.conflict(
        '${matching.length} releases carry the tag $tag',
        evidence: {
          for (final release in matching)
            release.id: release.isDraft ? 'draft' : 'published',
        },
      );
    }

    final release = matching.single;
    if (!release.isDraft) {
      final assets = await _assets(tag);
      final missing = expectedAssets.difference(assets.toSet());
      if (missing.isEmpty) {
        return const Inspection.exact(detail: 'published');
      }
      // A published release cannot be edited, so this is terminal.
      return Inspection.conflict(
        'the published release is missing ${missing.length} of its assets',
        evidence: {for (final name in missing) name: 'missing'},
      );
    }

    return Inspection.absent(detail: 'a draft exists with ${release.id}');
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
    final existing = await _list();
    if (existing == null) {
      return PublishOutcome.failed('the forge could not be read');
    }
    for (final release in existing.where((r) => r.tag == tag && r.isDraft)) {
      final deleted = await tools.run(
        'gh',
        ['release', 'delete', tag, '--repo', repository, '--yes', '--cleanup-tag=false'],
        workingDirectory: workingDirectory,
      );
      if (!deleted.ok) {
        return PublishOutcome.failed(
          'a draft (${release.id}) is in the way and could not be removed: '
              '${deleted.summary}',
        );
      }
    }

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
    if (!created.ok) return PublishOutcome.failed(created.summary);

    // Verify against the forge rather than trusting the command's word.
    final assets = await _assets(tag);
    final expected = assetPaths.map(_fileName).toSet();
    final missing = expected.difference(assets.toSet());
    if (missing.isNotEmpty) {
      return PublishOutcome.failed(
        'the release published without ${missing.join(', ')}',
      );
    }

    return PublishOutcome.published(
      'https://github.com/$repository/releases/tag/$tag',
    );
  }

  /// Asset names on a published release.
  Future<List<String>> _assets(String tag) async {
    final result = await tools.run(
      'gh',
      [
        'release',
        'view',
        tag,
        '--repo',
        repository,
        '--json',
        'assets',
      ],
      workingDirectory: workingDirectory,
    );
    if (!result.ok) return const [];
    try {
      final decoded = jsonDecode(result.stdout);
      if (decoded is! Map) return const [];
      final assets = decoded['assets'];
      if (assets is! List) return const [];
      return [
        for (final asset in assets)
          if (asset is Map && asset['name'] is String) asset['name'] as String,
      ];
    } on Object {
      return const [];
    }
  }

  /// Every release, drafts included — a lookup by tag returns only published
  /// ones, so a draft would be invisible to it.
  Future<List<_Release>?> _list() async {
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
          if (entry is Map && entry['tagName'] is String)
            _Release(
              tag: entry['tagName'] as String,
              isDraft: entry['isDraft'] == true,
              id: entry['name'] is String && (entry['name'] as String).isNotEmpty
                  ? entry['name'] as String
                  : entry['tagName'] as String,
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
  _Release({required this.tag, required this.isDraft, required this.id});
  final String tag;
  final bool isDraft;
  final String id;
}

class PublishOutcome {
  const PublishOutcome._(this.url, this.problem);
  const PublishOutcome.published(String url) : this._(url, null);
  const PublishOutcome.failed(String problem) : this._(null, problem);

  final String? url;
  final String? problem;
  bool get ok => url != null;
}
