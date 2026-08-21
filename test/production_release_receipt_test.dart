import 'dart:io';

import 'package:test/test.dart';

void main() {
  late String receipt;

  setUpAll(
    () => receipt = File('doc/production-alpha-receipt.md').readAsStringSync(),
  );

  test('records the completed rk 0.1.4 production release', () {
    expect(_field(receipt, 'Status'), 'completed');
    expect(_field(receipt, 'Date'), '2026-08-21');
    expect(_field(receipt, 'Unit'), 'rk');
    expect(_field(receipt, 'Version'), '0.1.4');
    expect(
      _field(receipt, 'Source commit'),
      '4118904ad0827b854f1d9200fdaf5fa924e62bb7',
    );
    expect(
      _field(receipt, 'Stage identity'),
      'ed53e252c2e1f97e38b3bb0219b388fdc6a15661df8bfd791cbfd4e09810ea95',
    );
    expect(
      _field(receipt, 'Manifest SHA-256'),
      'af61e56a53c3014660790cb919dad6ef2efc4d83faf022fa8616d1b8471450aa',
    );
    expect(
      _field(receipt, 'Notary submission ID'),
      'd0f083fe-af5b-4cc2-ac4a-dc959dc21d79',
    );

    for (final value in <String>{
      _field(receipt, 'Certificate SHA-256'),
      _field(receipt, 'macOS executable SHA-256'),
      ...RegExp(r'`([0-9a-f]{64})`')
          .allMatches(_section(receipt, '## Stage artifacts'))
          .map((match) => match.group(1)!),
    }) {
      expect(value, matches(RegExp(r'^[0-9a-f]{64}$')));
    }

    _expectText(receipt, {
      'Signed smoke: pass',
      'Post-smoke signature verification: pass',
      'Archive-extracted signature verification: pass',
      'Notarization requirement: pass',
      'Notary result: Accepted',
      'codesign --verify --strict',
      "codesign -R='notarized' -v",
      '970 passing tests',
      'GitHub CI on Ubuntu and macOS',
    });
    expect(receipt, isNot(contains('codesign --test-requirement')));
    expect(receipt, isNot(contains('Status: not run')));
    expect(receipt, isNot(matches(RegExp(r'<[^>]+>'))));
  });

  test('records exact public reconciliation and every clean consumer', () {
    _expectText(_section(receipt, '## Public reconciliation'), {
      'https://pub.dev/packages/rk/versions/0.1.4',
      'https://github.com/danReynolds/release-kit/releases/tag/v0.1.4',
      'https://github.com/danReynolds/homebrew-tap/blob/main/Casks/rk.rb',
      'Git tag, pub.dev, GitHub Release,',
      '`verdict: exact`',
      '`action: already_published`',
      'Public acts on retry: 0',
      'bounded 60-second read-back',
      'two minutes later',
    });

    final consumers = _section(receipt, '## Clean consumers');
    _expectText(consumers, {
      'fresh `PUB_CACHE`',
      'fresh download/extraction directory',
      'clean native Apple Silicon cask install',
      '`/opt/homebrew/bin/rk --version`',
      '`rk status rk`',
      '`/Users/dan/.local/bin/rk`',
      '0.1.4',
    });
    expect(RegExp(r'\| pass \|').allMatches(consumers), hasLength(4));
  });
}

String _field(String source, String label) {
  final match = RegExp(
    '^${RegExp.escape(label)}: +(.+)\$',
    multiLine: true,
    caseSensitive: false,
  ).firstMatch(source);
  expect(match, isNotNull, reason: 'missing `$label: <exact value>`');
  return match!.group(1)!.trim();
}

String _section(String source, String heading) {
  final start = source.indexOf('$heading\n');
  expect(start, isNonNegative, reason: 'missing `$heading`');
  final bodyStart = start + heading.length + 1;
  final next = source.indexOf('\n## ', bodyStart);
  return source.substring(bodyStart, next < 0 ? source.length : next);
}

void _expectText(String source, Set<String> required) {
  for (final text in required) {
    expect(source, contains(text), reason: 'missing evidence `$text`');
  }
}
