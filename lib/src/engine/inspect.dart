import '../destinations/github_release.dart';
import 'checklist.dart';
import 'git.dart';
import 'registry.dart';
import 'resolve.dart';
import 'tools.dart';
import 'verdict.dart';

/// Reads reality for one step, and nothing else.
///
/// One inspector rather than one per command. `status` is `release` without the
/// acting, so a second implementation would be a second set of answers to the
/// same question, and the two would drift — which they had: status inspected
/// channels project by project and never learned that a checklist has build,
/// sign and archive steps in it, while release answered `absent` by default for
/// every kind it did not name, asserting "definitely not there" about
/// destinations it had never asked.
///
/// It takes a step and returns a verdict. It holds no state between calls, acts
/// on nothing, and is the seam CI needs: an executable step is decided from the
/// checklist, its id, and destination reality (CI readiness, seam 1).
class Inspector {
  Inspector({
    required this.registry,
    required this.git,
    required this.resolution,
    this.tools,
    this.repository,
  });

  final RegistryReader registry;
  final GitState git;
  final Resolution resolution;

  /// Needed to read the forge. Absent means the forge cannot be read, which is
  /// `unknown` — never `absent`.
  final Tools? tools;

  /// `owner/name`, when the repository has an origin to ask about.
  final String? repository;

  /// Whether this step's state lives somewhere rk can read without acting.
  ///
  /// The rest — building, signing, notarizing, archiving — are local work
  /// whose results live in a workspace this run may not have. rk does not claim
  /// they are absent, because it has not looked, and a definite negative is
  /// what lets a release proceed.
  static bool isPublic(StepKind kind) => switch (kind) {
        StepKind.tag ||
        StepKind.prerequisite ||
        StepKind.publishRegistry ||
        StepKind.publishRelease ||
        StepKind.publishFormula =>
          true,
        _ => false,
      };

  Future<Inspection> inspect(Step step, ResolvedUnit unit) async {
    switch (step.kind) {
      case StepKind.tag:
        return git.hasTag(unit.tag)
            ? const Inspection.exact(detail: 'already tagged')
            : const Inspection.absent();

      case StepKind.prerequisite:
        return _prerequisite(step);

      case StepKind.publishRegistry:
        final project = unit.projects.firstWhere((p) => p.name == step.project);
        return registry.inspect(project.name, project.version);

      case StepKind.publishRelease:
        return _release(unit);

      case StepKind.publishFormula:
        // The tap is a repository rk has not been given a way to read here.
        // Saying so is the honest answer; saying `absent` would report a
        // formula that may already point at this release as work still to do.
        return const Inspection.unknown('the tap has not been read');

      case StepKind.build ||
            StepKind.sign ||
            StepKind.notarize ||
            StepKind.archive ||
            StepKind.checksums:
        return const Inspection.unknown('local work, decided when it runs');
    }
  }

  /// A package another unit publishes, which must already be live.
  Future<Inspection> _prerequisite(Step step) async {
    // The coordinate is carried by the step so nothing here has to know how an
    // id is spelled: `pub.dev/<package>/<version>`.
    final parts = step.coordinate!.split('/');
    if (parts.length < 3) {
      return const Inspection.unknown('the prerequisite could not be read');
    }
    final name = parts[parts.length - 2];
    final version = parts.last;

    final RegistryPackage? package;
    try {
      package = await registry.lookup(name);
    } on RegistryUnavailable catch (error) {
      return Inspection.unknown(error.message);
    }
    if (package == null) {
      return Inspection.absent(detail: '$name has never been published');
    }

    final live = package.versions.any((v) => v.version.canonical == version);
    return live
        ? const Inspection.exact(detail: 'live')
        // Absent, not conflict: it is not published *yet*, and publishing it
        // and re-running is exactly the fix. A conflict would halt saying this
        // cannot be fixed by re-running, which is the opposite of true.
        : Inspection.absent(detail: '$name $version is not published yet');
  }

  Future<Inspection> _release(ResolvedUnit unit) async {
    if (tools == null || repository == null) {
      return const Inspection.unknown('the forge has not been read');
    }
    final expected = <String>{};
    for (final project in unit.projects) {
      final executable = project.executable;
      if (executable == null) continue;
      for (final platform in project.binaryPlatforms) {
        expected.add('$executable-${project.version}-$platform.tar.gz');
      }
      if (project.binaryPlatforms.isNotEmpty) expected.add('SHA256SUMS');
    }

    return GithubRelease(
      tools: tools!,
      repository: repository!,
      workingDirectory: git.root,
    ).inspect(unit.tag, expected);
  }
}
