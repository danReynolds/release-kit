import 'dart:convert';
import 'dart:io';

import '../engine/assets.dart';
import '../engine/release_manifest.dart';
import '../engine/tools.dart';
import '../engine/verdict.dart';
import '../engine/version.dart';
import '../transforms/digest.dart';

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
    return _inspect(
      tag: tag,
      expectedAssets: expectedAssets,
    );
  }

  /// The newest semantic version carried by a published release matching
  /// [tagPattern]. Every page is read; a draft is private staging and therefore
  /// is not a published version. A malformed answer stays unknown rather than
  /// silently shortening the history rk compares against.
  Future<Inspection> inspectLatestVersion(String tagPattern) async {
    final parts = tagPattern.split('{version}');
    if (parts.length != 2) {
      return const Inspection.unknown(
        'the release tag pattern has no single {version} coordinate',
      );
    }
    final result = await tools.run(
      'gh',
      ['api', '--paginate', '--slurp', 'repos/$repository/releases'],
      workingDirectory: workingDirectory,
    );
    if (!result.ok) {
      return Inspection.unknown(
        'GitHub releases could not be read: ${result.summary}',
      );
    }

    try {
      final decoded = jsonDecode(result.stdout);
      if (decoded is! List) {
        return const Inspection.unknown(
          'GitHub returned a malformed paginated release list',
        );
      }
      Version? latest;
      for (final page in decoded) {
        if (page is! List) {
          return const Inspection.unknown(
            'GitHub returned a malformed release page',
          );
        }
        for (final entry in page) {
          if (entry is! Map ||
              entry['tag_name'] is! String ||
              entry['draft'] is! bool) {
            return const Inspection.unknown(
              'GitHub returned a malformed release entry',
            );
          }
          if (entry['draft'] as bool) continue;
          final raw = _versionIn(entry['tag_name'] as String, parts);
          if (raw == null) continue;
          final version = Version.tryParse(raw);
          if (version == null) {
            return Inspection.unknown(
              'the published tag ${entry['tag_name']} matches the release '
              'pattern but is not a semantic version',
            );
          }
          if (latest == null || version > latest) latest = version;
        }
      }
      if (latest == null) {
        return const Inspection.absent(
          detail: 'no matching GitHub Release is published',
        );
      }
      return Inspection.exact(
        detail: 'latest published GitHub Release is $latest',
        evidence: {'version': latest.canonical},
      );
    } on Object catch (error) {
      return Inspection.unknown(
        'GitHub returned a malformed release list: $error',
      );
    }
  }

  /// Inspects the complete public release identity, including downloaded
  /// asset bytes.
  ///
  /// [inspect] remains the inventory-only compatibility surface for callers
  /// that do not yet hold a stage receipt. Once a receipt exists, this is the
  /// stronger question: tag, title, body, asset names, and every asset digest
  /// must all match. A download failure is unknown rather than a digest
  /// mismatch — not being able to read bytes is not evidence about them.
  Future<Inspection> inspectExact(GithubReleaseExpectation expected) =>
      _inspect(
        tag: expected.tag,
        expectedAssets: expected.assetSha256.keys.toSet(),
        expectedTitle: expected.title,
        expectedBody: expected.body,
        expectedDigests: expected.assetSha256,
      );

  /// Inspects an immutable release using its public manifest as the source of
  /// artifact digests, without consulting a local stage.
  ///
  /// The manifest's own digest must come from outside the manifest — rk binds
  /// it into the Git tag message — so altered manifest bytes cannot redefine
  /// what counts as exact. The parsed manifest then binds every other public
  /// asset to the expected unit, version, tag, and stage identity.
  Future<Inspection> inspectManifest(
    GithubManifestExpectation expected,
  ) async =>
      (await _observeManifest(expected)).inspection;

  /// Returns the parsed manifest only after the same externally anchored,
  /// exact release verification used by [inspectManifest].
  ///
  /// Destination targets use this to authenticate manifest records that are
  /// deliberately not GitHub assets. A parsed document is never exposed from
  /// an unknown or conflicting observation.
  Future<GithubManifestRead> readManifest(
    GithubManifestExpectation expected,
  ) async {
    final observed = await _observeManifest(expected);
    return GithubManifestRead._(observed.inspection, observed.manifest);
  }

  /// Historical counterpart to [readManifest]. The peeled tag commit and the
  /// tag-bound manifest digest are the external anchors; today's configuration
  /// is not used to reconstruct the older release inventory.
  Future<GithubManifestRead> readHistoricalManifest(
    GithubHistoricalManifestExpectation expected,
  ) async {
    final observed = await _observeManifestRelease(
      unit: expected.unit,
      version: expected.version,
      tag: expected.tag,
      manifestSha256: expected.manifestSha256,
      sourceCommit: expected.sourceCommit,
      title: expected.title,
    );
    return GithubManifestRead._(observed.inspection, observed.manifest);
  }

  /// Reads one ordinary release asset through the manifest-bound inspection.
  ///
  /// This is deliberately not a second download surface. The release title,
  /// body, complete inventory, externally bound manifest digest, manifest
  /// coordinates, and every artifact digest are checked first by the same
  /// observation as [inspectManifest]. Bytes are returned only when that whole
  /// observation is exact; unknown and conflict observations never expose
  /// partially verified downloads.
  Future<GithubManifestAssetRead> readManifestBoundAsset(
    GithubManifestExpectation expected,
    String assetName,
  ) async {
    if (assetName == ReleaseAssets.manifest) {
      return const GithubManifestAssetRead._(
        Inspection.unknown(
          'release-manifest.json is verification metadata, not a readable '
          'release artifact',
        ),
        null,
      );
    }
    if (!expected.publicAssets.contains(assetName)) {
      return GithubManifestAssetRead._(
        Inspection.unknown(
          '$assetName is not a configured public release asset',
        ),
        null,
      );
    }

    final observation = await _observeManifest(expected);
    if (!observation.inspection.isExact) {
      return GithubManifestAssetRead._(observation.inspection, null);
    }
    final bytes = observation.verifiedBytes[assetName];
    if (bytes == null) {
      // An exact manifest observation necessarily verified every configured
      // non-manifest asset. Keep this guard fail-closed if that invariant is
      // ever broken by a future manifest schema.
      return GithubManifestAssetRead._(
        Inspection.unknown(
          '$assetName was not available after release verification',
        ),
        null,
      );
    }
    return GithubManifestAssetRead._(observation.inspection, bytes);
  }

  /// Reads an asset from an older, self-describing release.
  ///
  /// The tag supplies the two external anchors that the release cannot choose
  /// for itself: its peeled source commit and the manifest digest. The bound
  /// manifest may then describe its own stage identity and complete artifact
  /// inventory. This lets a later run recover an exact historical formula
  /// without retaining that release's local stage, resolved plan, or changelog
  /// body.
  Future<GithubManifestAssetRead> readHistoricalManifestBoundAsset(
    GithubHistoricalManifestExpectation expected,
    String assetName,
  ) async {
    if (assetName == ReleaseAssets.manifest) {
      return const GithubManifestAssetRead._(
        Inspection.unknown(
          'release-manifest.json is verification metadata, not a readable '
          'release artifact',
        ),
        null,
      );
    }

    final observation = await _observeManifestRelease(
      unit: expected.unit,
      version: expected.version,
      tag: expected.tag,
      manifestSha256: expected.manifestSha256,
      sourceCommit: expected.sourceCommit,
      title: expected.title,
    );
    if (!observation.inspection.isExact) {
      return GithubManifestAssetRead._(observation.inspection, null);
    }
    final bytes = observation.verifiedBytes[assetName];
    if (bytes == null) {
      return GithubManifestAssetRead._(
        Inspection.conflict(
          'the published release manifest does not declare $assetName',
          evidence: {assetName: 'missing from release manifest'},
        ),
        null,
      );
    }
    return GithubManifestAssetRead._(observation.inspection, bytes);
  }

  Future<_ManifestObservation> _observeManifest(
    GithubManifestExpectation expected,
  ) =>
      _observeManifestRelease(
        unit: expected.unit,
        version: expected.version,
        tag: expected.tag,
        manifestSha256: expected.manifestSha256,
        sourceCommit: expected.sourceCommit,
        title: expected.title,
        body: expected.body,
        publicAssets: expected.publicAssets,
      );

  Future<_ManifestObservation> _observeManifestRelease({
    required String unit,
    required String version,
    required String tag,
    required String manifestSha256,
    required String sourceCommit,
    String? title,
    String? body,
    Set<String>? publicAssets,
  }) async {
    if (!_isSha256(manifestSha256)) {
      return const _ManifestObservation.failed(
        Inspection.unknown(
          'the expected release manifest digest is not SHA-256',
        ),
      );
    }
    if (!_isObjectId(sourceCommit)) {
      return const _ManifestObservation.failed(
        Inspection.unknown(
          'the tag-bound source commit is not a full Git object ID',
        ),
      );
    }
    if (publicAssets != null &&
        !publicAssets.contains(ReleaseAssets.manifest)) {
      return const _ManifestObservation.failed(
        Inspection.unknown(
          'the configured public assets omit release-manifest.json',
        ),
      );
    }

    final lookup = await _readRelease(tag);
    if (!lookup.inspection.isExact) {
      return _ManifestObservation.failed(lookup.inspection);
    }
    final release = lookup.release!;
    final surface = _compareRelease(
      release,
      tag: tag,
      expectedAssets: publicAssets,
      expectedTitle: title,
      expectedBody: body,
    );
    if (!surface.isExact) return _ManifestObservation.failed(surface);
    if (!release.assets!.contains(ReleaseAssets.manifest)) {
      return const _ManifestObservation.failed(
        Inspection.conflict(
          'the published release has no release manifest',
          evidence: {ReleaseAssets.manifest: 'missing'},
        ),
      );
    }

    final downloaded = await _downloadAssetBytes(
      tag,
      ReleaseAssets.manifest,
    );
    if (downloaded.problem != null) {
      return _ManifestObservation.failed(
        Inspection.unknown(downloaded.problem!),
      );
    }
    final manifestBytes = downloaded.bytes!;
    final actualManifestSha = Sha256.hex(manifestBytes);
    final expectedManifestSha = manifestSha256.toLowerCase();
    if (actualManifestSha != expectedManifestSha) {
      return _ManifestObservation.failed(
        Inspection.conflict(
          'the published release manifest differs from the tag-bound manifest',
          evidence: {
            ReleaseAssets.manifest:
                'sha256 $actualManifestSha, expected $expectedManifestSha',
          },
        ),
      );
    }

    final ReleaseManifest manifest;
    try {
      manifest = ReleaseManifest.parse(utf8.decode(manifestBytes));
    } on Object catch (error) {
      return _ManifestObservation.failed(
        Inspection.conflict(
          'the published release manifest is invalid',
          evidence: {ReleaseAssets.manifest: '$error'},
        ),
      );
    }

    final differences = <String, String>{};
    if (manifest.unit != unit) {
      differences['unit'] = 'published ${manifest.unit}, expected $unit';
    }
    if (manifest.version != version) {
      differences['version'] =
          'published ${manifest.version}, expected $version';
    }
    if (manifest.tag != tag) {
      differences['manifest tag'] = 'published ${manifest.tag}, expected $tag';
    }
    if (manifest.commit == null ||
        manifest.commit!.toLowerCase() != sourceCommit.toLowerCase()) {
      differences['source commit'] = 'published ${manifest.commit}, expected '
          '${sourceCommit.toLowerCase()}';
    }

    final manifestArtifacts = manifest.artifacts.map((a) => a.name).toSet();
    final manifestPublicAssets = {
      ...manifestArtifacts,
      ReleaseAssets.manifest,
    };
    if (publicAssets != null) {
      final configuredArtifacts = publicAssets.difference(
        const {ReleaseAssets.manifest},
      );
      final missing = configuredArtifacts.difference(manifestArtifacts);
      final extra = manifestArtifacts.difference(configuredArtifacts);
      differences.addAll({
        for (final name in missing) name: 'missing from release manifest',
        for (final name in extra) name: 'not a configured public asset',
      });
    }
    if (differences.isNotEmpty) {
      return _ManifestObservation.failed(
        Inspection.conflict(
          'the published release manifest describes a different release',
          evidence: differences,
        ),
      );
    }

    final manifestSurface = _compareRelease(
      release,
      tag: tag,
      expectedAssets: manifestPublicAssets,
      expectedTitle: title,
      expectedBody: body,
    );
    if (!manifestSurface.isExact) {
      return _ManifestObservation.failed(manifestSurface);
    }

    final assets = await _observeAssetBytes(
      tag,
      {
        for (final artifact in manifest.artifacts)
          artifact.name: artifact.sha256,
        ReleaseAssets.manifest: expectedManifestSha,
      },
      knownBytes: {ReleaseAssets.manifest: manifestBytes},
      expectedBy: 'release manifest',
    );
    return assets.inspection.isExact
        ? _ManifestObservation.exact(
            assets.inspection,
            manifest,
            assets.verifiedBytes,
          )
        : _ManifestObservation.failed(assets.inspection);
  }

  Future<Inspection> _inspect({
    required String tag,
    required Set<String> expectedAssets,
    String? expectedTitle,
    String? expectedBody,
    Map<String, String>? expectedDigests,
  }) async {
    if (expectedDigests != null) {
      for (final entry in expectedDigests.entries) {
        if (!_isSha256(entry.value)) {
          return Inspection.unknown(
            'the expected digest for ${entry.key} is not SHA-256',
          );
        }
      }
    }

    final observed = await _readRelease(tag);
    if (!observed.inspection.isExact) return observed.inspection;
    final surface = _compareRelease(
      observed.release!,
      tag: tag,
      expectedAssets: expectedAssets,
      expectedTitle: expectedTitle,
      expectedBody: expectedBody,
    );
    if (!surface.isExact) return surface;
    if (expectedDigests != null) {
      return _inspectAssetBytes(tag, expectedDigests);
    }
    return surface;
  }

  Future<_ReleaseObservation> _readRelease(String tag) async {
    final lookup = await _view(tag);
    switch (lookup) {
      case _NotFound():
        return const _ReleaseObservation.failed(Inspection.absent());
      case _Unreadable(:final why):
        return _ReleaseObservation.failed(Inspection.unknown(why));
      case _Found(:final release):
        if (release.isDraft) {
          return _ReleaseObservation.failed(
            Inspection.absent(detail: 'a draft exists with ${release.id}'),
          );
        }
        if (release.assets == null) {
          return const _ReleaseObservation.failed(
            Inspection.unknown(
              'the release exists but its assets could not be listed',
            ),
          );
        }
        return _ReleaseObservation.exact(release);
    }
  }

  Inspection _compareRelease(
    _Release release, {
    required String tag,
    Set<String>? expectedAssets,
    String? expectedTitle,
    String? expectedBody,
  }) {
    if (expectedTitle != null && !release.titleReadable) {
      return const Inspection.unknown(
        'the release exists but its title could not be read',
      );
    }
    if (expectedBody != null && !release.bodyReadable) {
      return const Inspection.unknown(
        'the release exists but its body could not be read',
      );
    }

    final assets = release.assets!;
    final missing = expectedAssets?.difference(assets) ?? const <String>{};
    final extra = expectedAssets == null
        ? const <String>{}
        : assets.difference(expectedAssets);
    final differences = <String, String>{};
    if (release.tag != tag) {
      differences['tag'] = 'published ${release.tag}, expected $tag';
    }
    if (expectedTitle != null && release.title != expectedTitle) {
      differences['title'] =
          'published ${_shown(release.title)}, expected ${_shown(expectedTitle)}';
    }
    if (expectedBody != null && release.body != expectedBody) {
      differences['body'] = 'published release notes differ';
    }

    // Exact means equal, not subset. A release carrying assets this
    // configuration would not produce is not "what this release would put
    // there" any more than one missing assets is — and reading a superset as
    // exact would later bless a release whose notary log or formula went
    // missing, because nothing counted the extras.
    differences.addAll({
      for (final name in missing) name: 'missing',
      for (final name in extra) name: 'not produced by this configuration',
    });
    if (differences.isNotEmpty) {
      return Inspection.conflict(
        expectedAssets != null && missing.isEmpty && extra.isNotEmpty
            ? 'carries ${extra.length} assets this configuration would not '
                'produce (found ${assets.length}, expected '
                '${expectedAssets.length})'
            : expectedAssets != null && missing.isNotEmpty
                ? 'differs from what this configuration produces '
                    '(found ${assets.length}, expected '
                    '${expectedAssets.length}, ${missing.length} missing)'
                : 'release metadata differs from what this configuration '
                    'produces',
        evidence: differences,
      );
    }
    return const Inspection.exact(detail: 'published');
  }

  Future<Inspection> _inspectAssetBytes(
    String tag,
    Map<String, String> expectedDigests, {
    Map<String, List<int>> knownBytes = const {},
    String expectedBy = 'staged release',
  }) async =>
      (await _observeAssetBytes(
        tag,
        expectedDigests,
        knownBytes: knownBytes,
        expectedBy: expectedBy,
      ))
          .inspection;

  Future<_AssetObservation> _observeAssetBytes(
    String tag,
    Map<String, String> expectedDigests, {
    Map<String, List<int>> knownBytes = const {},
    String expectedBy = 'staged release',
  }) async {
    try {
      final names = expectedDigests.keys.toList()..sort();
      final verifiedBytes = <String, List<int>>{};
      // Assets are independent immutable coordinates. Reading them serially
      // multiplied the per-command timeout by the inventory size (five alpha
      // assets could mean ten minutes). Start every missing download
      // together, then classify in sorted name order so output and conflict
      // precedence remain deterministic.
      final reads = <String, Future<({List<int>? bytes, String? problem})>>{
        for (final name in names)
          if (!knownBytes.containsKey(name))
            name: _downloadAssetBytes(tag, name),
      };
      final completed = await Future.wait([
        for (final entry in reads.entries)
          entry.value.then((value) => (name: entry.key, value: value)),
      ]);
      final downloaded = {
        for (final item in completed) item.name: item.value,
      };

      final mismatches = <String, String>{};
      final unreadable = <String, String>{};
      for (final name in names) {
        final bytes = knownBytes[name] ?? downloaded[name]?.bytes;
        final problem = downloaded[name]?.problem;
        if (bytes == null) {
          unreadable[name] = problem ?? '$name produced no readable bytes';
          continue;
        }
        final actual = Sha256.hex(bytes);
        final expected = expectedDigests[name]!.toLowerCase();
        if (actual != expected) {
          mismatches[name] = 'sha256 $actual, expected $expected';
          continue;
        }
        verifiedBytes[name] = List<int>.unmodifiable(bytes);
      }
      // A proven immutable mismatch outranks an unreadable sibling. Unknown
      // means rk lacks a fact; it cannot erase a conflict already established.
      if (mismatches.isNotEmpty) {
        return _AssetObservation.failed(
          Inspection.conflict(
            'published asset bytes differ from the $expectedBy',
            evidence: mismatches,
          ),
        );
      }
      if (unreadable.isNotEmpty) {
        return _AssetObservation.failed(
          Inspection.unknown(unreadable.entries.first.value),
        );
      }
      return _AssetObservation.exact(
        Inspection.exact(
          detail: 'published metadata and asset bytes match',
          evidence: {
            for (final name in names)
              name: 'sha256 ${expectedDigests[name]!.toLowerCase()}',
          },
        ),
        verifiedBytes,
      );
    } on Object catch (error) {
      return _AssetObservation.failed(
        Inspection.unknown(
          'published asset bytes could not be read: $error',
        ),
      );
    }
  }

  /// Proves the bytes on one exact private release response.
  ///
  /// GitHub computes the SHA-256 after an upload reaches the `uploaded` state.
  /// Reading that digest from [_viewById] binds the proof to the draft that rk
  /// will PATCH; a tag lookup could select another same-tag draft or release.
  Inspection _inspectDraftAssets(
    _Release draft,
    Map<String, String> expectedDigests,
    Map<String, int> expectedSizes,
  ) {
    final metadata = draft.assetMetadata;
    if (metadata == null) {
      return const Inspection.unknown(
        'the private draft asset metadata could not be read',
      );
    }

    final ids = <String>{};
    final mismatches = <String, String>{};
    for (final name in expectedDigests.keys.toList()..sort()) {
      final asset = metadata[name];
      if (asset == null ||
          asset.id == null ||
          asset.state == null ||
          asset.size == null ||
          asset.digest == null) {
        return Inspection.unknown(
          'the private draft metadata for $name is incomplete',
        );
      }
      if (!ids.add(asset.id!)) {
        return const Inspection.unknown(
          'the private draft returned one asset id for several names',
        );
      }
      if (asset.state != 'uploaded') {
        mismatches[name] = 'state ${asset.state}, expected uploaded';
        continue;
      }
      final serverDigest = RegExp(r'^sha256:([0-9a-fA-F]{64})$')
          .firstMatch(asset.digest!)
          ?.group(1)
          ?.toLowerCase();
      if (serverDigest == null) {
        return Inspection.unknown(
          'the private draft digest for $name is not SHA-256',
        );
      }
      final expectedDigest = expectedDigests[name]!.toLowerCase();
      final expectedSize = expectedSizes[name]!;
      if (asset.size != expectedSize || serverDigest != expectedDigest) {
        mismatches[name] = 'size ${asset.size}, sha256 $serverDigest; expected '
            'size $expectedSize, sha256 $expectedDigest';
      }
    }
    if (mismatches.isNotEmpty) {
      return Inspection.conflict(
        'private draft asset bytes differ from the staged release',
        evidence: mismatches,
      );
    }
    return Inspection.exact(
      detail: 'private draft metadata and asset digests match',
      evidence: {
        for (final name in expectedDigests.keys)
          name: 'sha256 ${expectedDigests[name]!.toLowerCase()}',
      },
    );
  }

  Future<({List<int>? bytes, String? problem})> _downloadAssetBytes(
    String tag,
    String name,
  ) async {
    final Directory scratch;
    try {
      scratch = await Directory.systemTemp.createTemp('rk-gh-inspect-');
    } on Object catch (error) {
      return (
        bytes: null,
        problem: 'published asset bytes could not be read: $error',
      );
    }
    try {
      // The output filename is ours rather than the asset name. Apart from
      // avoiding path traversal, this makes existence an unambiguous receipt
      // for this one command in an otherwise empty directory.
      final outputPath = '${scratch.path}/asset';
      final downloaded = await tools.run(
        'gh',
        [
          'release',
          'download',
          tag,
          '--repo',
          repository,
          '--pattern',
          name,
          '--output',
          outputPath,
        ],
        workingDirectory: workingDirectory,
      );
      if (!downloaded.ok) {
        return (
          bytes: null,
          problem: '$name could not be downloaded: ${downloaded.summary}',
        );
      }
      final file = File(outputPath);
      if (!await file.exists()) {
        return (
          bytes: null,
          problem: 'GitHub reported downloading $name but produced no bytes',
        );
      }
      return (bytes: await file.readAsBytes(), problem: null);
    } on Object catch (error) {
      return (
        bytes: null,
        problem: 'published asset bytes could not be read: $error',
      );
    } finally {
      try {
        await scratch.delete(recursive: true);
      } on Object {
        // Scratch cleanup cannot change what the forge answered.
      }
    }
  }

  /// Creates a private draft, fills and validates it, then publishes it.
  ///
  /// GitHub has no atomic multi-asset public create. A single
  /// `gh release create <assets...>` still creates the public release before
  /// every upload is known complete. The only safe transaction boundary is a
  /// draft: asset failures leave private debris, while the final PATCH is the
  /// sole act that can make the already-complete inventory public.
  Future<PublishOutcome> publish({
    required String tag,
    required String title,
    required String notesPath,
    required List<GithubReleaseAssetUpload> assets,
  }) async {
    var draftEffect = DraftEffect.none;
    PublishOutcome failed(String problem) => PublishOutcome.failed(
          problem,
          draftEffect: draftEffect,
        );

    final url = 'https://github.com/$repository/releases/tag/$tag';
    final local = _validateUploadRequest(
      tag: tag,
      title: title,
      notesPath: notesPath,
      assets: assets,
    );
    if (local.problem != null) return failed(local.problem!);
    final notes = local.notes!;
    final ordered = local.assets!;
    final names = [for (final asset in ordered) asset.publicName];
    final assetSha256 = {
      for (final asset in ordered) asset.publicName: asset.sha256,
    };
    final assetSizes = {
      for (final asset in ordered) asset.publicName: asset.size,
    };

    // Local shape and bytes are validated before this first remote read. A
    // malformed request can therefore never delete, create, or fill a draft.
    final existing = await _drafts(tag);
    if (existing == null) return failed('GitHub could not be read');
    if (existing.length > 1) {
      return failed(
        '${existing.length} private drafts already use $tag; rk will not '
        'choose, replace, or delete one',
      );
    }

    final Directory scratch;
    try {
      scratch = await Directory.systemTemp.createTemp('rk-gh-publish-');
    } on Object catch (error) {
      return failed('the private draft could not be prepared: $error');
    }
    try {
      String draftId;
      var uploadedPrefix = 0;
      if (existing case [final candidate]) {
        final observed = await _viewById(candidate.id);
        if (observed is! _Found) {
          return failed(
            'private draft ${candidate.id} could not be read for recovery',
          );
        }
        final prefix = _inspectDraftPrefix(
          observed.release,
          tag: tag,
          title: title,
          body: notes,
          expected: ordered,
        );
        if (!prefix.inspection.isExact) {
          return failed(
            'private draft ${candidate.id} is not an exact resumable prefix: '
            '${prefix.inspection.detail ?? prefix.inspection.verdict.name}',
          );
        }
        draftId = candidate.id;
        uploadedPrefix = prefix.length;
      } else {
        final createInput = File('${scratch.path}/create.json');
        await createInput.writeAsString(jsonEncode({
          'tag_name': tag,
          'name': title,
          'body': notes,
          'draft': true,
        }));
        draftEffect = DraftEffect.uncertain;
        final created = await tools.run(
          'gh',
          [
            'api',
            '-X',
            'POST',
            'repos/$repository/releases',
            '--input',
            createInput.path,
          ],
          workingDirectory: workingDirectory,
        );

        final createdId = _releaseIdIn(created.stdout);
        if (createdId == null) {
          final afterCreate = await _drafts(tag);
          if (afterCreate == null || afterCreate.length != 1) {
            if (afterCreate?.isEmpty == true) draftEffect = DraftEffect.none;
            return failed(
              'the private draft could not be identified after create: '
              '${created.summary}',
            );
          }
          draftId = afterCreate.single.id;
        } else {
          draftId = createdId;
        }
        draftEffect = DraftEffect.changed;

        // A create response proves only an id. Verify the exact empty draft
        // metadata before placing the first byte into it.
        final observed = await _viewById(draftId);
        if (observed is! _Found) {
          return failed(
              'private draft $draftId could not be read after create');
        }
        final prefix = _inspectDraftPrefix(
          observed.release,
          tag: tag,
          title: title,
          body: notes,
          expected: ordered,
        );
        if (!prefix.inspection.isExact || prefix.length != 0) {
          return failed(
            'private draft $draftId did not start as the frozen empty release: '
            '${prefix.inspection.detail ?? prefix.inspection.verdict.name}',
          );
        }
      }

      for (var index = uploadedPrefix; index < ordered.length; index++) {
        final asset = ordered[index];
        final name = asset.publicName;
        draftEffect = DraftEffect.uncertain;
        final uploaded = await tools.run(
          'gh',
          [
            'api',
            '-X',
            'POST',
            '-H',
            'Content-Type: application/octet-stream',
            '--input',
            asset.stagedPath,
            // An absolute upload endpoint keeps github.com as gh's auth
            // authority. Selecting uploads.github.com with --hostname instead
            // asks gh for a separate host login and builds an Enterprise-style
            // /api/v3 URL, neither of which is the GitHub upload API.
            'https://uploads.github.com/repos/$repository/releases/'
                '$draftId/assets?name='
                '${Uri.encodeQueryComponent(name)}',
          ],
          workingDirectory: workingDirectory,
        );
        if (!uploaded.ok) {
          final observed = await _viewById(draftId);
          if (observed is _Found && !observed.release.isDraft) {
            draftEffect = DraftEffect.changed;
            return PublishOutcome.lostTrack(
              'release $draftId became public before rk authorized '
              'publication',
              url: url,
              draftEffect: draftEffect,
            );
          }
          final named = observed is _Found &&
              observed.release.isDraft &&
              observed.release.assets?.contains(name) == true;
          if (!named) {
            if (observed is! _Unreadable) {
              draftEffect = DraftEffect.changed;
            }
            return failed(
              'uploading $name to private draft $draftId did not complete: '
              '${uploaded.summary}',
            );
          }
          // A name in the draft inventory proves neither that the upload
          // finished nor that it landed the staged bytes. Reconcile only from
          // GitHub's digest on this exact private draft id.
          draftEffect = DraftEffect.changed;
          final prefix = _inspectDraftPrefix(
            observed.release,
            tag: tag,
            title: title,
            body: notes,
            expected: ordered,
          );
          if (!prefix.inspection.isExact || prefix.length != index + 1) {
            return failed(
              'uploading $name to private draft $draftId could not be '
              'reconciled by bytes: '
              '${prefix.inspection.detail ?? prefix.inspection.verdict.name}',
            );
          }
        }
        draftEffect = DraftEffect.changed;
      }

      // This is the publication gate. The draft must still be private and must
      // already carry the exact metadata, complete inventory, and staged bytes.
      // Post-act inspection repeats the same byte check against public reality;
      // it is confirmation, not the first point at which bad bytes are found.
      final beforePublish = await _viewById(draftId);
      if (beforePublish is! _Found) {
        return failed(
          'private draft $draftId could not be read before publication',
        );
      }
      final draft = beforePublish.release;
      if (!draft.isDraft) {
        return PublishOutcome.lostTrack(
          'release $draftId became public before rk authorized publication',
          url: url,
          draftEffect: draftEffect,
        );
      }
      final surface = _compareRelease(
        draft,
        tag: tag,
        expectedAssets: names.toSet(),
        expectedTitle: title,
        expectedBody: notes,
      );
      if (!surface.isExact) {
        return failed(
          'private draft $draftId is incomplete: '
          '${surface.detail ?? surface.verdict.name}',
        );
      }
      final draftBytes = _inspectDraftAssets(
        draft,
        assetSha256,
        assetSizes,
      );
      if (!draftBytes.isExact) {
        return failed(
          'private draft $draftId does not contain the staged bytes: '
          '${draftBytes.detail ?? draftBytes.verdict.name}',
        );
      }

      final publishInput = File('${scratch.path}/publish.json');
      await publishInput.writeAsString(jsonEncode({'draft': false}));
      final published = await tools.run(
        'gh',
        [
          'api',
          '-X',
          'PATCH',
          'repos/$repository/releases/$draftId',
          '--input',
          publishInput.path,
        ],
        workingDirectory: workingDirectory,
      );

      // A failed client response is ambiguous. Read by immutable release id:
      // public+complete reconciles to success, still-draft is a private failure,
      // and unreadable means the shared caller must inspect public reality.
      final after = await _viewById(draftId);
      if (after case _Found(:final release)) {
        if (release.isDraft) {
          return failed(
            'private draft $draftId was not published: ${published.summary}',
          );
        }
        final publicSurface = _compareRelease(
          release,
          tag: tag,
          expectedAssets: names.toSet(),
          expectedTitle: title,
          expectedBody: notes,
        );
        if (!publicSurface.isExact) {
          return PublishOutcome.terminal(
            'the release became public with different metadata or assets',
            url: url,
            permanent: 'the release at $tag is public and cannot be edited',
            draftEffect: draftEffect,
          );
        }
        return PublishOutcome.published(url, draftEffect: draftEffect);
      }
      return PublishOutcome.lostTrack(
        published.ok
            ? 'the complete draft was published but could not be read back'
            : 'publishing the complete draft did not return successfully: '
                '${published.summary}',
        url: url,
        draftEffect: DraftEffect.uncertain,
      );
    } on Object catch (error) {
      return failed('the private release draft failed: $error');
    } finally {
      try {
        await scratch.delete(recursive: true);
      } on Object {
        // Public truth does not depend on scratch cleanup.
      }
    }
  }

  ({String? problem, String? notes, List<GithubReleaseAssetUpload>? assets})
      _validateUploadRequest({
    required String tag,
    required String title,
    required String notesPath,
    required List<GithubReleaseAssetUpload> assets,
  }) {
    if (tag.trim().isEmpty || title.trim().isEmpty) {
      return (
        problem: 'the release tag or title is empty',
        notes: null,
        assets: null
      );
    }
    final notesType = FileSystemEntity.typeSync(notesPath, followLinks: false);
    if (notesType != FileSystemEntityType.file) {
      return (
        problem: 'the staged release notes are missing or not a regular file',
        notes: null,
        assets: null,
      );
    }
    final String notes;
    try {
      notes = File(notesPath).readAsStringSync();
    } on Object catch (error) {
      return (
        problem: 'the staged release notes could not be read: $error',
        notes: null,
        assets: null
      );
    }

    final ordered = List<GithubReleaseAssetUpload>.of(assets)
      ..sort((left, right) => left.publicName.compareTo(right.publicName));
    final names = <String>{};
    final paths = <String>{};
    for (final asset in ordered) {
      final normalized = asset.publicName.toLowerCase();
      if (!names.add(normalized)) {
        return (
          problem: 'two staged assets have the same public filename',
          notes: null,
          assets: null
        );
      }
      if (!paths.add(asset.stagedPath)) {
        return (
          problem: 'two public assets refer to the same staged file',
          notes: null,
          assets: null
        );
      }
      if (!_isPublicAssetName(asset.publicName)) {
        return (
          problem: 'invalid public asset filename: ${asset.publicName}',
          notes: null,
          assets: null
        );
      }
      if (!_isSha256(asset.sha256) || asset.size < 0) {
        return (
          problem: 'invalid size or SHA-256 for ${asset.publicName}',
          notes: null,
          assets: null
        );
      }
      if (FileSystemEntity.typeSync(asset.stagedPath, followLinks: false) !=
          FileSystemEntityType.file) {
        return (
          problem: '${asset.publicName} is missing or not a regular file',
          notes: null,
          assets: null
        );
      }
      try {
        final bytes = File(asset.stagedPath).readAsBytesSync();
        if (bytes.length != asset.size || Sha256.hex(bytes) != asset.sha256) {
          return (
            problem: '${asset.publicName} differs from its staged receipt',
            notes: null,
            assets: null
          );
        }
      } on Object catch (error) {
        return (
          problem: '${asset.publicName} could not be read: $error',
          notes: null,
          assets: null
        );
      }
    }
    return (problem: null, notes: notes, assets: List.unmodifiable(ordered));
  }

  ({Inspection inspection, int length}) _inspectDraftPrefix(
    _Release draft, {
    required String tag,
    required String title,
    required String body,
    required List<GithubReleaseAssetUpload> expected,
  }) {
    if (!draft.isDraft) {
      return (
        inspection:
            const Inspection.conflict('the candidate release is not private'),
        length: 0,
      );
    }
    if (!draft.titleReadable || !draft.bodyReadable || draft.assets == null) {
      return (
        inspection: const Inspection.unknown(
            'the private draft metadata or inventory is unreadable'),
        length: 0,
      );
    }
    final differences = <String, String>{};
    if (draft.tag != tag) {
      differences['tag'] = 'published ${draft.tag}, expected $tag';
    }
    if (draft.title != title) {
      differences['title'] = 'private draft title differs';
    }
    if (draft.body != body) differences['body'] = 'private draft body differs';
    final length = draft.assets!.length;
    if (length > expected.length) {
      differences['assets'] =
          'found $length, expected at most ${expected.length}';
    } else {
      final prefix =
          expected.take(length).map((asset) => asset.publicName).toSet();
      final missing = prefix.difference(draft.assets!);
      final extra = draft.assets!.difference(prefix);
      for (final name in missing) {
        differences[name] = 'missing from canonical prefix';
      }
      for (final name in extra) {
        differences[name] = 'not in canonical prefix';
      }
    }
    if (differences.isNotEmpty) {
      return (
        inspection: Inspection.conflict(
            'private draft differs from the frozen release',
            evidence: differences),
        length: length,
      );
    }
    final prefix = expected.take(length).toList();
    final bytes = _inspectDraftAssets(
      draft,
      {for (final asset in prefix) asset.publicName: asset.sha256},
      {for (final asset in prefix) asset.publicName: asset.size},
    );
    return (inspection: bytes, length: length);
  }

  Future<_Lookup> _viewById(String id) async {
    final ToolResult result;
    try {
      result = await tools.run(
        'gh',
        ['api', 'repos/$repository/releases/$id'],
        workingDirectory: workingDirectory,
      );
    } on Object catch (error) {
      return _Unreadable('GitHub could not read release $id: $error');
    }
    if (!result.ok) {
      return _Unreadable(
        'GitHub could not read release $id: ${result.summary}',
      );
    }
    return _decodeRelease(result.stdout);
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
    final ToolResult result;
    try {
      result = await tools.run(
        'gh',
        ['api', 'repos/$repository/releases/tags/$tag'],
        workingDirectory: workingDirectory,
      );
    } on Object catch (error) {
      return _Unreadable('GitHub could not be read: $error');
    }

    if (!result.ok) {
      if (result.summary.contains('(HTTP 404)')) {
        return await _repositoryIsReadable()
            ? const _NotFound()
            : _Unreadable(
                'the repository $repository could not be read, so rk cannot '
                'tell whether $tag is released',
              );
      }
      return _Unreadable('GitHub could not be read: ${result.summary}');
    }

    return _decodeRelease(result.stdout);
  }

  _Lookup _decodeRelease(String response) {
    try {
      final decoded = jsonDecode(response);
      if (decoded is! Map) {
        return const _Unreadable('GitHub answered something unreadable');
      }
      if (decoded['tag_name'] is! String ||
          decoded['draft'] is! bool ||
          decoded['id'] == null) {
        return const _Unreadable(
          'GitHub answered without a readable release identity',
        );
      }
      final assets = decoded['assets'];
      if (assets is! List) {
        return const _Unreadable(
          'GitHub answered without a readable asset inventory',
        );
      }
      final assetNames = <String>{};
      final assetMetadata = <String, _ReleaseAsset>{};
      for (final asset in assets) {
        if (asset is! Map || asset['name'] is! String) {
          return const _Unreadable(
            'GitHub returned a malformed asset inventory',
          );
        }
        final name = asset['name'] as String;
        if (!assetNames.add(name)) {
          return const _Unreadable(
            'GitHub returned duplicate names in its asset inventory',
          );
        }
        assetMetadata[name] = _ReleaseAsset(
          id: asset['id'] is int ? '${asset['id']}' : null,
          state: asset['state'] is String ? asset['state'] as String : null,
          size: asset['size'] is int ? asset['size'] as int : null,
          digest: asset['digest'] is String ? asset['digest'] as String : null,
        );
      }
      final hasTitle = decoded.containsKey('name');
      final hasBody = decoded.containsKey('body');
      if ((hasTitle && decoded['name'] != null && decoded['name'] is! String) ||
          (hasBody && decoded['body'] != null && decoded['body'] is! String)) {
        return const _Unreadable(
          'GitHub returned malformed release metadata',
        );
      }
      return _Found(_Release(
        tag: decoded['tag_name'] as String,
        isDraft: decoded['draft'] as bool,
        id: '${decoded['id']}',
        assets: assetNames,
        assetMetadata: assetMetadata,
        title: hasTitle ? decoded['name'] as String? : null,
        body: hasBody ? decoded['body'] as String? : null,
        titleReadable: hasTitle,
        bodyReadable: hasBody,
      ));
    } on Object catch (error) {
      return _Unreadable('GitHub answered something unreadable: $error');
    }
  }

  /// Whether the forge will tell rk about the repository at all.
  Future<bool> _repositoryIsReadable() async {
    try {
      final result = await tools.run(
        'gh',
        ['repo', 'view', repository, '--json', 'name'],
        workingDirectory: workingDirectory,
      );
      return result.ok;
    } on Object {
      return false;
    }
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
      final drafts = <_Release>[];
      for (final page in decoded) {
        if (page is! List) return null;
        for (final entry in page) {
          // A malformed entry can be the same-tag draft rk is trying to sweep.
          // Ignoring it would turn "could not read" into "none exists" and
          // create another ambiguous draft.
          if (entry is! Map ||
              entry['tag_name'] is! String ||
              entry['draft'] is! bool ||
              entry['id'] == null) {
            return null;
          }
          if (entry['tag_name'] == tag && entry['draft'] == true) {
            drafts.add(_Release(
              tag: tag,
              isDraft: true,
              id: '${entry['id']}',
              assets: null,
              assetMetadata: null,
            ));
          }
        }
      }
      return drafts;
    } on Object {
      return null;
    }
  }

  static String? _releaseIdIn(String response) {
    try {
      final decoded = jsonDecode(response);
      final id = decoded is Map ? decoded['id'] : null;
      return id == null ? null : '$id';
    } on Object {
      return null;
    }
  }

  static String? _versionIn(String tag, List<String> pattern) {
    final prefix = pattern[0];
    final suffix = pattern[1];
    if (!tag.startsWith(prefix) || !tag.endsWith(suffix)) return null;
    final end = tag.length - suffix.length;
    if (end <= prefix.length) return null;
    return tag.substring(prefix.length, end);
  }
}

