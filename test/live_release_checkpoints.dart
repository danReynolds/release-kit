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

    expect(_field(release, 'Unit'), 'rk');
    _expectHex(_field(release, 'Clean pushed source commit'), {40, 64});
    _expectHex(_field(release, 'Stage identity'), {64});
    _expectHex(_field(release, 'Manifest SHA-256'), {64});
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
      'shasum -a 256 -c SHA256SUMS',
      'tar -tzf',
      'rk $version',
      'codesign --verify --strict',
      'codesign -d -r-',
      'designated =>',
      'codesign --test-requirement=notarized -v',
      'Accepted',
    });
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
    final version = _field(retry, 'Version');
    final asset = _field(retry, 'Asset');
    final assetDigest = _field(retry, 'Asset SHA-256');

    expect(_field(retry, 'Unit'), 'rk');
    expect(version, matches(_semanticVersion));
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
      'dart run bin/rk.dart release rk',
      'already released',
    });
    expect(
      repeated,
      isNot(contains('dart pub login')),
      reason: 'an all-exact retry must neither log in nor publish again',
    );
    _expectTranscript(retry, 'pub.dev consumer', {
      'dart pub global activate release_kit $version',
      'https://pub.dev/packages/release_kit/versions/$version',
      'alpha_pub_cache',
      'PUB_CACHE="\$alpha_pub_cache"',
      '"\$alpha_pub_cache/bin/rk" --version',
      '"\$alpha_pub_cache/bin/rk" --help',
      'rk $version',
    });
    _expectTranscript(retry, 'GitHub Release consumer', {
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
