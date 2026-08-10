import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// Production evidence that is deliberately outside the default local lane.
///
/// Run this file only for the supervised release. It stays red until the
/// receipt contains the real provider, retry, and consumer transcripts.
void main() {
  late String receipt;

  setUpAll(
    () => receipt = File('doc/production-alpha-receipt.md').readAsStringSync(),
  );

  test('the release-kit provider release is recorded', () {
    _expectCompleted(receipt);
    final release = _section(receipt, '## Release and provider receipt');
    final version = _field(release, 'Version');
    final manifestDigest = _field(release, 'Manifest SHA-256');
    final notarySubmission = _field(release, 'Notary submission ID');

    expect(_field(release, 'Unit'), 'rk');
    _expectHex(_field(release, 'Clean pushed source commit'), {40});
    _expectHex(_field(release, 'Stage identity'), {64});
    _expectHex(manifestDigest, {64});
    _expectUuid(notarySubmission);
    expect(version, matches(_semanticVersion));
    _expectText(release, {
      'Git tag',
      'pub.dev',
      'GitHub Release',
      'https://github.com/danReynolds/release-kit',
      'https://pub.dev/packages/release_kit/versions/$version',
    });
    final staged = _expectTranscript(release, 'Staged artifact inspection', {
      'rk-$version-macos-arm64.tar.gz',
      'rk-$version-macos-arm64.notary-result.json',
      'rk-$version-macos-arm64.notary-log.json',
      'rk-$version-linux-x64.tar.gz',
      'rk-$version-linux-arm64.tar.gz',
      'SHA256SUMS',
      'release-manifest.json',
      'shasum -a 256 release-manifest.json',
      'shasum -a 256 -c SHA256SUMS',
      'tar -tzf',
      'rk $version',
      'codesign --verify --strict',
      'codesign -d -r-',
      'designated =>',
      'codesign --test-requirement=notarized -v',
      'Accepted',
    });
    _expectNextLine(
      staged,
      'shasum -a 256 release-manifest.json',
      RegExp(
        '^${RegExp.escape(manifestDigest)}[ \\t]+\\*?'
        r'release-manifest\.json$',
      ),
      reason: 'the recorded manifest digest must be the command output for '
          'release-manifest.json',
    );
    final archives = [
      'rk-$version-macos-arm64.tar.gz',
      'rk-$version-linux-x64.tar.gz',
      'rk-$version-linux-arm64.tar.gz',
    ];
    for (final archive in archives) {
      _expectExactLines(
        staged,
        'tar -tzf $archive',
        ['rk', 'LICENSE', 'README.md'],
      );
    }
    final checksumResults = RegExp(
      r'^(\S+): (?:OK|FAILED)$',
      multiLine: true,
    ).allMatches(staged).map((match) => match.group(0)).toList();
    expect(checksumResults, hasLength(archives.length));
    expect(
      checksumResults.toSet(),
      {for (final archive in archives) '$archive: OK'},
      reason: 'SHA256SUMS must verify exactly the three release archives',
    );
    expect(
      staged,
      contains(
        'tar -xzf rk-$version-macos-arm64.tar.gz '
        '-C "\$alpha_macos_dir"',
      ),
      reason: 'the macOS checks must use a freshly extracted archive',
    );
    _expectNextLine(
      staged,
      '"\$alpha_macos_dir/rk" --version',
      RegExp('^rk ${RegExp.escape(version)}\$'),
      reason: 'the staged macOS binary must report the released version',
    );
    expect(
      _commandOutput(
        staged,
        'codesign --verify --strict --verbose=2 '
        '"\$alpha_macos_dir/rk" && echo "signature valid"',
      ),
      contains('signature valid'),
      reason: 'the exact extracted binary signature must verify successfully',
    );
    expect(
      _commandOutput(
        staged,
        'codesign -d -r- --verbose=4 "\$alpha_macos_dir/rk"',
      ),
      contains('designated => identifier "io.github.danreynolds.rk"'),
      reason: 'the extracted binary must carry the configured identity',
    );
    expect(
      _commandOutput(
        staged,
        'codesign --test-requirement=notarized -v '
        '"\$alpha_macos_dir/rk" && echo "notarization valid"',
      ),
      contains('notarization valid'),
      reason: 'the exact extracted bytes must satisfy notarization',
    );
    _expectNotaryEvidence(
      staged,
      result: 'rk-$version-macos-arm64.notary-result.json',
      log: 'rk-$version-macos-arm64.notary-log.json',
      submission: notarySubmission,
    );
    expect(
      staged,
      isNot(contains('dart pub login')),
      reason: 'release --stage must not acquire a publishing session',
    );
    final published = _expectTranscript(release, 'Release transcript', {
      'dart run bin/rk.dart release rk',
      'dart pub login',
      'release_kit $version',
      'rk $version released',
    });
    expect(
      'dart pub login'.allMatches(published),
      hasLength(1),
      reason: 'one native session preflight serves this release',
    );
    expect(
      published.indexOf('dart pub login'),
      lessThan(published.indexOf('release_kit $version')),
      reason: 'native login must precede rk private-stage inspection',
    );
    _expectTranscript(release, 'Fresh-process status read-back', {
      'dart run bin/rk.dart status rk',
      'Git tag',
      'pub.dev',
      'GitHub Release',
      'Published everywhere configured',
    });
  });

  test('the release-kit retry and consumer checks are recorded', () {
    _expectCompleted(receipt);
    final retry = _section(receipt, '## Idempotent retry and consumer receipt');
    final release = _section(receipt, '## Release and provider receipt');
    final version = _field(retry, 'Version');
    final asset = _field(retry, 'Asset');
    final assetDigest = _field(retry, 'Asset SHA-256');
    final sourceCommit = _field(release, 'Clean pushed source commit');

    expect(_field(retry, 'Unit'), 'rk');
    expect(version, matches(_semanticVersion));
    expect(version, _field(release, 'Version'));
    expect(_field(retry, 'Public acts'), '0');
    expect(
      asset,
      matches(RegExp(
        '^rk-${RegExp.escape(version)}-'
        r'(?:macos-arm64|linux-x64|linux-arm64)\.tar\.gz$',
      )),
    );
    _expectHex(assetDigest, {64});
    final repeated = _expectTranscript(retry, 'Repeated release transcript', {
      'dart run bin/rk.dart release rk --json',
    });
    expect(
      repeated,
      isNot(contains('dart pub login')),
      reason: 'an all-exact retry must neither log in nor publish again',
    );
    _expectExactRetry(
      _jsonObjectFromCommand(
        repeated,
        'dart run bin/rk.dart release rk --json',
      ),
      version: version,
      sourceCommit: sourceCommit,
    );
    final pubConsumer = _expectTranscript(retry, 'pub.dev consumer', {
      'dart pub global activate release_kit $version',
      'https://pub.dev/packages/release_kit/versions/$version',
      'alpha_pub_cache',
      'PUB_CACHE="\$alpha_pub_cache"',
      '"\$alpha_pub_cache/bin/rk" --version',
      '"\$alpha_pub_cache/bin/rk" --help',
      'rk $version',
    });
    _expectNextLine(
      pubConsumer,
      '"\$alpha_pub_cache/bin/rk" --version',
      RegExp('^rk ${RegExp.escape(version)}\$'),
      reason: 'the activated pub.dev binary must report the released version',
    );
    _expectLockedHelp(_commandOutput(
      pubConsumer,
      '"\$alpha_pub_cache/bin/rk" --help',
    ));
    final githubConsumer = _expectTranscript(retry, 'GitHub Release consumer', {
      asset,
      assetDigest,
      'https://github.com/danReynolds/release-kit/releases/download/'
          'v$version/$asset',
      'https://github.com/danReynolds/release-kit/releases/download/'
          'v$version/SHA256SUMS',
      'shasum -a 256 -c',
      '$asset: OK',
      './rk --version',
      './rk --help',
      'rk $version',
    });
    expect(
      githubConsumer,
      matches(RegExp(
        '^${RegExp.escape(assetDigest)}[ \\t]+\\*?${RegExp.escape(asset)}\$',
        multiLine: true,
      )),
      reason: 'the selected public checksum line must bind the downloaded '
          'asset to the recorded digest',
    );
    _expectNextLine(
      githubConsumer,
      './rk --version',
      RegExp('^rk ${RegExp.escape(version)}\$'),
      reason: 'the downloaded GitHub binary must report the released version',
    );
    _expectLockedHelp(_commandOutput(githubConsumer, './rk --help'));
  });
}

