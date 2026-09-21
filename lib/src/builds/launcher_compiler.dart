import 'dart:io';

import '../engine/canonical_json.dart';
import '../transforms/digest.dart';

/// The Xcode command-line toolchain used for the small macOS launcher.
/// Its portable identity joins Dart's identity in the stage key; selected
/// paths are retained only to invoke the exact tools that were identified.
final class LauncherCompiler {
  LauncherCompiler._(this.executable, this.sdk, this.identity);
  final String executable;
  final String sdk;
  final Map<String, Object?> identity;

  factory LauncherCompiler.read() {
    String xcrun(List<String> args) {
      final result = Process.runSync('/usr/bin/xcrun', args);
      if (result.exitCode != 0 || '${result.stdout}'.trim().isEmpty) {
        throw StateError(
            'the macOS launcher needs Xcode command-line tools: ${result.stderr}');
      }
      return '${result.stdout}'.trim();
    }

    final executable =
        File(xcrun(['--find', 'clang'])).resolveSymbolicLinksSync();
    final sdk =
        Directory(xcrun(['--show-sdk-path'])).resolveSymbolicLinksSync();
    final settings = File('$sdk/SDKSettings.json');
    final fingerprint =
        '$executable:${_stat(File(executable))}:$sdk:${_stat(settings)}';
    if (_cachedKey == fingerprint) return _cached!;
    final version = Process.runSync(executable, ['--version']);
    if (version.exitCode != 0) {
      throw StateError('clang --version failed: ${version.stderr}');
    }
    final compiler = LauncherCompiler._(
        executable,
        sdk,
        Map.unmodifiable({
          'clang_sha256': Sha256.hex(File(executable).readAsBytesSync()),
          'clang_version': '${version.stdout}'
              .trim()
              .split('\n')
              .where((line) => !line.startsWith('InstalledDir:'))
              .join('\n'),
          'sdk_sha256': Sha256.hex(settings.readAsBytesSync()),
        }));
    _cachedKey = fingerprint;
    return _cached = compiler;
  }

  bool get isCurrent =>
      CanonicalJson.encode(identity) ==
      CanonicalJson.encode(LauncherCompiler.read().identity);
}

String _stat(File file) {
  final stat = file.statSync();
  return '${stat.changed.microsecondsSinceEpoch}:${stat.modified.microsecondsSinceEpoch}:${stat.size}:${stat.mode}';
}

String? _cachedKey;
LauncherCompiler? _cached;