bool _isPublicAssetName(String name) =>
    name.isNotEmpty &&
    name != '.' &&
    name != '..' &&
    !name.contains('/') &&
    !name.contains(r'\') &&
    !name.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f);

class _Release {
  _Release({
    required this.tag,
    required this.isDraft,
    required this.id,
    required this.assets,
    required this.assetMetadata,
    this.title,
    this.body,
    this.titleReadable = false,
    this.bodyReadable = false,
  });

  final String tag;
  final bool isDraft;
  final String id;

  final String? title;
  final String? body;
  final bool titleReadable;
  final bool bodyReadable;

  /// Asset names, or null when rk could not read them.
  final Set<String>? assets;

  /// Server-computed facts for the assets in this exact release-id response.
  final Map<String, _ReleaseAsset>? assetMetadata;
}

class _ReleaseAsset {
  const _ReleaseAsset({
    required this.id,
    required this.state,
    required this.size,
    required this.digest,
  });

  final String? id;
  final String? state;
  final int? size;
  final String? digest;
}

/// One exact staged file and the independent filename GitHub presents.
class GithubReleaseAssetUpload {
  const GithubReleaseAssetUpload({
    required this.publicName,
    required this.stagedPath,
    required this.size,
    required this.sha256,
  });

  final String publicName;
  final String stagedPath;
  final int size;
  final String sha256;
}

