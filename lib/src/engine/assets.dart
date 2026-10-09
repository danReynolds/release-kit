import '../builds/binary_artifact.dart';
import 'resolve.dart';

/// The names a release publishes, written once.
///
/// These are a public contract, not an implementation detail: they are the
/// filenames users download, the strings a Homebrew formula points at, and —
/// per the RFC — names frozen for compatibility with releases keybay made
/// before rk existed.
///
/// They were spelled in four places: the chain that produces them, the
/// inspector that expects them, the release that counts them, and literals
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
/// A leaf over `resolve.dart` alone, so the release model, the chain and the
/// inspector can all import it.
abstract final class ReleaseAssets {
  /// Public binding from release bytes back to their source and stage plan.
  static const manifest = 'release-manifest.json';

  static String producerRoot(ResolvedProject project) =>
      'producers/${project.name}';

  static String binaryPath(ResolvedProject project, String platform) =>
      '${producerRoot(project)}/$platform/${project.executable}';

  static BinaryArtifact binaryArtifact(
    ResolvedProject project,
    String platform,
  ) => BinaryArtifact.forPlatform(project.executable!, platform);

  static String binaryRoot(ResolvedProject project, String platform) =>
      '${producerRoot(project)}/$platform';

  static Map<String, String> binaryOutputs(
    ResolvedProject project,
    String platform,
  ) => {
    for (final file in binaryArtifact(project, platform).files)
      '${binaryRoot(project, platform)}/${file.path}': file.type,
  };

  static String archivePath(ResolvedProject project, String platform) =>
      '${producerRoot(project)}/archives/'
      '${archiveName(project.executable!, project.version.canonical, platform)}';

  static String formulaPath(ResolvedProject project) =>
      '${producerRoot(project)}/homebrew/${formulaName(project.executable!)}';

  /// The public name of a file a project's own build writes: its file name.
  static String assetName(String declared) => declared.split('/').last;

  /// Where a declared asset is staged, under its public name.
  static String assetPath(ResolvedProject project, String declared) =>
      '${producerRoot(project)}/assets/${assetName(declared)}';

  /// Every staged path a project's own build leaves, with its artifact type.
  static Map<String, String> assetOutputs(ResolvedProject project) => {
    for (final declared in project.assets)
      assetPath(project, declared): 'asset',
  };

  /// Private native package bytes uploaded to pub.dev.
  ///
  /// This is a stage artifact, not a GitHub Release asset. Keeping it under
  /// the same producer root gives publishers one content-addressed artifact
  /// boundary without implying that their public payloads match.
  static String pubArchivePath(ResolvedProject project) =>
      '${producerRoot(project)}/pub/'
      '${project.name}-${project.version.canonical}.tar.gz';

  /// The public name of one platform's archive, frozen for releases made
  /// before rk existed.
  static String archiveName(
    String executable,
    String version,
    String platform,
  ) => '$executable-$version-$platform.tar.gz';

  /// The formula's public filename inside its Homebrew tap.
  ///
  /// Formula bytes belong to the tap and do not enter the GitHub Release
  /// inventory. Their digest and tap path are bound by the release manifest.
  static String formulaToken(String executable) {
    final token = executable
        .toLowerCase()
        .replaceAll('_', '-')
        .replaceAll(RegExp('-+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (!RegExp(r'^[a-z](?:[a-z0-9-]*[a-z0-9])?$').hasMatch(token)) {
      throw ArgumentError(
        'executable does not produce a safe Homebrew formula token: '
        '$executable',
      );
    }
    return token;
  }

  static String formulaName(String executable) =>
      '${formulaToken(executable)}.rb';

  /// Homebrew's token-to-Ruby-constant mapping for the token subset rk emits.
  static String formulaClass(String executable) {
    final token = formulaToken(executable);
    return token
        .split('-')
        .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
        .join();
  }

  /// The complete public inventory excluding the manifest itself, by public
  /// name. Configuration already refuses two assets with one name, and the
  /// manifest's (RK-CONF-043).
  static List<ReleaseAsset> bundleFor(ResolvedUnit unit) {
    final project = unit.binaryProject;
    final List<ReleaseAsset> assets;
    if (unit.assetProject case final built?) {
      assets = [
        for (final declared in built.assets)
          (
            publicName: assetName(declared),
            stagedPath: assetPath(built, declared),
          ),
      ];
    } else if (project != null) {
      assets = [
        for (final platform in project.binaryPlatforms)
          (
            publicName: archiveName(
              project.executable!,
              project.version.canonical,
              platform,
            ),
            stagedPath: archivePath(project, platform),
          ),
      ];
    } else {
      return const [];
    }
    return List.unmodifiable(
      assets..sort((a, b) => a.publicName.compareTo(b.publicName)),
    );
  }

  static Set<String> expectedForUnit(ResolvedUnit unit) => {
    for (final asset in bundleFor(unit)) asset.publicName,
    manifest,
  };
}

/// One file a release publishes: its public name, and where it is staged.
typedef ReleaseAsset = ({String publicName, String stagedPath});