final _semanticVersion = RegExp(
  r'^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)'
  r'(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$',
);

void _expectCompleted(String receipt) {
  expect(_field(receipt, 'Status'), 'completed');
  expect(receipt, isNot(contains('Status: not run')));
}

String _section(String source, String heading) {
  final start = source.indexOf('$heading\n');
  expect(start, isNonNegative, reason: 'missing `$heading`');
  final bodyStart = start + heading.length + 1;
  final next = source.indexOf('\n## ', bodyStart);
  final body = source.substring(bodyStart, next < 0 ? source.length : next);
  expect(body.trim(), isNotEmpty, reason: '`$heading` has no evidence');
  return body;
}

String _field(String source, String label) {
  final match = RegExp(
    '^${RegExp.escape(label)}: +(.+)\$',
    multiLine: true,
    caseSensitive: false,
  ).firstMatch(source);
  expect(match, isNotNull, reason: 'missing `$label: <exact value>`');
  final value = match!.group(1)!.trim();
  expect(
    value.toLowerCase(),
    isNot(anyOf('not run', 'todo', 'tbd', 'pending', 'placeholder')),
  );
  return value;
}

String _expectTranscript(String parent, String title, Set<String> required) {
  final section = _section(parent, '### $title');
  final block = RegExp(r'```[^\n]*\n([\s\S]+?)\n```').firstMatch(section);
  expect(block, isNotNull, reason: '`### $title` needs a fenced transcript');
  final evidence = block!.group(1)!;
  expect(
    evidence.split('\n').where((line) => line.trim().isNotEmpty).length,
    greaterThanOrEqualTo(3),
    reason: '`### $title` needs substantive command and output evidence',
  );
  _expectText(evidence, required);
  return evidence;
}

