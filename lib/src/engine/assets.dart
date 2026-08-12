import 'release_asset.dart';
import 'resolve.dart';

/// The names a release publishes, written once.
///
/// These are a public contract, not an implementation detail: they are the
/// filenames users download, the strings a Homebrew formula points at, and —
/// per the RFC — names frozen for compatibility with releases keybay made
/// before rk existed.
///
/// They were spelled in four places: the chain that produces them, the
/// inspector that expects them, the checklist that counts them, and literals
/// for generated bundle files. That is not untidiness, it is a latent and
/// permanently unfixable failure. `GithubRelease.inspect` returns
/// `Verdict.conflict` for *any* difference between expected and published —
/// missing or extra — and a published release cannot be edited, so the
/// verdict is terminal. Meanwhile the publish step's own read-back compares
/// only against what it just uploaded, never against the expected set. One
/// name out of step between producer and inspector therefore lets rk publish
/// a release and then read it back, on the next run, as an unfixable conflict
/// against a release it made itself.
///
/// A leaf over `resolve.dart` alone, so the chain, the inspector and the
/// checklist can all import it. The comment that used to sit on the
/// checklist's copy claimed the two "cannot share code (checklist and
/// inspector would import each other)" — that cycle does not exist:
/// `checklist.dart` imports `diagnostic`, `resolve` and `version`, and
/// `inspect.dart` imports `checklist.dart` one way.
abstract final class ReleaseAssets {
  /// Public binding from release bytes back to their source and stage plan.
  static const manifest = 'release-manifest.json';

  static String producerRoot(ResolvedProject project) =>
      'producers/${project.name}';

  static String binaryPath(
    ResolvedProject project,
    String platform,
  ) =>
      '${producerRoot(project)}/$platform/${project.executable}';

  static String notaryInputPath(
    ResolvedProject project,
    String platform,
  ) =>
      '${producerRoot(project)}/$platform/${project.executable}.zip';

  static String archivePath(
    ResolvedProject project,
    String platform,
  ) =>
      '${producerRoot(project)}/archives/'
      '${archiveName(project.executable!, project.version.canonical, platform)}';

  static String notaryResultPath(
    ResolvedProject project,
    String platform,
  ) =>
      '${producerRoot(project)}/evidence/'
      '${notaryResultName(project.executable!, project.version.canonical, platform)}';

  static String notaryLogPath(
    ResolvedProject project,
    String platform,
  ) =>
      '${producerRoot(project)}/evidence/'
      '${notaryLogName(project.executable!, project.version.canonical, platform)}';

  static String formulaPath(ResolvedProject project) =>
      '${producerRoot(project)}/homebrew/${formulaName(project.executable!)}';

  static String archiveName(
    String executable,
    String version,
    String platform,
  ) =>
      standaloneArchiveName(executable, version, platform);

  /// Apple's verdict, verbatim — and its log, which says what the verdict
  /// covered. Stage evidence, not published assets: a consumer verifies the
  /// binary itself (`codesign --test-requirement=notarized` asks Apple about
  /// the exact bytes), which no JSON beside it can strengthen. The receipt
  /// records both files for diagnosis.
  static String notaryResultName(
    String executable,
    String version,
    String platform,
  ) =>
      '$executable-$version-$platform.notary-result.json';

  static String notaryLogName(
    String executable,
    String version,
    String platform,
  ) =>
      '$executable-$version-$platform.notary-log.json';

  /// The formula's public filename inside its Homebrew tap.
  ///
  /// Formula bytes belong to the tap and do not enter the GitHub Release
  /// inventory. Their digest and tap path are bound by the release manifest.
  static String formulaName(String executable) => '$executable.rb';

  static List<ReleaseAssetSpec> contributedBy(ResolvedProject project) => [
        for (final platform in [...project.binaryPlatforms]..sort())
          ReleaseAssetSpec(
            stagedPath: archivePath(project, platform),
            publicName: archiveName(
              project.executable!,
              project.version.canonical,
              platform,
            ),
          ),
      ];

  /// Every producer contribution, validated before producer work starts.
  static List<ReleaseAssetSpec> contributionsFor(ResolvedUnit unit) =>
      validateReleaseAssetSpecs([
        for (final project in unit.projects) ...contributedBy(project),
      ]);

  /// The complete public inventory excluding the manifest itself.
  static List<ReleaseAssetSpec> bundleFor(ResolvedUnit unit) =>
      contributionsFor(unit);

  static Set<String> expectedForUnit(ResolvedUnit unit) => {
        for (final asset in bundleFor(unit)) asset.publicName,
        manifest,
      };
}
