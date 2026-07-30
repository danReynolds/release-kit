import 'package:rk/src/engine/identity.dart';
import 'package:rk/src/engine/tools.dart';
import 'package:test/test.dart';

/// Tools that answer from a script, so the sequence rk runs is asserted rather
/// than assumed.
class ScriptedTools implements Tools {
  ScriptedTools(this.answers);

  /// Keyed by the executable rk invokes.
  final Map<String, ToolResult> answers;

  /// Every command run, in order.
  final List<List<String>> calls = [];

  @override
  Future<ToolResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    calls.add([executable, ...arguments]);
    return answers[executable] ??
        ToolResult(exitCode: 127, stdout: '', stderr: '$executable not found');
  }

  @override
  Future<int> runInteractive(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async =>
      0;
}

/// Tools that answer in order, for the paths where rk asks twice.
class _Sequence implements Tools {
  _Sequence(this._answers);

  final List<ToolResult> _answers;
  var _at = 0;

  @override
  Future<ToolResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async =>
      _at < _answers.length
          ? _answers[_at++]
          : ToolResult(exitCode: 127, stdout: '', stderr: 'unscripted');

  @override
  Future<int> runInteractive(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async =>
      0;
}

ToolResult ok([String stdout = '']) =>
    ToolResult(exitCode: 0, stdout: stdout, stderr: '');

ToolResult failed(String stderr) =>
    ToolResult(exitCode: 1, stdout: '', stderr: stderr);

void main() {
  PublishedIdentity identity(Map<String, ToolResult> answers) =>
      PublishedIdentity(
        tools: ScriptedTools(answers),
        repository: 'example/tool',
        workingDirectory: '/repo',
      );

  test('reads the requirement from the published binary', () async {
    final reading = await identity({
      'gh': ok(),
      'sh': ok('/tmp/w/example-2.1.0-macos-arm64.tar.gz\n'),
      'tar': ok(),
      'codesign': ok('designated => identifier "com.example.tool" and '
          'certificate leaf[subject.OU] = "ABCDE12345"'),
    }).read(tag: 'v2.1.0', executable: 'example', into: '/tmp/w');

    expect(reading.isKnown, isTrue, reason: reading.why);
    expect(reading.requirement, contains('ABCDE12345'));
  });

  test('runs the steps in the order that makes them meaningful', () async {
    final tools = ScriptedTools({
      'gh': ok(),
      'sh': ok('/tmp/w/example-2.1.0-macos-arm64.tar.gz\n'),
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
      ['gh', 'sh', 'tar', 'codesign'],
      reason: 'download, locate, open, then read the signature',
    );
    expect(tools.calls.first, contains('--repo'));
    expect(
      tools.calls.first,
      contains('example-*-macos-arm64.tar.gz'),
      reason: 'the asset is named by convention, not guessed at',
    );
  });

  group('nothing published and nothing readable are different answers', () {
    test('no matching asset is an absence, once the repo has answered',
        () async {
      // gh fails the download and succeeds the repo lookup, which is what
      // "the repository is there and has no such asset" looks like.
      final reading = await PublishedIdentity(
        tools: _Sequence([
          failed('no assets match the pattern'),
          ok('{"name":"tool"}'),
        ]),
        repository: 'example/tool',
        workingDirectory: '/repo',
      ).read(tag: 'v2.1.0', executable: 'example', into: '/tmp/w');

      expect(reading.isKnown, isFalse);
      expect(
        reading.why,
        contains('no macOS archive is published'),
        reason: 'the honest state before a first signed release',
      );
    });

    test('a repository rk cannot see is not an absence', () async {
      // gh says "release not found" for a repository that does not exist and
      // for a real one missing that release. Read as absence, a typo in the
      // origin would let a release sign against no identity at all.
      final reading = await PublishedIdentity(
        tools: _Sequence([
          failed('release not found'),
          failed('Could not resolve to a Repository'),
        ]),
        repository: 'example/typo',
        workingDirectory: '/repo',
      ).read(tag: 'v2.1.0', executable: 'example', into: '/tmp/w');

      expect(reading.isKnown, isFalse);
      expect(reading.why, contains('could not be read'));
      expect(reading.why, isNot(contains('no macOS archive is published')));
    });

    test('a network failure is not an absence', () async {
      final reading = await identity({
        'gh': failed('could not resolve host: api.github.com'),
      }).read(tag: 'v2.1.0', executable: 'example', into: '/tmp/w');

      expect(reading.isKnown, isFalse);
      expect(
        reading.why,
        contains('could not be downloaded'),
        reason: 'read as "nothing is published", an unreachable forge would '
            'let a release sign itself against no identity at all',
      );
      expect(reading.why, isNot(contains('no macOS archive is published')));
    });

    test('an archive that will not open is not an absence', () async {
      final reading = await identity({
        'gh': ok(),
        'sh': ok('/tmp/w/example-2.1.0-macos-arm64.tar.gz\n'),
        'tar': failed('unexpected end of file'),
      }).read(tag: 'v2.1.0', executable: 'example', into: '/tmp/w');

      expect(reading.isKnown, isFalse);
      expect(reading.why, contains('could not be opened'));
    });

    test('an unsigned published binary is not an absence either', () async {
      final reading = await identity({
        'gh': ok(),
        'sh': ok('/tmp/w/example-2.1.0-macos-arm64.tar.gz\n'),
        'tar': ok(),
        'codesign': failed('code object is not signed at all'),
      }).read(tag: 'v2.1.0', executable: 'example', into: '/tmp/w');

      expect(reading.isKnown, isFalse);
      expect(reading.why, contains('no signature rk could read'));
    });
  });

  test('the identity comes from the published binary, never the keychain',
      () async {
    final tools = ScriptedTools({
      'gh': ok(),
      'sh': ok('/tmp/w/example-2.1.0-macos-arm64.tar.gz\n'),
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
