// Read-only provider qualification against this repository's public sources.
// Optional --download=pub or --download=github installs into an isolated temp
// directory, prints the receipt, then deletes it. Never alters user routing.
import 'dart:io';
import 'package:rk/src/builds/capability.dart';
import 'package:rk/src/engine/config.dart';
import 'package:rk/src/engine/diagnostic.dart';
import 'package:rk/src/engine/git.dart';
import 'package:rk/src/engine/resolve.dart';
import 'package:rk/src/engine/source_tree.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/installations/discovery.dart';
import 'package:rk/src/installations/manager.dart';
import 'package:rk/src/installations/metadata.dart';
import 'package:rk/src/installations/model.dart';
import 'package:rk/src/installations/store.dart';
import 'package:rk/src/targets/github_release/installation.dart';
import 'package:rk/src/targets/homebrew/installation.dart';
import 'package:rk/src/targets/pub_dev/installation.dart';

Future<void> main(List<String> args) async {
  final requested = args
      .where((a) => a.startsWith('--download='))
      .map((a) => a.substring(11))
      .toSet();
  if (requested.length > 1) {
    throw ArgumentError('Qualify one isolated download at a time.');
  }
  if (args.any((a) => !{'--download=pub', '--download=github'}.contains(a))) {
    throw ArgumentError(
      'Use --download=pub or --download=github, or no arguments for read-only checks.',
    );
  }
  final root = Directory.current.path;
  final tree = FileSystemSourceTree(root);
  final diagnostics = Diagnostics();
  final config = ReleaseConfig.parse(
    tree.read('release.toml')!,
    'release.toml',
    diagnostics,
  )!;
  final resolution = Resolution.resolve(config, tree, diagnostics)!;
  final projects = executableProjects(
    resolution,
    root,
    repository: await GitState.readOrigin(root),
  );
  final scratch = Directory.systemTemp.createTempSync('rk-source-probe-');
  const tools = SystemTools();
  final environment = {
    ...Platform.environment,
    'PUB_CACHE': '${scratch.path}/pub-cache',
  };
  final store = InstallationStore('${scratch.path}/store', tools);
  final manager = InstallationManager(
    store: store,
    environment: environment,
    providers: {
      InstallationSource.pub: PubInstallationProvider(
        tools,
        Platform.resolvedExecutable,
        environment,
      ),
      InstallationSource.github: GithubInstallationProvider(
        tools,
        store,
        HostCapabilities.inspect().hostPlatform,
      ),
      InstallationSource.homebrew: HomebrewInstallationProvider(
        tools,
        findExecutable('brew', environment),
      ),
    },
  );
  try {
    await Future.wait([
      for (final project in projects)
        for (final source in project.sources.where(
          (s) => s != InstallationSource.local,
        ))
          () async {
            final check = InstallationCheck();
            try {
              final started = DateTime.now();
              final release = await manager.latest(
                project,
                source,
                check: check,
              );
              stdout.writeln(
                '${source.label}: ${release.version} (${DateTime.now().difference(started).inMilliseconds} ms)',
              );
              if (requested.contains(source.name)) {
                // Manager mutations are serialized below by invoking one download per run.
                final result = await manager.download(
                  project,
                  release,
                  progress: stdout.writeln,
                );
                stdout.writeln(result);
                if (store.selected(project) != null) {
                  throw StateError('Download changed selection');
                }
              }
            } catch (error) {
              stderr.writeln(
                '${source.label}: $error ${error is InstallationFailure ? error.remedy : ''}',
              );
              exitCode = 1;
            } finally {
              check.cancel();
            }
          }(),
    ]);
  } finally {
    scratch.deleteSync(recursive: true);
  }
}