/// The immutable GitHub Release identity recorded by a completed stage.
class GithubReleaseExpectation {
  GithubReleaseExpectation({
    required this.tag,
    required this.title,
    required this.body,
    required Map<String, String> assetSha256,
  }) : assetSha256 = Map.unmodifiable(assetSha256);

  final String tag;
  final String title;
  final String body;

  /// Exact public asset name to lowercase or uppercase SHA-256.
  final Map<String, String> assetSha256;
}

/// The public facts needed to verify a release after its local stage is gone.
class GithubManifestExpectation {
  GithubManifestExpectation({
    required this.unit,
    required this.version,
    required this.tag,
    required this.sourceCommit,
    required this.title,
    required this.body,
    required this.manifestSha256,
    required Set<String> publicAssets,
  }) : publicAssets = Set.unmodifiable(publicAssets);

  final String unit;
  final String version;
  final String tag;

  /// The independently authenticated source anchor: the remote tag's peeled
  /// commit. The manifest carries the same fact, and a commit already binds
  /// its tree, so one anchor is the whole comparison.
  final String sourceCommit;
  final String title;
  final String body;

  /// SHA-256 read from the tag's authenticated manifest binding.
  final String manifestSha256;

  /// Exact release inventory, including `release-manifest.json`.
  final Set<String> publicAssets;
}

