import 'config.dart';
import 'dart_workspace.dart';
import 'pubspec.dart';
import 'source_tree.dart';

enum InitOption { use, binary, gitTag, pubDev, githubRelease, homebrew }

extension InitOptionLabel on InitOption {
  String get label => switch (this) {
        InitOption.use => 'Use',
        InitOption.binary => 'Binary',
        InitOption.gitTag => 'Git tag',
        InitOption.pubDev => 'pub.dev',
        InitOption.githubRelease => 'GitHub',
        InitOption.homebrew => 'Homebrew',
      };

  String get wireName => switch (this) {
        InitOption.use => 'use',
        InitOption.binary => 'binary',
        InitOption.gitTag => 'git-tag',
        InitOption.pubDev => 'pub.dev',
        InitOption.githubRelease => 'github-release',
        InitOption.homebrew => 'homebrew',
      };
}

final class InitAvailability {
  const InitAvailability.available(this.reason) : available = true;
  const InitAvailability.unavailable(this.reason) : available = false;

  final bool available;
  final String reason;

  Map<String, Object?> toJson() => {
        'available': available,
        'reason': reason,
      };
}

final class InitCandidate {
  InitCandidate({
    required this.name,
    required this.path,
    required this.version,
    required this.executables,
    required this.availability,
    required this.selected,
    required this.use,
  });

  final String name;
  final String path;
  final String? version;
  final List<String> executables;
  final Map<InitOption, InitAvailability> availability;
  final Set<InitOption> selected;
  final bool use;

  String get unit => InitPlan.unitName(name);

  InitCandidate copyWith({Set<InitOption>? selected, bool? use}) =>
      InitCandidate(
        name: name,
        path: path,
        version: version,
        executables: executables,
        availability: availability,
        selected: selected ?? this.selected,
        use: use ?? this.use,
      );

