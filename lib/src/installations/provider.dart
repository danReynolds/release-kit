import '../engine/tools.dart';
import 'model.dart';

/// Installation capability lives beside a provider, not in UI/release lifecycle.
abstract interface class InstallationProvider {
  InstallationSource get source;

  /// What this source has installed for [project], read from its native state.
  Future<SourceInspection> inspect(ExecutableProject project);

  /// The newest version offered to [project]. Local throws: it follows the
  /// checkout.
  Future<AvailableInstallation> latest(
    ExecutableProject project, {
    InstallationCancellation? check,
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

/// Cancels an operation before its next step, and a check's network requests
/// at once, so closing the picker never waits for a timeout.
class InstallationCancellation {
  final _onCancel = <void Function()>{};
  bool cancelled = false;

  void cancel() {
    cancelled = true;
    for (final close in _onCancel.toList()) {
      close();
    }
    _onCancel.clear();
  }

  void check() {
    if (cancelled) {
      throw const InstallationFailure(
        'Selection cancelled.',
        'Any completed installation was kept; the previous selection was not changed.',
      );
    }
  }

  /// Calls [close] on cancellation, at once if cancelled already, and
  /// returns what unregisters it.
  void Function() onCancel(void Function() close) {
    if (cancelled) {
      close();
    } else {
      _onCancel.add(close);
    }
    return () => _onCancel.remove(close);
  }
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
