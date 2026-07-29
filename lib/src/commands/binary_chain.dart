import 'dart:convert';
import 'dart:io';

import '../builds/capability.dart';
import '../builds/dart_cli.dart';
import '../destinations/github_release.dart';
import '../destinations/homebrew.dart';
import '../engine/output.dart';
import '../engine/resolve.dart';
import '../engine/tools.dart';
import '../transforms/archive.dart';
import '../transforms/digest.dart';
import '../transforms/macos.dart';

/// Produces and ships a unit's binaries.
///
/// Every artifact is built into the workspace, checked, and only then handed
/// to a destination. The workspace is a cache: it is keyed by release and
/// commit, deleted when the release completes, and never seeded from another
/// run.
class BinaryChain {
  BinaryChain({
    required this.tools,
    required this.output,
    required this.workspace,
    required this.repositoryRoot,
    required this.capabilities,
  });

  final Tools tools;
  final Output output;

  /// Where intermediates live for this release.
  final String workspace;

  final String repositoryRoot;
  final HostCapabilities capabilities;

  /// Builds, signs, notarizes and archives every declared platform.
  ///
  /// Returns the finished assets, or null when something stopped it — each
  /// failure having already been reported where it happened.
  Future<List<ReleaseAsset>?> produce({
    required ResolvedUnit unit,
    required ResolvedProject project,
    required String? appleTeam,
    required String? codeId,
  }) async {
    Directory(workspace).createSync(recursive: true);

    final builder = DartCliBuilder(tools: tools, capabilities: capabilities);
    final signer = MacOsSigner(tools: tools);
    final notarizer = MacOsNotarizer(tools: tools);

    final assets = <ReleaseAsset>[];
    final version = project.version.canonical;
    final executable = project.executable!;
    final projectDirectory = project.pubspec.directory == '.'
        ? repositoryRoot
        : '$repositoryRoot/${project.pubspec.directory}';

    for (final platform in project.binaryPlatforms) {
      final capability = capabilities.resolve(platform);
      if (!capability.canProduce) {
        output.line(platform, mark: Mark.blocked, note: capability.reason);
        return null;
      }

      final binary = '$workspace/$platform/$executable';
      Directory('$workspace/$platform').createSync(recursive: true);

      output.progress('building $platform');
      final built = await builder.build(
        platform: platform,
        entryPoint: 'bin/$executable.dart',
        output: binary,
        workingDirectory: projectDirectory,
        expectedVersion: version,
      );
      if (!built.ok) {
        output.line(platform, mark: Mark.blocked, note: built.problem);
        return null;
      }

      if (platform.startsWith('macos-')) {
        if (appleTeam == null || codeId == null) {
          output.line(
            platform,
            mark: Mark.blocked,
            note: 'no signing identity is established for this project',
          );
          output.say(
            'the first signed release states it once: add [identity] with '
            'apple_team and code_id',
            depth: 1,
          );
          return null;
        }

        output.progress('signing $platform');
        final signed = await signer.sign(
          binary: binary,
          team: appleTeam,
          codeId: codeId,
        );
        if (!signed.ok) {
          output.line(platform, mark: Mark.blocked, note: signed.problem);
          return null;
        }
        output.line(platform, mark: Mark.done, note: 'signed · $appleTeam');

        output.progress(
          'notarizing $platform · typically ${MacOsNotarizer.typicalWait}',
        );
        final zip = '$workspace/$platform/$executable.zip';
        final zipped = await tools.run(
          'ditto',
          ['-c', '-k', '--keepParent', binary, zip],
        );
        if (!zipped.ok) {
          output.line(platform, mark: Mark.blocked, note: zipped.summary);
          return null;
        }

        final notarized = await notarizer.submit(zip);
        if (!notarized.ok) {
          output.line(platform, mark: Mark.blocked, note: notarized.problem);
          if (notarized.remedy != null) {
            output.say(notarized.remedy!, depth: 1);
          }
          return null;
        }
        output.line(platform, mark: Mark.done, note: 'notarized');
      }

      final asset = await _archive(
        platform: platform,
        binary: binary,
        executable: executable,
        project: project,
        version: version,
      );
      if (asset == null) return null;
      assets.add(asset);
      output.line(platform, mark: Mark.done, note: asset.name);
    }

    // The checksums describe the assets, so they are produced from them.
    final sums = Checksums.render({
      for (final asset in assets) asset.name: asset.bytes,
    });
    final sumsPath = '$workspace/SHA256SUMS';
    File(sumsPath).writeAsStringSync(sums);
    assets.add(
      ReleaseAsset(
        name: 'SHA256SUMS',
        path: sumsPath,
        bytes: utf8.encode(sums),
        platform: null,
      ),
    );

    return assets;
  }

