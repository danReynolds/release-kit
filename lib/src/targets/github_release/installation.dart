import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../builds/binary_artifact.dart';
import '../../engine/assets.dart';
import '../../engine/git.dart';
import '../../engine/release_manifest.dart';
import '../../engine/stage_archive.dart';
import '../../engine/tools.dart';
import '../../engine/version.dart';
import '../../installations/model.dart';
import '../../installations/metadata.dart';
import '../../installations/provider.dart';
import '../../installations/store.dart';
import '../../transforms/digest.dart';

/// Public release assets, verified against RK's release manifest before use.
/// The checksum proves consistency with that release, not independent authorship.
class GithubInstallationProvider
    implements InstallationProvider, InstallationUpdates {
  GithubInstallationProvider(
    this.tools,
    this.store,
    this.platform, {
    this.fetch = fetchHttps,
  });
  final Tools tools;
  final InstallationStore store;
  final String platform;
  final HttpsFetch fetch;
  @override
  InstallationSource get source => InstallationSource.github;

  @override
  Future<SourceInspection> inspect(ExecutableProject project) async {
    if (project.repository == null || project.unit.tagPattern == null) {
      return const SourceInspection(
        problem:
            'GitHub installs need an origin repository and release tag pattern.',
      );
    }
    if (!project.project.binaryPlatforms.contains(platform)) {
      return SourceInspection(
        problem: 'This project does not publish a $platform binary.',
      );
    }
    // Each download is a directory named by its version; the highest one is
    // the installation, read from disk rather than from a receipt.
    final downloads = Directory(store.downloads(project));
    final versions = [
      if (downloads.existsSync())
        for (final entry in downloads.listSync())
          if (Version.tryParse(
                entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty),
              )
              case final version?)
            if (File('${entry.path}/${project.commands.single}').existsSync())
              version,
    ]..sort();
    if (versions.isEmpty) return const SourceInspection();
    return SourceInspection(
      installation: _installation(project, versions.last.canonical),
    );
  }

  Installation _installation(ExecutableProject project, String version) {
    final location = '${store.downloads(project)}/$version';
    return Installation(
      source: source,
      version: version,
      location: location,
      commands: {
        project.commands.single: LaunchCommand(
          '$location/${project.commands.single}',
        ),
      },
    );
  }

  @override
  Future<AvailableInstallation> latest(
    ExecutableProject project, {
    InstallationCheck? check,
  }) async {
    if (project.repository == null ||
        project.unit.tagPattern == null ||
        !project.project.binaryPlatforms.contains(platform)) {
      throw InstallationFailure('No configured GitHub binary for $platform.');
    }
    // Release summaries advertise their asset inventory. Ignore newer releases
    // that do not carry this project's host binary (including multi-unit repos).
    for (var page = 1; page <= 10; page++) {
      final uri = Uri.https(
        'api.github.com',
        '/repos/${project.repository}/releases',
        {'per_page': '100', 'page': '$page'},
      );
      final bytes = await fetch(uri, 8 * 1024 * 1024, check: check);
      final list = (jsonDecode(utf8.decode(bytes)) as List)
          .cast<Map<String, dynamic>>();
      final candidates = <(Map<String, dynamic>, Version)>[];
      for (final item in list) {
        if (item['draft'] != false || item['prerelease'] != false) continue;
        final version = GitState.versionIn(
          item['tag_name'] as String,
          project.unit.tagPattern!,
        );
        final parsed = version == null ? null : Version.tryParse(version);
        if (parsed != null && !parsed.isPrerelease) {
          candidates.add((item, parsed));
        }
      }
      candidates.sort((a, b) => b.$2.compareTo(a.$2));
      for (final (item, parsed) in candidates) {
        final version = parsed.canonical;
        final tag = item['tag_name'] as String;
        final archiveName = ReleaseAssets.archiveName(
          project.commands.single,
          version,
          platform,
        );
        if (item['assets'] case final List assets) {
          final names = assets.whereType<Map>().map((a) => a['name']).toSet();
          if (!names.contains(archiveName) ||
              !names.contains(ReleaseAssets.manifest)) {
            continue;
          }
        }
        Uri asset(String name) => Uri(
          scheme: 'https',
          host: 'github.com',
          pathSegments: [
            ...project.repository!.split('/'),
            'releases',
            'download',
            tag,
            name,
          ],
        );
        final manifest = ReleaseManifest.parse(
          utf8.decode(
            await fetch(
              asset(ReleaseAssets.manifest),
              2 * 1024 * 1024,
              check: check,
            ),
          ),
        );
        if (manifest.unit != project.unit.name ||
            manifest.version != version ||
            manifest.tag != tag) {
          throw const InstallationFailure(
            'The release manifest does not match the selected release.',
          );
        }
        final metadata = manifest.artifacts
            .where((a) => a.name == archiveName)
            .firstOrNull;
        if (metadata == null || metadata.size > 128 * 1024 * 1024) continue;
        return _GithubRelease(project, version, asset(archiveName), metadata);
      }
      if (list.length < 100) break;
    }
    throw InstallationFailure(
      'No public stable $platform release matches ${project.unit.name}.',
    );
  }

  @override
  Future<Installation> install(
    ExecutableProject project,
    void Function(String) progress,
  ) async {
    progress('Finding the latest ${project.unit.name} release…');
    return download(project, await latest(project), progress);
  }

  @override
  Future<Installation> download(
    ExecutableProject project,
    AvailableInstallation release,
    void Function(String) progress,
  ) async {
    if (release is! _GithubRelease) {
      throw const InstallationFailure('Invalid GitHub release.');
    }
    final version = release.version;
    final metadata = release.metadata;
    progress('Downloading ${project.name} $version…');
    final bytes = await fetch(release.archive, metadata.size);
    if (bytes.length != metadata.size || Sha256.hex(bytes) != metadata.sha256) {
      throw const InstallationFailure(
        'The downloaded archive failed its release checksum.',
      );
    }
    progress('Installing ${project.name} $version…');
    final decoded = await decodeInstallationArchive(
      bytes,
      project.commands.single,
    );
    final parent = store.downloads(project);
    Directory(parent).createSync(recursive: true);
    final destination = '$parent/$version';
    if (Directory(destination).existsSync()) {
      Directory(destination).deleteSync(recursive: true);
    }
    final temporary = Directory(parent).createTempSync('preparing-');
    try {
      for (final entry in decoded.files.entries) {
        final file = File('${temporary.path}/${entry.key}');
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(entry.value, flush: true);
        final mode =
            decoded.artifact.files
                    .where((f) => f.path == entry.key)
                    .firstOrNull
                    ?.executable ==
                true
            ? '700'
            : '600';
        await checked(tools, '/bin/chmod', [mode, file.path]);
      }
      if (platform.startsWith('macos-')) {
        for (final file in decoded.artifact.signedFiles) {
          await checked(tools, '/usr/bin/codesign', [
            '--verify',
            '--strict',
            '${temporary.path}/${file.path}',
          ]);
        }
      }
      final smoke = await tools.run(
        '${temporary.path}/${decoded.artifact.entryPoint}',
        ['--version'],
        timeout: const Duration(minutes: 2),
      );
      if (!smoke.ok || !smoke.stdout.contains(version)) {
        throw InstallationFailure(
          'The downloaded command did not report $version.',
          smoke.summary,
        );
      }
      temporary.renameSync(destination);
    } finally {
      if (temporary.existsSync()) temporary.deleteSync(recursive: true);
    }
    return _installation(project, version);
  }

  @override
  Future<void> uninstall(
    ExecutableProject project,
    Installation installation,
  ) async {
    final downloads = Directory(store.downloads(project));
    if (downloads.existsSync()) downloads.deleteSync(recursive: true);
  }
}

