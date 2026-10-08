import 'dart:io';

/// The Xcode command-line tools that build the small macOS launcher: clang
/// and the SDK it compiles against, located once per process.
final class LauncherCompiler {
  LauncherCompiler._(this.executable, this.sdk);

  final String executable;
  final String sdk;

  static LauncherCompiler read() => _located ??= _locate();
  static LauncherCompiler? _located;

  static LauncherCompiler _locate() {
    String xcrun(List<String> args) {
      final result = Process.runSync('/usr/bin/xcrun', args);
      if (result.exitCode != 0 || '${result.stdout}'.trim().isEmpty) {
        throw StateError(
          'the macOS launcher needs Xcode command-line tools: ${result.stderr}',
        );
      }
      return '${result.stdout}'.trim();
    }

    return LauncherCompiler._(
      xcrun(['--find', 'clang']),
      xcrun(['--show-sdk-path']),
    );
  }
}
