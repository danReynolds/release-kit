import 'dart:io';

import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/transforms/macos.dart';
import 'package:test/test.dart';

const _name = 'Developer ID Application: Dan (TEAM123456)';
final _sha1 = 'a' * 40;
final _otherSha1 = 'b' * 40;
final _sha256 = 'c' * 64;
final _otherSha256 = 'd' * 64;

void main() {
  test('correlates the selected identity to its SHA-256 certificate block',
      () async {
    final tools = _tools(certificateOutput: '''
SHA-256 hash: $_otherSha256
SHA-1 hash: $_otherSha1
keychain: "/tmp/other.keychain"
SHA-256 hash: $_sha256
SHA-1 hash: $_sha1
keychain: "/tmp/login.keychain-db"
''');
    final signer = MacOsSigner(tools: tools);

    final identities = await signer.availableIdentities();

    expect(identities, hasLength(1));
    expect(identities!.single.sha1, _sha1);
    expect(await signer.certificateSha256(identities.single), _sha256);
    expect(
      tools.calls,
      contains('security find-certificate -a -c $_name -Z'),
    );
  });

  test('signing carries the exact certificate SHA-256 fingerprint', () async {
    final tools = _tools(certificateOutput: '''
SHA-256 hash: $_sha256
SHA-1 hash: $_sha1
''');
    final signer = MacOsSigner(tools: tools);
    final identity = (await signer.availableIdentities())!.single;

    final signed = await signer.sign(
      binary: '/tmp/tool',
      team: 'TEAM123456',
      codeId: 'io.example.tool',
      selectedIdentity: identity,
      expectedCertificateSha256: _sha256,
    );

    expect(signed.ok, isTrue);
    expect(signed.certificate, _name);
    expect(signed.certificateSha256, _sha256);
    expect(
      tools.calls.where((call) => call.startsWith('codesign --force')).single,
      contains('--sign $_sha1 /tmp/tool'),
    );
    expect(tools.calls, contains('codesign --verify --strict /tmp/tool'));
    expect(
      tools.calls.indexOf('codesign --verify --strict /tmp/tool'),
      greaterThan(tools.calls.indexOf('codesign -d -r- /tmp/tool')),
      reason: 'the readable requirement is not proof that the signed bytes '
          'verify; both checks must finish before the outcome is recordable',
    );
  });

  test('a newly written signature must verify before it is recordable',
      () async {
    final tools = _tools(
      certificateOutput: '''
SHA-256 hash: $_sha256
SHA-1 hash: $_sha1
''',
      signatureVerifies: false,
    );
    final signer = MacOsSigner(tools: tools);

    final signed = await signer.sign(
      binary: '/tmp/tool',
      team: 'TEAM123456',
      codeId: 'io.example.tool',
    );

    expect(signed.ok, isFalse);
    expect(signed.requirement, isNull);
    expect(signed.problem, contains('did not verify after signing'));
    expect(tools.calls, contains('codesign -d -r- /tmp/tool'));
    expect(tools.calls, contains('codesign --verify --strict /tmp/tool'));
    // rk's sentence says the signature is bad; only codesign says which
    // resource, and after this returns nobody else can ask.
    expect(signed.transcript, contains('a sealed resource is missing'));
    expect(signed.transcript, contains('file modified: /tmp/tool'));
  });

  test('an unreadable fingerprint fails before codesign can mutate bytes',
      () async {
    final tools = _tools(certificateOutput: '');
    final signer = MacOsSigner(tools: tools);

    final signed = await signer.sign(
      binary: '/tmp/tool',
      team: 'TEAM123456',
      codeId: 'io.example.tool',
    );

    expect(signed.ok, isFalse);
    expect(signed.problem, contains('fingerprint could not be read'));
    expect(tools.calls.where((call) => call.startsWith('codesign --force')),
        isEmpty);
  });

  group('a runtime admits only the modules it ships', () {
    final module = 'ab' * 20;
    final other = '0f' * 20;

    test('signing embeds a constraint naming exactly the pinned code hashes',
        () async {
      String? call;
      String? constraint;
      final tools = _tools(
        certificateOutput: 'SHA-256 hash: $_sha256\nSHA-1 hash: $_sha1\n',
        onSign: (key) {
          call = key;
          constraint = File(key
                  .split(' --library-constraint ')
                  .last
                  .split(' --sign ')
                  .first)
              .readAsStringSync();
        },
      );

      final signed = await MacOsSigner(tools: tools).sign(
        binary: '/tmp/runtime',
        team: 'TEAM123456',
        codeId: 'io.example.tool',
        pinnedLibraries: [module, other],
      );

      expect(signed.ok, isTrue, reason: signed.problem);
      expect(call, contains('--enforce-constraint-validity'),
          reason: 'a constraint this macOS cannot evaluate must fail to sign');
      expect(constraint, contains('<key>cdhash</key>'));
      expect(constraint, contains(r'<key>$in</key>'));
      expect(constraint, contains('<data>q6urq6urq6urq6urq6urq6urq6s=</data>'));
      expect(constraint, contains('<data>Dw8PDw8PDw8PDw8PDw8PDw8PDw8=</data>'));
      expect(
          File('/tmp/runtime.library-constraint.plist').existsSync(), isFalse,
          reason: 'a codesign input must not survive into the workspace');
    });

    test('a signature with nothing to pin carries no constraint', () async {
      final tools = _tools(
          certificateOutput: 'SHA-256 hash: $_sha256\nSHA-1 hash: $_sha1\n');

      await MacOsSigner(tools: tools)
          .sign(binary: '/tmp/tool', team: 'TEAM123456', codeId: 'io.example');

      expect(
          tools.calls
              .singleWhere((call) => call.startsWith('codesign --force')),
          isNot(contains('--library-constraint')));
    });

    test('a malformed code hash is refused before anything is signed',
        () async {
      final tools = _tools(
          certificateOutput: 'SHA-256 hash: $_sha256\nSHA-1 hash: $_sha1\n');

      final signed = await MacOsSigner(tools: tools).sign(
        binary: '/tmp/runtime',
        team: 'TEAM123456',
        codeId: 'io.example.tool',
        pinnedLibraries: ['not a hash'],
      );

      expect(signed.ok, isFalse);
      expect(signed.problem, contains('malformed'));
      expect(tools.calls, isEmpty);
    });

    test('code hashes are every candidate codesign displays', () async {
      final tools = _tools(certificateOutput: '', displays: {
        'codesign -dvvv /tmp/app.aot': ToolResult(
          exitCode: 0,
          stdout: '',
          stderr: 'Hash type=sha256 size=32\n'
              'CandidateCDHash sha1=$other\n'
              'CandidateCDHash sha256=$module\n'
              'CandidateCDHashFull sha256=${module}0123456789abcdef01234567\n'
              'CDHash=$module\n',
        ),
      });

      expect(
          await MacOsSigner(tools: tools).codeDirectoryHashes('/tmp/app.aot'),
          [other, module]);
    });

    test('a module whose code hash cannot be read answers null', () async {
      final tools = _tools(certificateOutput: '', displays: {
        'codesign -dvvv /tmp/app.aot':
            ToolResult(exitCode: 1, stdout: '', stderr: 'not signed at all'),
      });

      expect(
          await MacOsSigner(tools: tools).codeDirectoryHashes('/tmp/app.aot'),
          isNull);
    });

    test('the embedded constraint reads back as exactly its code hashes',
        () async {
      final tools = _tools(certificateOutput: '', displays: {
        'codesign -dvvvvvv /tmp/runtime':
            ToolResult(exitCode: 0, stdout: '', stderr: _constraint([module])),
      });

      expect(await MacOsSigner(tools: tools).admittedLibraries('/tmp/runtime'),
          {module});
    });

    test('a constraint stating more than code hashes is not read as a pin',
        () async {
      final tools = _tools(certificateOutput: '', displays: {
        'codesign -dvvvvvv /tmp/runtime': ToolResult(
            exitCode: 0,
            stdout: '',
            stderr: _constraint([module], extra: 'team-identifier')),
      });

      expect(await MacOsSigner(tools: tools).admittedLibraries('/tmp/runtime'),
          isNull);
    });

    test('a runtime without a constraint admits nothing it records', () async {
      final tools = _tools(certificateOutput: '', displays: {
        'codesign -dvvvvvv /tmp/runtime': ToolResult(
            exitCode: 0,
            stdout: '',
            stderr: 'CDHash=$module\nSignature=adhoc\n'),
      });

      expect(await MacOsSigner(tools: tools).admittedLibraries('/tmp/runtime'),
          isEmpty);
    });
  });
}

