import '../builds/capability.dart';
import 'dart_workspace.dart';
import 'pubspec.dart';
import 'release_choice.dart';
import 'source_tree.dart';

final class InitAvailability {
  const InitAvailability.available(this.reason) : available = true;
  const InitAvailability.unavailable(this.reason) : available = false;

  final bool available;
  final String reason;

  Map<String, Object?> toJson() => {'available': available, 'reason': reason};
}

final class InitCandidate {
  InitCandidate({
    required this.name,
    required this.path,
    required this.version,
    required this.executables,
    required this.vetoesRegistry,
    required this.availability,
    required this.selected,
  });

  final String name;
  final String path;
  final String? version;
  final List<String> executables;
  final bool vetoesRegistry;
  final Map<ReleaseChoice, InitAvailability> availability;
  final Set<ReleaseChoice> selected;

  String get unit => InitPlan.unitName(name);

  InitCandidate copyWith({Set<ReleaseChoice>? selected}) => InitCandidate(
        name: name,
        path: path,
        version: version,
        executables: executables,
        vetoesRegistry: vetoesRegistry,
        availability: availability,
        selected: selected ?? this.selected,
      );

  Map<String, Object?> toJson() => {
        'unit': unit,
        'project': name,
        'path': path,
        'version': version,
        'executables': executables,
        'options': {
          for (final option in ReleaseChoice.values)
            option.id: {
              ...availability[option]!.toJson(),
              'selected': selected.contains(option),
              'effects': option.requires.map((effect) => effect.id).toList(),
            },
        },
      };
}

final class InitToggleResult {
  const InitToggleResult(this.plan, this.message);
  final InitPlan plan;
  final String message;
}

/// Static, side-effect-free discovery and selection state for `rk init`.
final class InitPlan {
  InitPlan({
    required Iterable<InitCandidate> candidates,
    required Iterable<String> notices,
    required Iterable<PlatformCapability> platformCapabilities,
    required this.gitBound,
    required this.hasRemote,
    required this.githubRepository,
  })  : candidates = List.unmodifiable(candidates),
        notices = List.unmodifiable(notices),
        platformCapabilities = List.unmodifiable(platformCapabilities);

