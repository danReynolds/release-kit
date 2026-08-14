import '../destinations/git_tag.dart';
import '../destinations/github_release.dart';
import '../engine/assets.dart';
import '../engine/changelog.dart';
import '../engine/publish_target.dart';
import '../engine/release_manifest.dart';
import '../engine/resolve.dart';
import '../engine/source_tree.dart';
import '../engine/verdict.dart';
import '../engine/version.dart';
import 'target_module.dart';

/// Cross-target provenance shared by GitHub Release and Homebrew reads.
///
/// A cask is authenticated through the manifest bound into its Git tag and
/// hosted by its GitHub Release. Keeping that proof here prevents either
/// target module from reaching into the other module or weakening the chain.
final class PublishedReleaseEvidence {
  const PublishedReleaseEvidence(this.context);

  final TargetReadContext context;

  Future<PublishedCaskRead> currentCask(
    ResolvedUnit unit, {
    required String project,
    required String tap,
    required String path,
  }) async {
    final tag = requiredTargetTag(unit, PublishTarget.gitTag);
    final object = context.git.tagObject(tag);
    final commit = context.git.tagTarget(tag);
    if (object == null || commit == null) {
      return const PublishedCaskRead(
        Inspection.unknown('the release tag object could not be read'),
        null,
      );
    }
    final tagBinding = await GitTag(
      tools: context.tools!,
      root: context.git.root,
    ).manifestBinding(
      tag: tag,
      expectedObject: object,
      expectedCommit: commit,
    );
    if (tagBinding case TagManifestBound(:final digest)) {
      try {
        final read = await GithubRelease(
          tools: context.tools!,
          repository: context.repository!,
          workingDirectory: context.git.root,
        ).readManifest(manifestExpectation(unit, digest));
        return _selectCask(
          read.inspection,
          read.manifest,
          project: project,
          tap: tap,
          path: path,
        );
      } on Object catch (error) {
        return PublishedCaskRead(
          Inspection.unknown(
            'the expected release manifest could not be derived: $error',
          ),
          null,
        );
      }
    }
    return PublishedCaskRead(
      bindingInspection(tagBinding),
      null,
    );
  }

  GithubManifestExpectation manifestExpectation(
    ResolvedUnit unit,
    String digest, {
    Set<String>? publicAssets,
  }) {
    final tag = requiredTargetTag(unit, PublishTarget.gitTag);
    final source = GitCommitSourceTree(context.git.root, context.git.head);
    final entries = <({String project, String body})>[];
    for (final project in unit.projects) {
      final changelog = source.read(project.fileAt('CHANGELOG.md'));
      final notes = changelog == null
          ? null
          : Changelog.entry(changelog, project.version);
      if (notes == null) {
        throw StateError(
          'release notes for ${project.name} are absent from the released '
          'commit',
        );
      }
      entries.add((project: project.name, body: notes));
    }
    final body = entries.length == 1
        ? entries.single.body
        : entries
            .map((entry) => '## ${entry.project}\n\n${entry.body}')
            .join('\n\n');
    return GithubManifestExpectation(
      unit: unit.name,
      version: unit.version.canonical,
      tag: tag,
      sourceCommit: context.git.head,
      title: '${unit.name} ${unit.version}',
      body: body,
      prerelease: unit.version.isPrerelease,
      manifestSha256: digest,
      publicAssets: publicAssets ?? expectedReleaseAssets(unit),
    );
  }

  Future<PublishedCaskRead> historicalCask(
    ResolvedUnit unit,
    Version version, {
    required ResolvedProject project,
    required String tap,
    required String path,
  }) async {
    final tag = requiredTargetTagPattern(unit, PublishTarget.gitTag)
        .replaceAll('{version}', version.canonical);
    final object = context.git.tagObject(tag);
    final commit = context.git.tagTarget(tag);
    if (object == null || commit == null) {
      return PublishedCaskRead(
        Inspection.unknown(
          'the earlier release tag $tag is not available in this checkout',
        ),
        null,
      );
    }
    final tagBinding = await GitTag(
      tools: context.tools!,
      root: context.git.root,
    ).manifestBinding(
      tag: tag,
      expectedObject: object,
      expectedCommit: commit,
    );
    if (tagBinding case TagManifestBound(:final digest)) {
      final read = await GithubRelease(
        tools: context.tools!,
        repository: context.repository!,
        workingDirectory: context.git.root,
      ).readHistoricalManifest(
        GithubHistoricalManifestExpectation(
          unit: unit.name,
          version: version.canonical,
          tag: tag,
          sourceCommit: commit,
          manifestSha256: digest,
          prerelease: version.isPrerelease,
        ),
      );
      return _selectCask(
        read.inspection,
        read.manifest,
        project: project.name,
        tap: tap,
        path: path,
      );
    }
    return PublishedCaskRead(
      bindingInspection(tagBinding),
      null,
    );
  }

  static Inspection bindingInspection(TagManifestBinding binding) =>
      switch (binding) {
        TagManifestBound() => const Inspection.unknown(
            'the tag manifest binding was not consumed',
          ),
        TagManifestAbsent(:final why) => Inspection.conflict(
            'the release tag is absent',
            evidence: {'tag': why},
          ),
        TagManifestConflict(:final why, :final evidence) =>
          Inspection.conflict(why, evidence: evidence),
        TagManifestMissing(:final why) ||
        TagManifestMalformed(:final why) ||
        TagManifestUnbound(:final why) =>
          Inspection.conflict(
            'the release tag does not bind its public manifest',
            evidence: {'tag': why},
          ),
        TagManifestUnreadable(:final why) => Inspection.unknown(why),
      };
}

final class PublishedCaskRead {
  const PublishedCaskRead(this.inspection, this.cask);

  final Inspection inspection;
  final ReleaseManifestCask? cask;
}

PublishedCaskRead _selectCask(
  Inspection inspection,
  ReleaseManifest? manifest, {
  required String project,
  required String tap,
  required String path,
}) {
  if (!inspection.isExact || manifest == null) {
    return PublishedCaskRead(inspection, null);
  }
  final cask = manifest.cask;
  if (cask == null || !cask.names(project: project, tap: tap, path: path)) {
    return PublishedCaskRead(
      Inspection.conflict(
        'the published release manifest does not bind the Homebrew cask '
        'for $project',
        evidence: {
          '$tap/$path': cask == null
              ? 'missing from manifest'
              : 'manifest binds ${cask.tap}/${cask.path}',
        },
      ),
      null,
    );
  }
  return PublishedCaskRead(inspection, cask);
}

Set<String> expectedReleaseAssets(ResolvedUnit unit) =>
    ReleaseAssets.expectedForUnit(unit);
