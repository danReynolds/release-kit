import '../engine/config.dart';
import '../engine/diagnostic.dart';
import '../engine/release_choice.dart';
import '../output/output.dart';
import '../version.dart';

/// The installed binary's static release-choice reference.
///
/// This command never reads the current directory. `status` owns configured
/// repository truth; `target` answers what this exact rk binary understands.
final class TargetCommand {
  const TargetCommand({required this.output});

  static const usage = '''
Usage
  rk target list                  list every release choice this rk supports
  rk target <name>                explain one choice and its configuration
''';

  final Output output;

  int run(String? name) {
    if (name == 'list') return _list();
    final choice = name == null ? null : ReleaseChoice.named(name);
    if (choice == null) {
      output.problem(
        Diagnostic(
          code: 'RK-CLI-009',
          message: name == null
              ? 'rk target needs "list" or a release choice name'
              : 'rk does not support a release choice named "$name"',
          remedy: name == null
              ? usage.trim()
              : 'Supported: ${ReleaseChoice.values.map((item) => item.id).join(', ')}\n'
                  'Run rk target list to see what each one does.',
        ),
      );
      return ExitCodes.usage;
    }
    return _detail(_references[choice]!);
  }

  int _list() {
    output.report.releaseChoices(_references.values.map((item) => item.json));
    output.heading('Release choices supported by rk $rkVersion');
    output.blank();
    output.say('This lists everything the installed rk can create or publish.');
    output.say('It does not read the current folder.');
    output.say('Run `rk status` to see what is set up here.');
    _choiceGroup('Local output', ReleaseChoiceCategory.localOutput);
    _choiceGroup('Release targets', ReleaseChoiceCategory.releaseTarget);
    output.blank();
    output.say('Details and configuration: rk target <name>');
    return ExitCodes.ok;
  }

  void _choiceGroup(String heading, ReleaseChoiceCategory category) {
    output.blank();
    output.heading(heading);
    for (final choice in ReleaseChoice.values.where(
      (choice) => choice.category == category,
    )) {
      output.line(
        choice.id,
        note: choice.summary,
        depth: 1,
        labelWidth: 20,
        role: category == ReleaseChoiceCategory.localOutput
            ? VisualRole.localWork
            : VisualRole.releaseTarget,
        noteRole: VisualRole.secondary,
      );
    }
  }

  int _detail(_Reference reference) {
    final choice = reference.choice;
    output.report.releaseChoices([reference.json]);
    output.heading('${choice.id} — ${reference.title}');
    output.blank();
    output.say(reference.description);
    _section('Select', reference.select);

    if (choice.requires.isNotEmpty) {
      output.blank();
      output.heading('Also needs');
      for (final required in choice.requires) {
        output.line(
          required.id,
          note: reference.requirementReasons[required] ?? required.summary,
          depth: 1,
          labelWidth: 20,
          role: VisualRole.requirement,
          noteRole: VisualRole.secondary,
        );
      }
      output.blank();
      output.say('`rk init` selects these together for you.');
    }

    _section(
      'Configure',
      reference.configure.isEmpty
          ? const ['No RK-specific settings.']
          : reference.configure,
    );
    if (reference.usesBinaryPlatforms) {
      _section(
          'Supported binary platforms', ReleaseConfig.supportedPlatformsList);
    }
    _section('Read automatically', reference.nativeConfiguration);
    _section('Example', reference.example.split('\n'));
    return ExitCodes.ok;
  }

  void _section(String heading, Iterable<String> lines) {
    output.blank();
    output.heading(heading);
    for (final line in lines) {
      if (line.isEmpty) {
        output.blank();
      } else {
        output.say(line, depth: 1);
      }
    }
  }
}

final class _Reference {
  const _Reference({
    required this.choice,
    required this.title,
    required this.description,
    required this.select,
    this.requirementReasons = const {},
    this.configure = const [],
    this.usesBinaryPlatforms = false,
    required this.nativeConfiguration,
    required this.example,
  });

  final ReleaseChoice choice;
  final String title;
  final String description;
  final List<String> select;
  final Map<ReleaseChoice, String> requirementReasons;
  final List<String> configure;
  final bool usesBinaryPlatforms;
  final List<String> nativeConfiguration;
  final String example;

  Map<String, Object?> get json => {
        'id': choice.id,
        'label': choice.selectorLabel,
        'category': choice.category.name,
        'summary': choice.summary,
        'description': description,
        'requires': choice.requires.map((item) => item.id).toList(),
        'select': select,
        'configure': configure,
        if (usesBinaryPlatforms)
          'supported_binary_platforms': ReleaseConfig.supportedPlatformsList,
        'native_configuration': nativeConfiguration,
        'example': example,
      };
}