void _expectText(String source, Set<String> required) {
  for (final value in required) {
    expect(source, contains(value), reason: 'missing evidence `$value`');
  }
}

void _expectHex(String value, Set<int> lengths) {
  expect(value, matches(RegExp(r'^[0-9a-f]+$')),
      reason: 'expected a lowercase hexadecimal identifier');
  expect(lengths, contains(value.length));
  expect(value.split('').toSet().length, greaterThan(5),
      reason: 'placeholder digests are not evidence');
}

void _expectUuid(String value) {
  expect(
    value,
    matches(RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-'
      r'[0-9a-f]{4}-[0-9a-f]{12}$',
      caseSensitive: false,
    )),
    reason: 'expected the exact Apple notary submission id',
  );
}

void _expectNotaryEvidence(
  String transcript, {
  required String result,
  required String log,
  required String submission,
}) {
  final resultJson = _jsonObjectFromCommand(transcript, 'cat $result');
  final logJson = _jsonObjectFromCommand(transcript, 'cat $log');
  expect(resultJson['id'], submission,
      reason: '`$result` must identify the recorded submission');
  expect(resultJson['status'], 'Accepted',
      reason: '`$result` must be Apple\'s Accepted result');
  expect(logJson['jobId'], submission,
      reason: '`$log` must identify the same submission');
  expect(logJson['status'], 'Accepted',
      reason: '`$log` must be Apple\'s Accepted result');
}