/// Stable public facts for recovering one asset from a historical release.
///
/// [sourceCommit] is the peeled commit proven by the authenticated Git tag;
/// [manifestSha256] is the digest bound into that tag. Together they prevent a
/// valid-looking manifest from redefining either the release source or its
/// artifacts. The manifest supplies the old release's inventory, which is
/// intentionally not reconstructed from today's configuration.
class GithubHistoricalManifestExpectation {
  const GithubHistoricalManifestExpectation({
    required this.unit,
    required this.version,
    required this.tag,
    required this.sourceCommit,
    required this.manifestSha256,
    this.title,
  });

  final String unit;
  final String version;
  final String tag;
  final String sourceCommit;
  final String manifestSha256;

  /// Optional stable title. Historical changelog bodies are not required.
  final String? title;
}

/// The result of reading one artifact through a manifest-bound release check.
///
/// [bytes] is non-null exactly when [inspection] is exact. The list is an
/// immutable defensive copy, so a caller cannot mutate the verified value it
/// was handed.
class GithubManifestAssetRead {
  const GithubManifestAssetRead._(this.inspection, this.bytes);

  final Inspection inspection;
  final List<int>? bytes;
}

/// An authenticated release manifest, withheld unless the whole observation
/// is exact.
class GithubManifestRead {
  const GithubManifestRead._(this.inspection, this.manifest);

