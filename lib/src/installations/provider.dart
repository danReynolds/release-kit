import '../engine/tools.dart';
import 'model.dart';
import 'metadata.dart';

/// Installation capability lives beside a provider, not in UI/release lifecycle.
abstract class InstallationProvider {
  InstallationSource get source;
  Future<SourceInspection> inspect(ExecutableProject project);
  Future<Installation> install(
    ExecutableProject project,
    void Function(String) progress,
  );
  Future<void> uninstall(ExecutableProject project, Installation installation);
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

/// Optional capability owned by remote sources. The checked release is carried
/// to installation, so a click never silently installs a newly resolved version.
abstract interface class InstallationUpdates {
  Future<AvailableInstallation> latest(
    ExecutableProject project, {
    InstallationCheck? check,
  });
  Future<Installation> download(
    ExecutableProject project,
    AvailableInstallation release,
    void Function(String) progress,
  );
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
