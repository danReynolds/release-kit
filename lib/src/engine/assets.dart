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
/// for the checksums file. That is not untidiness, it is a latent and
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
  /// The checksums file, which every binary release carries exactly one of.
  static const checksums = 'SHA256SUMS';

  /// Public binding from release bytes back to their source and stage plan.
  static const manifest = 'release-manifest.json';

  static String archiveName(
    String executable,
    String version,
    String platform,
  ) =>
      '$executable-$version-$platform.tar.gz';

  /// Apple's verdict, verbatim — and its log, which says what the verdict
  /// covered. Published so a user who trusts neither can ask Apple with the
  /// submission id inside them.
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

  /// The formula ships with the release too, so the release is
  /// self-describing: the tap's copy is a pointer, this one is the record.
  static String formulaName(String executable) => '$executable.rb';

  /// Every name a release of [project] carries.
  ///
  /// The single derivation. Anything that produces, expects, or counts these
  /// reads it rather than re-spelling it.
  static Set<String> expectedFor(ResolvedProject project) {
    final executable = project.executable;
    if (executable == null || project.binaryPlatforms.isEmpty) return const {};
    final version = project.version.canonical;

    return {
      for (final platform in project.binaryPlatforms) ...{
        archiveName(executable, version, platform),
        // Apple only vouches for macOS, so only macOS carries its evidence.
        if (platform.startsWith('macos-')) ...{
          notaryResultName(executable, version, platform),
          notaryLogName(executable, version, platform),
        },
      },
      if (project.channels.contains('homebrew')) formulaName(executable),
      checksums,
      manifest,
    };
  }
}
