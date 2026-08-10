import '../destinations/git_tag.dart';
import '../destinations/github_release.dart';
import '../engine/assets.dart';
import '../engine/changelog.dart';
import '../engine/resolve.dart';
import '../engine/source_tree.dart';
import '../engine/verdict.dart';
import '../engine/version.dart';
import 'target_module.dart';

/// Cross-target provenance shared by GitHub Release and Homebrew reads.
///
/// A formula is authenticated through the manifest bound into its Git tag and
/// hosted by its GitHub Release. Keeping that proof here prevents either
/// target module from reaching into the other module or weakening the chain.
final class PublishedReleaseEvidence {
  const PublishedReleaseEvidence(this.context);

  final TargetReadContext context;

  Future<({Inspection inspection, List<int>? bytes})> currentManifestAsset(
    ResolvedUnit unit,
    String assetName,
  ) async {
    final object = context.git.tagObject(unit.tag);
    final commit = context.git.tagTarget(unit.tag);
    if (object == null || commit == null) {
      return (
        inspection: const Inspection.unknown(
          'the release tag object could not be read',
        ),
        bytes: null,
      );
    }
    final binding = await GitTag(
      tools: context.tools!,
      root: context.git.root,
    ).manifestBinding(
      tag: unit.tag,
      expectedObject: object,
      expectedCommit: commit,
    );
    if (binding case TagManifestBound(:final digest)) {
      try {
        final expected = manifestExpectation(unit, digest);
        final read = await GithubRelease(
          tools: context.tools!,
          repository: context.repository!,
          workingDirectory: context.git.root,
        ).readManifestBoundAsset(expected, assetName);
        return (inspection: read.inspection, bytes: read.bytes);
      } on Object catch (error) {
        return (
          inspection: Inspection.unknown(
            'the expected release manifest could not be derived: $error',
          ),
          bytes: null,
        );
      }
    }
    return (inspection: bindingInspection(binding), bytes: null);
  }

  GithubManifestExpectation manifestExpectation(
    ResolvedUnit unit,
    String digest, {
    Set<String>? publicAssets,
  }) {
    final project = unit.binaryProject;
    final source = GitCommitSourceTree(context.git.root, context.git.head);
    final changelog = source.read(project.fileAt('CHANGELOG.md'));
    final notes =
        changelog == null ? null : Changelog.entry(changelog, project.version);
    if (notes == null) {
      throw StateError('release notes are absent from the released commit');
    }
    return GithubManifestExpectation(
      unit: unit.name,
      version: unit.version.canonical,
      tag: unit.tag,
      sourceCommit: context.git.head,
      sourceTree: context.git.headTree,
      title: '${project.name} ${unit.version}',
      body: notes,
      manifestSha256: digest,
      publicAssets: publicAssets ?? expectedReleaseAssets(unit),
    );
  }

  Future<({Inspection inspection, List<int>? bytes})> historicalManifestAsset(
    ResolvedUnit unit,
    Version version,
    String assetName,
  ) async {
    final tag = unit.tagPattern.replaceAll('{version}', version.canonical);
    final object = context.git.tagObject(tag);
    final commit = context.git.tagTarget(tag);
    if (object == null || commit == null) {
      return (
        inspection: Inspection.unknown(
          'the earlier release tag $tag is not available in this checkout',
        ),
        bytes: null,
      );
    }
    final binding = await GitTag(
      tools: context.tools!,
      root: context.git.root,
    ).manifestBinding(
      tag: tag,
      expectedObject: object,
      expectedCommit: commit,
    );
    if (binding case TagManifestBound(:final digest)) {
      final read = await GithubRelease(
        tools: context.tools!,
        repository: context.repository!,
        workingDirectory: context.git.root,
      ).readHistoricalManifestBoundAsset(
        GithubHistoricalManifestExpectation(
          unit: unit.name,
          version: version.canonical,
          tag: tag,
          sourceCommit: commit,
          manifestSha256: digest,
          title: '${unit.binaryProject.name} ${version.canonical}',
        ),
        assetName,
      );
      return (inspection: read.inspection, bytes: read.bytes);
    }
    return (inspection: bindingInspection(binding), bytes: null);
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

Set<String> expectedReleaseAssets(ResolvedUnit unit) => {
      for (final project in unit.projects)
        ...ReleaseAssets.expectedFor(project),
    };
