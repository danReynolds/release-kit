import '../engine/tools.dart';
import 'model.dart';
import 'metadata.dart';

/// Installation capability lives beside a provider, not in UI/release lifecycle.
abstract interface class InstallationProvider {
  InstallationSource get source;

  /// What this source has installed for [project], read from its native state.
  Future<SourceInspection> inspect(ExecutableProject project);

  /// The newest version offered to [project]. Local throws: it follows the
  /// checkout.
  Future<AvailableInstallation> latest(
    ExecutableProject project, {
    InstallationCheck? check,
  });

  /// Installs exactly [release], or what the package manager picks without
  /// one. A checked release is carried to installation, so a click never
  /// installs a version resolved since.
  Future<Installation> install(
    ExecutableProject project,
    AvailableInstallation? release,
    void Function(String) progress,
  );
  Future<void> uninstall(ExecutableProject project);
}

Future<ToolResult> checked(
  Tools tools,
  String executable,
  List<String> arguments, {
  String? directory,
  Map<String, String>? environment,
}) async {
  final result = await tools.run(
    executable,
    arguments,
    workingDirectory: directory,
    environment: environment,
    timeout: const Duration(minutes: 10),
  );
  if (!result.ok) {
    throw InstallationFailure(
      result.summary,
      'Resolve the provider error, then check rk use --list before retrying.',
    );
  }
  return result;
}

/// What [provider] reports once its package manager has finished.
Future<Installation> inspectedAfterInstall(
  InstallationProvider provider,
  ExecutableProject project,
) async {
  final state = await provider.inspect(project);
  return state.installation ??
      (throw InstallationFailure(
        state.problem ??
            '${provider.source.label} did not install ${project.name}.',
      ));
}

/// A version a check found; installing it installs exactly this version.
/// [sha256] pins the bytes: GitHub's archive or Homebrew's formula.
final class AvailableInstallation {
  const AvailableInstallation(this.version, {this.url, this.size, this.sha256});
  final String version;

  /// GitHub's archive, and its size as the release manifest records it.
  final Uri? url;
  final int? size;
  final String? sha256;
}