  final Inspection inspection;
  final ReleaseManifest? manifest;
}

class _ManifestObservation {
  const _ManifestObservation._(
    this.inspection,
    this.manifest,
    this.verifiedBytes,
  );

  const _ManifestObservation.failed(Inspection inspection)
      : this._(inspection, null, const {});

  _ManifestObservation.exact(
    Inspection inspection,
    ReleaseManifest manifest,
    Map<String, List<int>> verifiedBytes,
  ) : this._(
          inspection,
          manifest,
          Map.unmodifiable({
            for (final entry in verifiedBytes.entries)
              entry.key: List<int>.unmodifiable(entry.value),
          }),
        );

  final Inspection inspection;
  final ReleaseManifest? manifest;
  final Map<String, List<int>> verifiedBytes;
}

class _AssetObservation {
  const _AssetObservation._(this.inspection, this.verifiedBytes);

  const _AssetObservation.failed(Inspection inspection)
      : this._(inspection, const {});

  _AssetObservation.exact(
    Inspection inspection,
    Map<String, List<int>> verifiedBytes,
  ) : this._(
          inspection,
          Map.unmodifiable(verifiedBytes),
        );

  final Inspection inspection;
  final Map<String, List<int>> verifiedBytes;
}

class _ReleaseObservation {
  const _ReleaseObservation._(this.inspection, this.release);