final Map<ReleaseChoice, _Reference> _references = {
  ReleaseChoice.binary: const _Reference(
    choice: ReleaseChoice.binary,
    title: 'build standalone executable archives',
    description: 'Builds standalone executable archives locally. It publishes '
        'them nowhere unless another selected target consumes them.',
    select: [
      'Set binary_platforms on the project. `binary` does not go in publish.',
    ],
    configure: [
      'binary_platforms = ["macos-arm64", "linux-x64"]',
      'Required on the project. Choose one or more supported platforms.',
      '`rk init` defaults to every platform this host can produce. Pure-Dart '
          'Linux binaries can be cross-compiled from macOS; Docker or Podman '
          'is optional proof, not a build requirement.',
    ],
    usesBinaryPlatforms: true,
    nativeConfiguration: ['Executable and version    pubspec.yaml'],
    example: '''[release.tool]
binary_platforms = ["macos-arm64", "linux-x64"]''',
  ),
  ReleaseChoice.gitTag: const _Reference(
    choice: ReleaseChoice.gitTag,
    title: 'record a release in Git',
    description:
        'Creates and pushes a Git tag that identifies the released version.',
    select: ['Add "git-tag" to the release unit\'s publish list.'],
    configure: [
      'tag = "tool-v{version}"',
      'Optional on the release unit. Omit it for v{version} when that name is '
          'unambiguous.',
    ],
    nativeConfiguration: [
      'Version                   pubspec.yaml',
      'Repository                Git origin',
    ],
    example: '''[release.tool]
publish = ["git-tag"]''',
  ),
  ReleaseChoice.pubDev: const _Reference(
    choice: ReleaseChoice.pubDev,
    title: 'publish a Dart package',
    description: 'Publishes one Dart package to pub.dev.',
    select: ['Add "pub.dev" to the project\'s publish list.'],
    nativeConfiguration: [
      'Name, version, publish_to pubspec.yaml',
      'Authentication            Dart tools',
    ],
    example: '''[release.core]
path = "packages/core"
publish = ["pub.dev"]''',
  ),
  ReleaseChoice.githubRelease: const _Reference(
    choice: ReleaseChoice.githubRelease,
    title: 'publish a GitHub Release',
    description: 'Creates a GitHub Release containing the changelog and '
        'release manifest, plus any selected binary archives.',
    select: ['Add "github-release" to the release unit\'s publish list.'],
    requirementReasons: {
      ReleaseChoice.gitTag: 'Gives the GitHub Release its versioned identity.',
    },
    nativeConfiguration: [
      'Version and changelog     pubspec.yaml and CHANGELOG.md',
      'Repository                Git origin',
      'Authentication            GitHub CLI',
    ],
    example: '''[release.tool]
publish = ["git-tag", "github-release"]''',
  ),
  ReleaseChoice.homebrew: const _Reference(
    choice: ReleaseChoice.homebrew,
    title: 'publish through a Homebrew tap',
    description: 'Publishes stable releases through a formula that installs '
        'one standalone executable from its GitHub Release. Prereleases keep '
        'the tap on its last stable version.',
    select: ['Add "homebrew" to the project\'s publish list.'],
    requirementReasons: {
      ReleaseChoice.binary: 'Builds the archives installed by Homebrew.',
      ReleaseChoice.gitTag: 'Gives the release a versioned source identity.',
      ReleaseChoice.githubRelease: 'Hosts the archives used by the formula.',
    },
    configure: [
      'homebrew_tap = "owner/repository"',
      'Optional on the release unit.',
      'Default: <GitHub owner>/homebrew-tap',
      '',
      'binary_platforms = ["macos-arm64", "linux-x64"]',
      'Required on the Homebrew project.',
      'A Linux-only list publishes a valid Linux-only Formula; macOS is not '
          'required to publish the target.',
    ],
    usesBinaryPlatforms: true,
    nativeConfiguration: [
      'Executable and version    pubspec.yaml',
      'Repository and tap owner  Git origin',
      'Authentication            GitHub CLI',
    ],
    example: '''[release.tool]
publish = ["git-tag", "github-release", "homebrew"]
binary_platforms = ["macos-arm64", "linux-x64"]
homebrew_tap = "owner/homebrew-tools"''',
  ),
};