/// codesign's highest-verbosity display of a library load constraint, as
/// macOS 26 prints it.
String _constraint(List<String> hashes, {String? extra}) => [
      'Library Load Constraints:',
      '\tHas Library Load Constraints',
      'CDHash=${'1' * 40}',
      'Signature=adhoc',
      'Internal requirements count=0 size=12',
      '\t[Dict]',
      '\t\t[Key] ccat',
      '\t\t[Value]',
      '\t\t\t[Int] 0',
      '\t\t[Key] comp',
      '\t\t[Value]',
      '\t\t\t[Int] 1',
      '\t\t[Key] reqs',
      '\t\t[Value]',
      '\t\t\t[Dict]',
      if (extra != null) ...[
        '\t\t\t\t[Key] $extra',
        '\t\t\t\t[Value]',
        '\t\t\t\t\t[String] TEAM123456',
      ],
      '\t\t\t\t[Key] cdhash',
      '\t\t\t\t[Value]',
      '\t\t\t\t\t[Dict]',
      '\t\t\t\t\t\t[Key] \$in',
      '\t\t\t\t\t\t[Value]',
      '\t\t\t\t\t\t\t[Array]',
      for (final hash in hashes) '\t\t\t\t\t\t\t\t[Data] $hash',
      '\t\t[Key] vers',
      '\t\t[Value]',
      '\t\t\t[Int] 1',
    ].join('\n');