  factory InitPlan.discover({
    required SourceTree tree,
    required bool gitBound,
    required bool hasRemote,
    required String? githubRepository,
    required Iterable<PlatformCapability> platformCapabilities,
    String? ambientPubHostedUrl,
  }) {
    final platforms = List<PlatformCapability>.unmodifiable(
      platformCapabilities,
    );
    final defaultBinaryPlatforms = platforms
        .where((platform) => platform.capability == Capability.native)
        .map((platform) => platform.platform)
        .toList();
    final native = DartWorkspaceDiscovery(tree, trackedManifests: gitBound);
    final notices = [...native.notices];
    final projects = native.projects
        .where((project) => !project.isExampleOrFixture)
        .toList();
    bool registryAvailableFor(DartProjectDiscovery project) =>
        !project.isGroupingRoot &&
        project.version != null &&
        !project.vetoesRegistry &&
        (project.publishTo == null ||
            isPubDevDestination(project.publishTo!)) &&
        (project.publishTo != null ||
            ambientPubHostedUrl == null ||
            isPubDevDestination(ambientPubHostedUrl));
    final releasable = projects.where(registryAvailableFor).length;
    final candidates = <InitCandidate>[];
    var vetoed = 0;
    for (final project in projects) {
      if (project.vetoesRegistry) vetoed++;
      final packageUsable = !project.isGroupingRoot && project.version != null;
      final repositoryPubDev =
          project.publishTo == null || isPubDevDestination(project.publishTo!);
      final ambientPubDev = project.publishTo != null ||
          ambientPubHostedUrl == null ||
          isPubDevDestination(ambientPubHostedUrl);
      final registryAvailable = registryAvailableFor(project);
      final tagAvailable = packageUsable && gitBound && hasRemote;
      final githubAvailable = tagAvailable && githubRepository != null;
      final oneExecutable = project.executables.length == 1;
      final binaryAvailable =
          packageUsable && oneExecutable && defaultBinaryPlatforms.isNotEmpty;
      final homebrewAvailable = binaryAvailable && githubAvailable;
      final selected = <ReleaseChoice>{
        if (registryAvailable) ReleaseChoice.pubDev,
        if (registryAvailable && tagAvailable && releasable == 1)
          ReleaseChoice.gitTag,
      };
      final availability = <ReleaseChoice, InitAvailability>{
        ReleaseChoice.pubDev: registryAvailable
            ? const InitAvailability.available('native Dart package coordinate')
            : InitAvailability.unavailable(
                project.isGroupingRoot
                    ? 'workspace root — select its packages instead'
                    : project.version == null
                        ? 'the native manifest declares no version'
                        : project.vetoesRegistry
                            ? 'publish_to: none vetoes registry publication'
                            : !repositoryPubDev
                                ? 'publish_to names a custom registry; this build has no matching target'
                                : !ambientPubDev
                                    ? 'PUB_HOSTED_URL redirects the default registry; declare publish_to in the pubspec first'
                                    : 'a package version is required',
              ),
        ReleaseChoice.gitTag: tagAvailable
            ? InitAvailability.available(
                selected.contains(ReleaseChoice.gitTag)
                    ? 'usable Git remote; selected conservatively'
                    : 'available; selecting writes an explicit package tag',
              )
            : InitAvailability.unavailable(
                !gitBound
                    ? 'Git is not available for this source'
                    : !hasRemote
                        ? 'add a Git remote first'
                        : 'a package version is required',
              ),
        ReleaseChoice.githubRelease: githubAvailable
            ? const InitAvailability.available(
                'changelog and manifest, plus selected binaries',
              )
            : InitAvailability.unavailable(
                !gitBound
                    ? 'GitHub Release requires Git'
                    : githubRepository == null
                        ? 'origin is not a recognized GitHub repository'
                        : 'a package version is required',
              ),
        ReleaseChoice.binary: binaryAvailable
            ? InitAvailability.available(
                'standalone ${project.executables.single} archives for '
                '${defaultBinaryPlatforms.join(', ')}',
              )
            : InitAvailability.unavailable(
                defaultBinaryPlatforms.isEmpty
                    ? 'this host cannot produce a supported binary platform'
                    : !oneExecutable
                        ? project.executables.isEmpty
                            ? 'no executable is declared'
                            : 'several executables need a hand-authored decision'
                        : 'a package version is required',
              ),
        ReleaseChoice.homebrew: homebrewAvailable
            ? const InitAvailability.available(
                'formula in the conventional or configured tap',
              )
            : const InitAvailability.unavailable(
                'Homebrew requires one standalone executable and GitHub',
              ),
      };
      candidates.add(
        InitCandidate(
          name: project.name,
          path: project.path,
          version: project.version,
          executables: project.executables,
          vetoesRegistry: project.vetoesRegistry,
          availability: Map.unmodifiable(availability),
          selected: Set.unmodifiable(selected),
        ),
      );
    }
    if (vetoed > 0) {
      notices.add(
        '$vetoed excluded from registry publication by publish_to: none',
      );
    }
    return InitPlan(
      candidates: candidates,
      notices: notices,
      platformCapabilities: platforms,
      gitBound: gitBound,
      hasRemote: hasRemote,
      githubRepository: githubRepository,
    );
  }

  final List<InitCandidate> candidates;
  final List<String> notices;
  final List<PlatformCapability> platformCapabilities;
  final bool gitBound;
  final bool hasRemote;
  final String? githubRepository;

  List<InitCandidate> get included =>
      candidates.where((candidate) => candidate.selected.isNotEmpty).toList();

  List<String> get defaultBinaryPlatforms => platformCapabilities
      .where((platform) => platform.capability == Capability.native)
      .map((platform) => platform.platform)
      .toList();

  /// Host facts worth disclosing only when the proposal actually ships a
  /// binary. Product intent stays editable in release.toml, but init's own
  /// defaults must be finishable on the machine that proposed them.
  List<String> get binaryPlatformNotices {
    if (!included.any(
      (candidate) => candidate.selected.contains(ReleaseChoice.binary),
    )) {
      return const [];
    }
    return [
      for (final platform in platformCapabilities)
        if (platform.capability != Capability.native)
          if (!platform.canProduce)
            '${platform.platform} was not selected: ${platform.reason}. '
                'Add it only when the release will run on a host that can '
                'produce it.'
          else if (!platform.canProve)
            '${platform.platform} was not selected by default. It can be '
                'built here but not executed here: ${platform.reason}. The '
                'container runtime is optional; rk will disclose the missing '
                'smoke test instead of blocking if you add this cross-build '
                'explicitly.'
          else
            '${platform.platform} was not selected by default. Add it to '
                'binary_platforms if this release should cross-build it.',
    ];
  }

