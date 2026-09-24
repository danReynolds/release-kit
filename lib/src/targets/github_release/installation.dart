import 'dart:convert';
import 'dart:async';
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
import '../../installations/provider.dart';
import '../../installations/store.dart';
import '../../transforms/digest.dart';

/// Public release assets, verified against RK's release manifest before use.
/// The checksum proves consistency with that release, not independent authorship.
class GithubInstallationProvider implements InstallationProvider {
  GithubInstallationProvider(
    this.tools,
    this.store,
    this.platform, {
    this.fetch = fetchPublicRelease,
  });
  final Tools tools;
  final InstallationStore store;
  final String platform;
  final Future<Uint8List> Function(Uri, int) fetch;
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
    final installation = store.recorded(project, source);
    if (installation != null) {
      _validateLocation(project, installation);
      if (installation.commands.values.any(
        (c) =>
            !File(c.executable).existsSync() ||
            c.requiredFiles.any((path) => !File(path).existsSync()),
      )) {
        return SourceInspection(
          installation: installation,
          problem:
              'The GitHub installation is incomplete. Remove it before reinstalling.',
        );
      }
    }
    return SourceInspection(installation: installation);
  }

  void _validateLocation(ExecutableProject project, Installation installation) {
    final parent = '${store.projectRoot(project)}/downloads/';
    if (!installation.managed ||
        !installation.location.startsWith(parent) ||
        !RegExp(
          r'^github-[a-f0-9]{64}$',
        ).hasMatch(installation.location.substring(parent.length))) {
      throw const InstallationFailure(
        'The GitHub receipt is not an owned installation.',
      );
    }
    store.validateManagedDirectory(installation.location);
  }

  @override
  Future<Installation> install(
    ExecutableProject project,
    void Function(String) progress,
  ) async {
    progress('Finding the latest ${project.unit.name} release…');
    Map<String, dynamic>? release;
    String? version;
    // Scope releases by the configured unit's tag, including multi-unit repos.
    for (var page = 1; page <= 10 && release == null; page++) {
      final list =
          jsonDecode(
                utf8.decode(
                  await fetch(
                    Uri.https(
                      'api.github.com',
                      '/repos/${project.repository}/releases',
                      {'per_page': '100', 'page': '$page'},
                    ),
                    8 * 1024 * 1024,
                  ),
                ),
              )
              as List;
      for (final item in list.cast<Map<String, dynamic>>()) {
        if (item['draft'] != false || item['prerelease'] != false) continue;
        final candidate = GitState.versionIn(
          item['tag_name'] as String,
          project.unit.tagPattern!,
        );
        final parsed = candidate == null ? null : Version.tryParse(candidate);
        if (parsed == null || parsed.isPrerelease) continue;
        release = item;
        version = candidate;
        break;
      }
      if (list.length < 100) break;
    }
    if (release == null) {
      throw InstallationFailure(
        'No public stable release was found for ${project.unit.name}.',
        'Publish a release with RK first, or choose another source.',
      );
    }
    final tag = release['tag_name'] as String;
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
      utf8.decode(await fetch(asset(ReleaseAssets.manifest), 2 * 1024 * 1024)),
    );
    if (manifest.unit != project.unit.name ||
        manifest.version != version ||
        manifest.tag != tag) {
      throw const InstallationFailure(
        'The release manifest does not match the selected release.',
      );
    }
    final archiveName = ReleaseAssets.archiveName(
      project.commands.single,
      version!,
      platform,
    );
    final metadata = manifest.artifacts
        .where((a) => a.name == archiveName)
        .firstOrNull;
    if (metadata == null || metadata.size > 128 * 1024 * 1024) {
      throw InstallationFailure(
        'No supported $platform archive exists in this release.',
      );
    }
    progress('Downloading ${project.name} $version…');
    final bytes = await fetch(asset(archiveName), metadata.size);
    if (bytes.length != metadata.size || Sha256.hex(bytes) != metadata.sha256) {
      throw const InstallationFailure(
        'The downloaded archive failed its release checksum.',
      );
    }
    final decoded = await decodeInstallationArchive(
      bytes,
      project.commands.single,
    );
    final parent = store.managedDirectory(project, 'downloads');
    final destination = '$parent/github-${metadata.sha256}';
    if (FileSystemEntity.typeSync(destination, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw InstallationFailure(
        'A previous download already occupies $destination.',
        'Keep it for diagnosis or remove it before retrying.',
      );
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
    return Installation(
      source: source,
      version: version,
      location: destination,
      managed: true,
      commands: {
        project.commands.single: LaunchCommand(
          '$destination/${decoded.artifact.entryPoint}',
          requiredFiles: [
            for (final file in decoded.artifact.files)
              '$destination/${file.path}',
          ],
        ),
      },
    );
  }

  @override
  Future<void> uninstall(
    ExecutableProject project,
    Installation installation,
  ) async {
    _validateLocation(project, installation);
    final directory = Directory(installation.location);
    if (directory.existsSync()) directory.deleteSync(recursive: true);
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

Future<Uint8List> fetchPublicRelease(Uri uri, int maxBytes) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  final deadline = Timer(
    const Duration(minutes: 3),
    () => client.close(force: true),
  );
  try {
    // Follow only HTTPS redirects, with a bounded response and deadline.
    for (var redirects = 0; redirects < 6; redirects++) {
      if (uri.scheme != 'https' ||
          uri.port != 443 ||
          uri.userInfo.isNotEmpty ||
          !(const {'github.com', 'api.github.com'}.contains(uri.host) ||
              uri.host.endsWith('.githubusercontent.com'))) {
        throw const InstallationFailure(
          'A release download left the supported GitHub HTTPS hosts.',
        );
      }
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 30));
      request.followRedirects = false;
      request.headers.set('User-Agent', 'rk-installation');
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
        final location = response.headers.value('location');
        if (location == null) {
          throw const InstallationFailure(
            'A release redirect has no destination.',
          );
        }
        uri = uri.resolve(location);
        await response.drain<void>().timeout(const Duration(seconds: 10));
        continue;
      }
      if (response.statusCode != 200) {
        throw InstallationFailure(
          'GitHub download returned HTTP ${response.statusCode}.',
          'Check the public release or choose another source. Private GitHub downloads are not supported yet.',
        );
      }
      final data = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        if (data.length + chunk.length > maxBytes) {
          throw const InstallationFailure(
            'Release download exceeded its expected size.',
          );
        }
        data.add(chunk);
      }
      return data.takeBytes();
    }
    throw const InstallationFailure('Too many release download redirects.');
  } finally {
    deadline.cancel();
    client.close(force: true);
  }
}