RecordingTools _tools({
  required String certificateOutput,
  bool signatureVerifies = true,
  void Function(String key)? onSign,
  Map<String, ToolResult> displays = const {},
}) =>
    RecordingTools(
      results: displays,
      onRun: (key) {
        if (key.startsWith('codesign --force')) {
          final path =
              key.split(' --entitlements ').last.split(' --identifier ').first;
          final entitlements = File(path).readAsStringSync();
          expect(entitlements, contains('<dict>'));
          expect(entitlements, isNot(contains('<key>')));
          onSign?.call(key);
        }
      },
      answers: (key) {
        if (key == 'security find-identity -v -p codesigning') {
          return ToolResult(
            exitCode: 0,
            stdout: '1) $_sha1 "$_name"',
            stderr: '',
          );
        }
        if (key.startsWith('security find-certificate')) {
          return ToolResult(
            exitCode: 0,
            stdout: certificateOutput,
            stderr: '',
          );
        }
        if (key.startsWith('codesign -d -r-')) {
          return ToolResult(
            exitCode: 0,
            stdout: 'designated => identifier "io.example.tool"',
            stderr: '',
          );
        }
        if (key.startsWith('codesign --verify --strict')) {
          return ToolResult(
            exitCode: signatureVerifies ? 0 : 1,
            stdout: '',
            stderr: signatureVerifies
                ? ''
                : 'invalid signature\n'
                    '/tmp/tool: a sealed resource is missing or invalid\n'
                    'file modified: /tmp/tool/Contents/MacOS/helper',
          );
        }
        return null;
      },
    );