  InitToggleResult toggle(int index, ReleaseChoice option) {
    final candidate = candidates[index];
    final availability = candidate.availability[option]!;
    if (!availability.available) {
      return InitToggleResult(this, availability.reason);
    }
    final selected = {...candidate.selected};
    final changed = <ReleaseChoice>[];
    if (!selected.contains(option)) {
      for (final required in {...option.requires, option}) {
        if (!candidate.availability[required]!.available) {
          return InitToggleResult(
            this,
            candidate.availability[required]!.reason,
          );
        }
        if (selected.add(required)) changed.add(required);
      }
    } else {
      final remove = <ReleaseChoice>{option};
      var grew = true;
      while (grew) {
        grew = false;
        for (final active in selected) {
          if (active.requires.any(remove.contains) && remove.add(active)) {
            grew = true;
          }
        }
      }
      for (final item in remove) {
        if (selected.remove(item)) changed.add(item);
      }
    }
    final included = selected.isNotEmpty;
    final plan = _replace(
      index,
      candidate.copyWith(selected: Set.unmodifiable(selected)),
    );
    final names = changed.map((item) => item.selectorLabel).join(', ');
    return InitToggleResult(
      plan,
      selected.contains(option)
          ? '$names enabled'
          : '$names disabled${included ? '' : '; unit excluded'}',
    );
  }

  String renderToml() {
    final buffer = StringBuffer('schema = 2\n');
    final tagged = included
        .where((candidate) => candidate.selected.contains(ReleaseChoice.gitTag))
        .toList();
    for (final candidate in included) {
      buffer.write('\n[release.${candidate.unit}]\n');
      if (candidate.path != '.') {
        buffer.write('path = "${candidate.path}"\n');
      }
      if (candidate.selected.contains(ReleaseChoice.gitTag) &&
          tagged.length > 1) {
        buffer.write('tag = "${candidate.name}-v{version}"\n');
      }
      final publish = <String>[
        if (candidate.selected.contains(ReleaseChoice.gitTag)) 'git-tag',
        if (candidate.selected.contains(ReleaseChoice.pubDev)) 'pub.dev',
        if (candidate.selected.contains(ReleaseChoice.githubRelease))
          'github-release',
        if (candidate.selected.contains(ReleaseChoice.homebrew)) 'homebrew',
      ];
      if (publish.isNotEmpty) {
        buffer.write(
          'publish = [${publish.map((item) => '"$item"').join(', ')}]\n',
        );
      }
      if (candidate.selected.contains(ReleaseChoice.binary)) {
        buffer.write(
          'binary_platforms = '
          '[${defaultBinaryPlatforms.map((item) => '"$item"').join(', ')}]\n',
        );
      }
    }
    if (candidates.any((candidate) => candidate.executables.isNotEmpty) &&
        !included.any(
          (candidate) => candidate.selected.contains(ReleaseChoice.binary),
        )) {
      buffer.write(
        '\n# A package here declares an executable, but standalone '
        'distribution was not selected.\n',
      );
    }
    return buffer.toString();
  }

  Map<String, Object?> toJson() => {
        'source': {
          'binding': gitBound ? 'gitCommit' : 'unbound',
          'git_remote': hasRemote,
          'github_repository': githubRepository,
        },
        'candidates':
            candidates.map((candidate) => candidate.toJson()).toList(),
        'binary_platforms': [
          for (final platform in platformCapabilities)
            {
              'name': platform.platform,
              'selected_by_default': platform.capability == Capability.native,
              'can_execute_here': platform.canProve,
              if (platform.reason != null) 'reason': platform.reason,
            },
        ],
        'notices': notices,
      };

  InitPlan _replace(int index, InitCandidate replacement) => InitPlan(
        candidates: [
          for (var i = 0; i < candidates.length; i++)
            i == index ? replacement : candidates[i],
        ],
        notices: notices,
        platformCapabilities: platformCapabilities,
        gitBound: gitBound,
        hasRemote: hasRemote,
        githubRepository: githubRepository,
      );

  static String unitName(String package) {
    final cleaned = package.toLowerCase().replaceAll(RegExp('[^a-z0-9_-]'), '');
    return cleaned.isEmpty ? 'main' : cleaned;
  }
}
