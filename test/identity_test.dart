import 'package:release_kit/src/engine/identity.dart';
import 'package:release_kit/src/engine/tools.dart';
import 'package:release_kit/src/engine/version.dart';
import 'package:test/test.dart';

import 'scripted_tools.dart';

void main() {
  PublishedIdentity identity(Map<String, ToolResult> answers) =>
      PublishedIdentity(
        tools: ScriptedTools(answers),
        repository: 'example/tool',
        workingDirectory: '/repo',
      );

  group('public signing history', () {
    test('is complete, public-only, and newest first in a shallow checkout',
        () async {
      final history = await identity({
        'gh': ok('''[[
          {"tag_name":"v0.7.0","draft":false},
          {"tag_name":"v0.9.0","draft":false},
          {"tag_name":"v0.8.0","draft":true},
          {"tag_name":"notes","draft":false}
        ],[
          {"tag_name":"v1.0.0","draft":false}
        ]]'''),
      }).priorReleaseTags(
        tagPattern: 'v{version}',
        before: Version.tryParse('1.0.0')!,
      );

      expect(history.readable, isTrue, reason: history.why);
      expect(history.tags, ['v0.9.0', 'v0.7.0']);
    });

    test('an unreadable or malformed public history never means first release',
        () async {
      final unreachable = await identity({
        'gh': failed('could not resolve host'),
      }).priorReleaseTags(
        tagPattern: 'v{version}',
        before: Version.tryParse('1.0.0')!,
      );
      final malformed = await identity({
        'gh': ok('[[{"tag_name":"v0.9.0"}]]'),
      }).priorReleaseTags(
        tagPattern: 'v{version}',
        before: Version.tryParse('1.0.0')!,
      );

      expect(unreachable.readable, isFalse);
      expect(malformed.readable, isFalse);
    });

    test('a listed release disappearing during identity read is unreadable',
        () async {
      final reading = await PublishedIdentity(
        tools: SequencedTools([failed('gh: Not Found (HTTP 404)')]),
        repository: 'example/tool',
        workingDirectory: '/repo',
      ).read(
        tag: 'v0.9.0',
        executable: 'example',
        into: '/tmp/w',
        expectedPublished: true,
      );

      expect(reading.answer, IdentityAnswer.unreadable);
      expect(reading.why, contains('disappeared'));
    });
  });

  test('reads the requirement from the published binary', () async {
    final reading = await identity({
      'gh': ok('{"assets":[{"name":"example-2.1.0-macos-arm64.tar.gz"}]}'),
      'tar': ok(),
      'codesign': ok('designated => identifier "com.example.tool" and '
          'certificate leaf[subject.OU] = "ABCDE12345"'),
    }).read(tag: 'v2.1.0', executable: 'example', into: '/tmp/w');

    expect(reading.isKnown, isTrue, reason: reading.why);
    expect(reading.requirement, contains('ABCDE12345'));
  });

  test('runs the steps in the order that makes them meaningful', () async {
    final tools = ScriptedTools({
      'gh': ok('{"assets":[{"name":"example-2.1.0-macos-arm64.tar.gz"}]}'),
      'tar': ok(),
      'codesign': ok('designated => identifier "x"'),
    });
    await PublishedIdentity(
      tools: tools,
      repository: 'example/tool',
      workingDirectory: '/repo',
    ).read(tag: 'v2.1.0', executable: 'example', into: '/tmp/w');

    expect(
      tools.calls.map((c) => c.first).toList(),
      ['gh', 'gh', 'tar', 'codesign', 'codesign'],
      reason: 'ask the release, download, open the named asset, then read the '
          'verified signature',
    );
    expect(
      tools.calls.first.join(' '),
      contains('api repos/example/tool/releases/tags/v2.1.0'),
      reason: 'existence is read from the release object, status-coded',
    );
    expect(tools.calls[1], contains('--repo'));
    expect(
      tools.calls[1],
      contains('example-2.1.0-macos-arm64.tar.gz'),
      reason: 'the asset is named from the release\'s own list, not guessed '
          'at with a glob',
    );
  });

  group('nothing published and nothing readable are different answers', () {
    test('no matching asset is an absence, read from the list itself',
        () async {
      // The release exists and its own asset list has nothing for this
      // executable and platform — absence as data, not as matched prose.
      final reading = await PublishedIdentity(
        tools: SequencedTools([
          ok('{"assets":[{"name":"other-2.1.0-linux-x64.tar.gz"}]}'),
        ]),
        repository: 'example/tool',
        workingDirectory: '/repo',
      ).read(tag: 'v2.1.0', executable: 'example', into: '/tmp/w');

      expect(reading.isKnown, isFalse);
      expect(
        reading.answer,
        IdentityAnswer.none,
        reason: 'the honest state before a first signed release — and data, '
            'so no caller has to string-match the prose',
      );
    });

    test('no release at the tag is an absence, once the repo has answered',
        () async {
      final reading = await PublishedIdentity(
        tools: SequencedTools([
          failed('gh: Not Found (HTTP 404)'),
          ok('{"name":"tool"}'),
        ]),
        repository: 'example/tool',
        workingDirectory: '/repo',
      ).read(tag: 'v2.1.0', executable: 'example', into: '/tmp/w');

      expect(reading.answer, IdentityAnswer.none);
    });

    test('a repository rk cannot see is not an absence', () async {
      // gh says "release not found" for a repository that does not exist and
      // for a real one missing that release. Read as absence, a typo in the
      // origin would let a release sign against no identity at all.
      final reading = await PublishedIdentity(
        tools: SequencedTools([
          failed('gh: Not Found (HTTP 404)'),
          failed('Could not resolve to a Repository'),
        ]),
        repository: 'example/typo',
        workingDirectory: '/repo',
      ).read(tag: 'v2.1.0', executable: 'example', into: '/tmp/w');

      expect(reading.isKnown, isFalse);
      expect(reading.answer, IdentityAnswer.unreadable);
    });

    test('a network failure is not an absence', () async {
      final reading = await identity({
        'gh': failed('could not resolve host: api.github.com'),
      }).read(tag: 'v2.1.0', executable: 'example', into: '/tmp/w');

      expect(reading.isKnown, isFalse);
      expect(
        reading.answer,
        IdentityAnswer.unreadable,
        reason: 'read as "nothing is published", an unreachable forge would '
            'let a release sign itself against no identity at all',
      );
    });

    test('an archive that will not open is not an absence', () async {
      final reading = await identity({
        'gh': ok('{"assets":[{"name":"example-2.1.0-macos-arm64.tar.gz"}]}'),
        'tar': failed('unexpected end of file'),
      }).read(tag: 'v2.1.0', executable: 'example', into: '/tmp/w');

      expect(reading.isKnown, isFalse);
      expect(reading.why, contains('could not be opened'));
    });

    test('an unsigned published binary is not an absence either', () async {
      final reading = await identity({
        'gh': ok('{"assets":[{"name":"example-2.1.0-macos-arm64.tar.gz"}]}'),
        'tar': ok(),
        'codesign': failed('code object is not signed at all'),
      }).read(tag: 'v2.1.0', executable: 'example', into: '/tmp/w');

      expect(reading.isKnown, isFalse);
      expect(reading.why, contains('signature is not valid'));
    });

    test('a displayed requirement from invalid bytes is not a baseline',
        () async {
      final tools = RecordingTools(
        answers: (key) {
          if (key.startsWith('gh api ')) {
            return ok(
              '{"assets":[{'
              '"name":"example-2.1.0-macos-arm64.tar.gz"}]}',
            );
          }
          if (key.startsWith('gh release download')) return ok();
          if (key.startsWith('tar -xzf')) return ok();
          if (key.startsWith('codesign --verify')) {
            return failed('code object is not signed at all');
          }
          if (key.startsWith('codesign -d -r-')) {
            return ok('designated => identifier "forged"');
          }
          return null;
        },
      );
      final reading = await PublishedIdentity(
        tools: tools,
        repository: 'example/tool',
        workingDirectory: '/repo',
      ).read(tag: 'v2.1.0', executable: 'example', into: '/tmp/w');

      expect(reading.answer, IdentityAnswer.unreadable);
      expect(reading.why, contains('not valid for its bytes'));
      expect(
        tools.calls.where((call) => call.startsWith('codesign -d -r-')),
        isEmpty,
      );
    });
  });

  test('the identity comes from the published binary, never the keychain',
      () async {
    final tools = ScriptedTools({
      'gh': ok('{"assets":[{"name":"example-2.1.0-macos-arm64.tar.gz"}]}'),
      'tar': ok(),
      'codesign': ok('designated => identifier "x"'),
    });
    await PublishedIdentity(
      tools: tools,
      repository: 'example/tool',
      workingDirectory: '/repo',
    ).read(tag: 'v2.1.0', executable: 'example', into: '/tmp/w');

    expect(
      tools.calls.any((c) => c.first == 'security'),
      isFalse,
      reason: 'asking the certificate that is about to sign what it will sign '
          'with is a tautology — it agrees with itself whatever it is',
    );
  });
}
