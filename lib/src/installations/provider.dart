import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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
    throw InstallationFailure.withEvidence(
      result.summary,
      remedy: 'Fix the reported tool error, then retry the same command.',
      evidence: [
        'Directory: ${directory ?? Directory.current.path}',
        'Command: ${[executable, ...arguments].map(shellQuote).join(' ')}',
        result.transcript,
      ].join('\n'),
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

/// Reads one public resource; a [check] can cancel it. Providers take this as
/// a parameter so tests can serve releases without a network.
typedef HttpsFetch =
    Future<Uint8List> Function(
      Uri uri,
      int maxBytes, {
      InstallationCancellation? check,
    });

/// Reads a public pub.dev or GitHub resource over HTTPS, following its
/// redirects, bounded in size and time. A check gives up after 15 seconds; a
/// download may take three minutes.
Future<Uint8List> fetchHttps(
  Uri uri,
  int maxBytes, {
  InstallationCancellation? check,
}) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20)
    ..userAgent = 'rk-installation';
  void close() => client.close(force: true);
  final unregister = check?.onCancel(close);
  final deadline = Timer(
    check == null ? const Duration(minutes: 3) : const Duration(seconds: 15),
    close,
  );
  try {
    final request = await client
        .getUrl(uri)
        .timeout(const Duration(seconds: 30));
    final response = await request.close().timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw InstallationFailure(
        '${uri.host} returned HTTP ${response.statusCode}.',
        'Installed versions are still available. Retry later, or check the '
            'public release. Private GitHub downloads are not supported yet.',
      );
    }
    final data = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(const Duration(seconds: 30))) {
      if (data.length + chunk.length > maxBytes) {
        throw const InstallationFailure('A download exceeded its size limit.');
      }
      data.add(chunk);
    }
    return data.takeBytes();
  } finally {
    unregister?.call();
    deadline.cancel();
    client.close(force: true);
  }
}
