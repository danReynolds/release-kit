import 'dart:io';

import 'package:rk/src/engine/version.dart';

/// Keeps the two version declarations needed by rk's compiled executable in
/// sync. This is repository tooling, not an rk product command: release-kit
/// deliberately does not own a consumer project's versioning policy.
void main(List<String> arguments) {
  if (arguments.length != 1) {
    stderr.writeln(
      'usage: dart run tool/prepare_release.dart <major.minor.patch>',
    );
    exitCode = 64;
    return;
  }

  try {
    final update = prepareReleaseVersion(
      Directory.current,
      arguments.single,
    );
    stdout.writeln('rk ${update.previous} → ${update.next}');
    stdout.writeln('Updated pubspec.yaml and lib/src/version.dart.');
    stdout.writeln(
      'Next: add the ${update.next} release notes to CHANGELOG.md.',
    );
  } on ArgumentError catch (error) {
    stderr.writeln(error.message);
    exitCode = 64;
  } on StateError catch (error) {
    stderr.writeln(error.message);
    exitCode = 1;
  } on FileSystemException catch (error) {
    stderr.writeln(error.message);
    exitCode = 1;
  }
}

ReleaseVersionUpdate prepareReleaseVersion(
  Directory repository,
  String requested,
) {
  final next = Version.tryParse(requested);
  if (next == null) {
    throw ArgumentError(
      'the release version must be canonical major.minor.patch SemVer',
    );
  }

  final pubspec = File('${repository.path}/pubspec.yaml');
  final embedded = File('${repository.path}/lib/src/version.dart');
  if (!pubspec.existsSync() || !embedded.existsSync()) {
    throw StateError(
      'run this command from the release-kit repository root',
    );
  }

  final pubspecSource = pubspec.readAsStringSync();
  final embeddedSource = embedded.readAsStringSync();
  final pubspecMatch = _singleMatch(
    RegExp(r'^version: ([^\r\n]+)$', multiLine: true),
    pubspecSource,
    'pubspec.yaml version',
  );
  final embeddedMatch = _singleMatch(
    RegExp(r"^const rkVersion = '([^']+)';$", multiLine: true),
    embeddedSource,
    'lib/src/version.dart rkVersion',
  );

  final pubspecVersion = Version.tryParse(pubspecMatch.group(1)!);
  final embeddedVersion = Version.tryParse(embeddedMatch.group(1)!);
  if (pubspecVersion == null || embeddedVersion == null) {
    throw StateError('the current rk version declarations are not canonical');
  }
  if (pubspecVersion != embeddedVersion) {
    throw StateError(
      'rk version declarations disagree: pubspec.yaml has $pubspecVersion; '
      'lib/src/version.dart has $embeddedVersion',
    );
  }
  if (next <= pubspecVersion) {
    throw ArgumentError(
      'the release version must move forward from $pubspecVersion',
    );
  }

  // Validate every input before either write. The agreement test in the core
  // suite remains the backstop against any interrupted or manual edit.
  pubspec.writeAsStringSync(
    pubspecSource.replaceRange(
      pubspecMatch.start,
      pubspecMatch.end,
      'version: ${next.canonical}',
    ),
  );
  embedded.writeAsStringSync(
    embeddedSource.replaceRange(
      embeddedMatch.start,
      embeddedMatch.end,
      "const rkVersion = '${next.canonical}';",
    ),
  );

  return ReleaseVersionUpdate(
    previous: pubspecVersion,
    next: next,
  );
}

RegExpMatch _singleMatch(
  RegExp pattern,
  String source,
  String description,
) {
  final matches = pattern.allMatches(source).toList();
  if (matches.length != 1) {
    throw StateError('expected exactly one $description declaration');
  }
  return matches.single;
}

class ReleaseVersionUpdate {
  const ReleaseVersionUpdate({
    required this.previous,
    required this.next,
  });

  final Version previous;
  final Version next;
}