class InstallationArchive {
  InstallationArchive(this.artifact, this.files);
  final BinaryArtifact artifact;
  final Map<String, List<int>> files;
}

/// Validate the whole inventory before writing any path. Never extract archive
/// permissions, links, device nodes, arbitrary paths, or unknown bundle layouts.
Future<InstallationArchive> decodeInstallationArchive(
  List<int> compressed,
  String command,
) async {
  const limit = 512 * 1024 * 1024;
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in gzip.decoder.bind(Stream.value(compressed))) {
    if (bytes.length + chunk.length > limit) {
      throw const InstallationFailure(
        'The unpacked archive exceeds the installation limit.',
      );
    }
    bytes.add(chunk);
  }
  try {
    final decoded = StageArchiveInventory.decodeTar(bytes.takeBytes());
    if (decoded.artifact.entryPoint != command) {
      throw const FormatException('The archive exports a different command.');
    }
    return InstallationArchive(decoded.artifact, decoded.files);
  } on FormatException catch (error) {
    throw InstallationFailure(
      'The release archive does not match its executable layout.',
      error.message,
    );
  }
}

class _GithubRelease extends AvailableInstallation {
  _GithubRelease(
    ExecutableProject project,
    String version,
    this.archive,
    this.metadata,
  ) : super(project, InstallationSource.github, version);
  final Uri archive;
  final ReleaseManifestArtifact metadata;
}