  const _ReleaseObservation.failed(Inspection inspection)
      : this._(inspection, null);

  _ReleaseObservation.exact(_Release release)
      : this._(const Inspection.exact(detail: 'published'), release);

  final Inspection inspection;
  final _Release? release;
}

bool _isSha256(String value) => RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(value);

bool _isObjectId(String value) =>
    RegExp(r'^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})$').hasMatch(value);

String _shown(String? value) => value == null ? '<none>' : '"$value"';

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
    this.draftEffect = DraftEffect.none,
  });

  const PublishOutcome.published(
    String url, {
    DraftEffect draftEffect = DraftEffect.none,
  }) : this._(url, null, true, draftEffect: draftEffect);

  /// No public release was confirmed. [draftEffect] records the separate
  /// private transaction, which can have changed even though publication did
  /// not happen.
  const PublishOutcome.failed(
    String problem, {
    DraftEffect draftEffect = DraftEffect.none,
  }) : this._(null, problem, false, draftEffect: draftEffect);

  /// Something may exist that rk could not read back, so the next run must
  /// inspect rather than assume.
  const PublishOutcome.lostTrack(
    String problem, {
    String? url,
    DraftEffect draftEffect = DraftEffect.none,
  }) : this._(url, problem, false, draftEffect: draftEffect);

  /// rk read back what it did and it is wrong, and it cannot be taken back.
  const PublishOutcome.terminal(
    String problem, {
    required String url,
    required String permanent,
    DraftEffect draftEffect = DraftEffect.none,
  }) : this._(
          url,
          problem,
          false,
          permanent: permanent,
          draftEffect: draftEffect,
        );

  final String? url;
  final String? problem;

  /// Whether rk read back what it did.
  final bool confirmed;

  /// What is already public and cannot be undone, stated before any remedy.
  final String? permanent;

  /// What this attempt did to GitHub's private draft surface.
  final DraftEffect draftEffect;

  bool get ok => confirmed;

  /// A public release may exist that rk could not verify.
  bool get mayHaveActed => !confirmed && url != null;
}

/// The private half of GitHub's draft-first release transaction.
enum DraftEffect {
  /// No private mutation began.
  none,

  /// The current attempt made and observed a private change.
  changed,

  /// A private mutation was attempted and its result could not be determined.
  uncertain,
}
