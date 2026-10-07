import 'dart:io';

import 'package:rk/src/engine/tools.dart';
import 'package:yaml/yaml.dart' as yaml;

/// What Pub reports when the pub.dev stage resolves its package the way its
/// consumers do. Each report can be set on its own, so a test can prove the
/// stage reads it.
final class PubResolution {
  const PubResolution({
    this.consumerFailure,
    this.consumerAlsoReports = const {},
  });

  /// Why `pub get` fails; null when it succeeds.
  final String? consumerFailure;

  /// Overrides `pub get` reports besides the ones the stage wrote.
  final Set<String> consumerAlsoReports;
}

/// `dart pub get --no-example` in [workingDirectory], where the stage wrote
/// its `pubspec_overrides.yaml`: Pub applies that file's overrides and no
/// others, and reports each one it applied with a `!` line. Pub prints
/// those only in a full report, which the environment variable
/// `PUB_SUMMARY_ONLY` turns off; the double assumes the caller's
/// environment sets it, as Flutter's tooling does, unless the call itself
/// sets it to `0`.
ToolResult pubGetIn(
  String workingDirectory, {
  PubResolution resolution = const PubResolution(),
  Map<String, String>? environment,
}) {
  if (resolution.consumerFailure case final failure?) {
    return ToolResult(
      exitCode: 1,
      stdout: 'Resolving dependencies...\n',
      stderr: '$failure\n',
    );
  }
  final fullReport = environment?['PUB_SUMMARY_ONLY'] == '0';
  final reported = {
    ...?_writtenOverrides(workingDirectory),
    ...resolution.consumerAlsoReports,
  };
  return ToolResult(
    exitCode: 0,
    stdout: [
      'Resolving dependencies...',
      if (fullReport)
        for (final name in reported)
          '! $name 9.9.9 from path ../$name (overridden)',
      fullReport ? 'Got dependencies!' : 'Got dependencies.',
      '',
    ].join('\n'),
    stderr: '',
  );
}

/// The packages the `pubspec_overrides.yaml` the stage wrote at [directory]
/// overrides; null when it wrote none there.
Set<String>? _writtenOverrides(String directory) {
  final file = File('$directory/pubspec_overrides.yaml');
  if (!file.existsSync()) return null;
  final source = file.readAsStringSync();
  if (!source.startsWith('# Written by rk')) return null;
  final overrides = (yaml.loadYaml(source) as Map)['dependency_overrides'];
  return {for (final name in (overrides as Map).keys) name as String};
}