Map<String, Object?> _jsonObjectFromCommand(
  String transcript,
  String command,
) {
  final output = _commandOutput(transcript, command);
  final decoded = jsonDecode(output.trim());
  expect(decoded, isA<Map>(), reason: '`$command` did not return an object');
  return (decoded as Map).cast<String, Object?>();
}

void _expectExactRetry(
  Map<String, Object?> report, {
  required String version,
  required String sourceCommit,
}) {
  expect(report['command'], 'release');
  expect(report['exit'], 0);
  expect(report['problems'], isEmpty);
  expect(report['next'], isEmpty);
  expect(report.containsKey('halt'), isFalse);
  expect((report['mode'] as Map)['stage'], isFalse);
  expect((report['repository'] as Map)['head'], sourceCommit);

  final units = report['units'] as List;
  expect(units, hasLength(1));
  final unit = (units.single as Map).cast<String, Object?>();
  expect(unit['name'], 'rk');
  expect(unit['version'], version);
  final publicSteps = (unit['steps'] as List)
      .cast<Map>()
      .map((step) => step.cast<String, Object?>())
      .where((step) => step['public'] == true)
      .toList();
  expect(publicSteps, hasLength(3));
  expect(
    publicSteps.map((step) => step['kind']).toSet(),
    {'tag', 'publishRegistry', 'publishRelease'},
    reason: 'the retry must account for every configured public target',
  );
  for (final step in publicSteps) {
    expect(step['verdict'], 'exact', reason: '${step['kind']} was not exact');
    expect(step['action'], 'already_exact',
        reason: '${step['kind']} performed work on the retry');
  }
}

void _expectNextLine(
  String transcript,
  String command,
  RegExp expected, {
  required String reason,
}) {
  final output = _commandOutput(transcript, command);
  final line = output.split('\n').firstWhere(
        (candidate) => candidate.trim().isNotEmpty,
        orElse: () => '',
      );
  expect(line, matches(expected), reason: reason);
}

void _expectExactLines(
  String transcript,
  String command,
  List<String> expected,
) {
  final actual = _commandOutput(transcript, command)
      .split('\n')
      .where((line) => line.isNotEmpty)
      .toList();
  expect(actual, expected, reason: '`\$ $command` inventory differs');
}

String _commandOutput(String transcript, String command) {
  final marker = RegExp(
    '^\\\$ ${RegExp.escape(command)}[ \\t]*\$',
    multiLine: true,
  );
  final commands = marker.allMatches(transcript).toList();
  expect(commands, hasLength(1),
      reason: 'record exactly one command line as `\$ $command`');
  final lineEnd = transcript.indexOf('\n', commands.single.end);
  expect(lineEnd, isNonNegative, reason: '`\$ $command` has no output');
  final outputStart = lineEnd + 1;
  final nextCommand = RegExp(r'^\$ ', multiLine: true)
      .firstMatch(transcript.substring(outputStart));
  final outputEnd =
      nextCommand == null ? transcript.length : outputStart + nextCommand.start;
  return transcript.substring(outputStart, outputEnd);
}

void _expectLockedHelp(String transcript) {
  final usage = RegExp(
    r'^  (rk(?: [^ \n]+)*) {2,}\S',
    multiLine: true,
  ).allMatches(transcript).map((match) => match.group(1)).toList();
  expect(usage, hasLength(6));
  expect(
    usage.toSet(),
    {
      'rk',
      'rk --version',
      'rk status [unit]',
      'rk init',
      'rk release <unit>',
      'rk release <unit> --stage',
    },
    reason: 'the consumed binary must expose the exact locked usage surface',
  );
  expect(transcript, isNot(contains('--dry-run')),
      reason: 'the retired rehearsal surface must not return');
}