  Map<String, Object?> toJson() => {
        'unit': unit,
        'project': name,
        'path': path,
        'version': version,
        'executables': executables,
        'use': use,
        'options': {
          for (final option in InitOption.values.where(
            (option) => option != InitOption.use,
          ))
            option.wireName: {
              ...availability[option]!.toJson(),
              'selected': selected.contains(option),
              'effects': InitPlan.effectsFor(option)
                  .map((effect) => effect.wireName)
                  .toList(),
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
    required this.gitBound,
    required this.hasRemote,
    required this.githubRepository,
  })  : candidates = List.unmodifiable(candidates),
        notices = List.unmodifiable(notices);

  factory InitPlan.discover({
    required SourceTree tree,
    required bool gitBound,
    required bool hasRemote,
    required String? githubRepository,
    String? ambientPubHostedUrl,
  }) {
    final native = DartWorkspaceDiscovery(
      tree,
      trackedManifests: gitBound,
    );
    final notices = [...native.notices];
    bool registryAvailableFor(DartProjectDiscovery project) =>
        !project.isGroupingRoot &&
        project.version != null &&
        !project.vetoesRegistry &&
        !project.isExampleOrFixture &&
        (project.publishTo == null ||
            isPubDevDestination(project.publishTo!)) &&
        (project.publishTo != null ||
            ambientPubHostedUrl == null ||
            isPubDevDestination(ambientPubHostedUrl));
    final releasable = native.projects.where(registryAvailableFor).length;
    final candidates = <InitCandidate>[];
    var vetoed = 0;
    for (final project in native.projects) {
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
      final binaryAvailable = packageUsable && oneExecutable && githubAvailable;
      final selected = <InitOption>{
        if (registryAvailable) InitOption.pubDev,
        if (registryAvailable && tagAvailable && releasable == 1)
          InitOption.gitTag,
      };
      final availability = <InitOption, InitAvailability>{
        InitOption.use: packageUsable
            ? const InitAvailability.available('include this release unit')
            : InitAvailability.unavailable(project.isGroupingRoot
                ? 'workspace root — select its packages instead'
                : 'the native manifest declares no version'),
        InitOption.pubDev: registryAvailable
            ? const InitAvailability.available(
                'native Dart package coordinate',
              )
            : project.isExampleOrFixture &&
                    packageUsable &&
                    !project.vetoesRegistry &&
                    repositoryPubDev &&
                    ambientPubDev
                ? const InitAvailability.available(
                    'native coordinate; example and fixture paths start unselected',
                  )
                : InitAvailability.unavailable(project.vetoesRegistry
                    ? 'publish_to: none vetoes registry publication'
                    : !repositoryPubDev
                        ? 'publish_to names a custom registry; this build has no matching target'
                        : !ambientPubDev
                            ? 'PUB_HOSTED_URL redirects the default registry; declare publish_to in the pubspec first'
                            : 'a package version is required'),
        InitOption.gitTag: tagAvailable
            ? InitAvailability.available(selected.contains(InitOption.gitTag)
                ? 'usable Git remote; selected conservatively'
                : 'available; selecting writes an explicit package tag')
            : InitAvailability.unavailable(!gitBound
                ? 'Git is not available for this source'
                : !hasRemote
                    ? 'add a Git remote first'
                    : 'a package version is required'),
        InitOption.githubRelease: githubAvailable
            ? const InitAvailability.available(
                'changelog and manifest, plus selected binaries',
              )
            : InitAvailability.unavailable(!gitBound
                ? 'GitHub Release requires Git'
                : githubRepository == null
                    ? 'origin is not a recognized GitHub repository'
                    : 'a package version is required'),
        InitOption.binary: binaryAvailable
            ? InitAvailability.available(
                'standalone ${project.executables.single} archives',
              )
            : InitAvailability.unavailable(!oneExecutable
                ? project.executables.isEmpty
                    ? 'no executable is declared'
                    : 'several executables need a hand-authored decision'
                : !githubAvailable
                    ? 'standalone binaries require GitHub Release'
                    : 'a package version is required'),
        InitOption.homebrew: binaryAvailable
            ? const InitAvailability.available(
                'formula in the conventional or configured tap',
              )
            : const InitAvailability.unavailable(
                'Homebrew requires one standalone executable and GitHub',
              ),
      };
      candidates.add(InitCandidate(
        name: project.name,
        path: project.path,
        version: project.version,
        executables: project.executables,
        availability: Map.unmodifiable(availability),
        selected: Set.unmodifiable(selected),
        use: selected.isNotEmpty,
      ));
    }
    if (vetoed > 0) notices.add('$vetoed excluded by publish_to: none');
    return InitPlan(
      candidates: candidates,
      notices: notices,
      gitBound: gitBound,
      hasRemote: hasRemote,
      githubRepository: githubRepository,
    );
  }

  final List<InitCandidate> candidates;
  final List<String> notices;
  final bool gitBound;
  final bool hasRemote;
  final String? githubRepository;

  List<InitCandidate> get included => candidates
      .where((candidate) => candidate.use && _targets(candidate).isNotEmpty)
      .toList();

  InitToggleResult toggle(int index, InitOption option) {
    final candidate = candidates[index];
    if (option == InitOption.use) {
      var selected = candidate.selected;
      final enable = !candidate.use;
      if (enable && selected.isEmpty) {
        final fallback = [
          InitOption.pubDev,
          InitOption.gitTag,
          InitOption.githubRelease,
        ].firstWhere(
          (item) => candidate.availability[item]!.available,
          orElse: () => InitOption.use,
        );
        if (fallback == InitOption.use) {
          return InitToggleResult(
            this,
            candidate.availability[InitOption.use]!.reason,
          );
        }
        selected = {fallback};
      }
      return InitToggleResult(
        _replace(index, candidate.copyWith(use: enable, selected: selected)),
        enable ? '${candidate.unit} included' : '${candidate.unit} excluded',
      );
    }

    final availability = candidate.availability[option]!;
    if (!availability.available) {
      return InitToggleResult(this, availability.reason);
    }
    final selected = {...candidate.selected};
    final changed = <InitOption>[];
    if (!selected.contains(option)) {
      for (final required in {...effectsFor(option), option}) {
        if (!candidate.availability[required]!.available) {
          return InitToggleResult(
            this,
            candidate.availability[required]!.reason,
          );
        }
        if (selected.add(required)) changed.add(required);
      }
    } else {
      final remove = <InitOption>{option};
      var grew = true;
      while (grew) {
        grew = false;
        for (final active in selected) {
          if (effectsFor(active).any(remove.contains) && remove.add(active)) {
            grew = true;
          }
        }
      }
      for (final item in remove) {
        if (selected.remove(item)) changed.add(item);
      }
    }
    final use = selected.any(_isTarget);
    final plan = _replace(
      index,
      candidate.copyWith(selected: Set.unmodifiable(selected), use: use),
    );
    final names = changed.map((item) => item.label).join(', ');
    return InitToggleResult(
      plan,
      selected.contains(option)
          ? '$names enabled'
          : '$names disabled${use ? '' : '; unit excluded'}',
    );
  }

  String renderToml() {
    final buffer = StringBuffer('schema = 2\n');
    final tagged = included
        .where((candidate) => candidate.selected.contains(InitOption.gitTag))
        .toList();
    for (final candidate in included) {
      buffer.write('\n[release.${candidate.unit}]\n');
      if (candidate.path != '.') {
        buffer.write('path = "${candidate.path}"\n');
      }
      if (candidate.selected.contains(InitOption.gitTag) && tagged.length > 1) {
        buffer.write('tag = "${candidate.name}-v{version}"\n');
      }
      final publish = <String>[
        if (candidate.selected.contains(InitOption.gitTag)) 'git-tag',
        if (candidate.selected.contains(InitOption.pubDev)) 'pub.dev',
        if (candidate.selected.contains(InitOption.githubRelease))
          'github-release',
        if (candidate.selected.contains(InitOption.homebrew)) 'homebrew',
      ];
      buffer.write(
          'publish = [${publish.map((item) => '"$item"').join(', ')}]\n');
      if (candidate.selected.contains(InitOption.binary)) {
        buffer.write('binary_platforms = '
            '[${ReleaseConfig.supportedPlatformsList.map((item) => '"$item"').join(', ')}]\n');
      }
    }
    if (candidates.any((candidate) => candidate.executables.isNotEmpty) &&
        !included.any(
          (candidate) => candidate.selected.contains(InitOption.binary),
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
        'notices': notices,
      };

  InitPlan _replace(int index, InitCandidate replacement) => InitPlan(
        candidates: [
          for (var i = 0; i < candidates.length; i++)
            i == index ? replacement : candidates[i],
        ],
        notices: notices,
        gitBound: gitBound,
        hasRemote: hasRemote,
        githubRepository: githubRepository,
      );

  static Set<InitOption> effectsFor(InitOption option) => switch (option) {
        InitOption.binary => const {
            InitOption.githubRelease,
            InitOption.gitTag,
          },
        InitOption.githubRelease => const {InitOption.gitTag},
        InitOption.homebrew => const {
            InitOption.binary,
            InitOption.githubRelease,
            InitOption.gitTag,
          },
        _ => const {},
      };

  static String unitName(String package) {
    final cleaned = package.toLowerCase().replaceAll(RegExp('[^a-z0-9_-]'), '');
    return cleaned.isEmpty ? 'main' : cleaned;
  }
}

Set<InitOption> _targets(InitCandidate candidate) =>
    candidate.selected.where(_isTarget).toSet();

bool _isTarget(InitOption option) => switch (option) {
      InitOption.gitTag ||
      InitOption.pubDev ||
      InitOption.githubRelease ||
      InitOption.homebrew =>
        true,
      _ => false,
    };