  Future<ReleaseAsset?> _archive({
    required String platform,
    required String binary,
    required String executable,
    required ResolvedProject project,
    required String version,
  }) async {
    final directory = project.pubspec.directory == '.'
        ? repositoryRoot
        : '$repositoryRoot/${project.pubspec.directory}';

    final entries = <ArchiveEntry>[
      ArchiveEntry(
        name: executable,
        bytes: File(binary).readAsBytesSync(),
        executable: true,
      ),
    ];

    // LICENSE and README travel with the binary by convention, not by
    // configuration.
    for (final name in const ['LICENSE', 'README.md']) {
      final file = File('$directory/$name');
      if (file.existsSync()) {
        entries.add(ArchiveEntry(name: name, bytes: file.readAsBytesSync()));
      }
    }

    final bytes = ArchiveBuilder.gzip(ArchiveBuilder.tar(entries));
    final name = '$executable-$version-$platform.tar.gz';
    final path = '$workspace/$name';
    File(path).writeAsBytesSync(bytes);

    return ReleaseAsset(
      name: name,
      path: path,
      bytes: bytes,
      platform: platform,
    );
  }

  /// Publishes the assets as one immutable release.
  Future<String?> publishRelease({
    required String repository,
    required String tag,
    required String title,
    required List<ReleaseAsset> assets,
  }) async {
    final release = GithubRelease(
      tools: tools,
      repository: repository,
      workingDirectory: repositoryRoot,
    );

    output.progress('publishing ${assets.length} assets');
    final published = await release.publish(
      tag: tag,
      title: title,
      assetPaths: assets.map((a) => a.path).toList(),
    );
    if (!published.ok) {
      output.line('github-release',
          mark: Mark.blocked, note: published.problem);
      return null;
    }
    output.line(
      'github-release',
      mark: Mark.done,
      note: '${assets.length} assets, immutable',
    );
    return published.url;
  }

  /// Moves the tap formula to this release.
  Future<bool> updateFormula({
    required String tap,
    required String repository,
    required String tag,
    required ResolvedProject project,
    required List<ReleaseAsset> assets,
  }) async {
    final executable = project.executable!;
    final formula = HomebrewFormula.render(
      className: HomebrewFormula.classNameFor(executable),
      description: 'Released by rk',
      homepage: 'https://github.com/$repository',
      version: project.version.canonical,
      repository: repository,
      tag: tag,
      executable: executable,
      assets: {
        for (final asset in assets)
          if (asset.platform != null)
            asset.platform!: PlatformAsset(
              name: asset.name,
              sha256: Sha256.hex(asset.bytes),
            ),
      },
    );

    final checkout = '$workspace/tap';
    final result = await HomebrewTap(
      tools: tools,
      tap: tap,
      checkout: checkout,
    ).update(
      formulaPath: 'Formula/$executable.rb',
      contents: formula,
      message: '$executable ${project.version}',
    );

    if (!result.ok) {
      output.line('homebrew', mark: Mark.blocked, note: result.problem);
      return false;
    }
    output.line(
      'homebrew',
      mark: Mark.done,
      note: result.changed ? 'formula updated' : 'formula already current',
    );
    return true;
  }
}

/// A finished file a release ships.
class ReleaseAsset {
  ReleaseAsset({
    required this.name,
    required this.path,
    required this.bytes,
    required this.platform,
  });

  final String name;
  final String path;
  final List<int> bytes;

  /// Null for an asset that is not per-platform, such as the checksums.
  final String? platform;
}
