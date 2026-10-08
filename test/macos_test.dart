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
  test(
    'correlates the selected identity to its SHA-256 certificate block',
    () async {
      final tools = _tools(
        certificateOutput:
            '''
SHA-256 hash: $_otherSha256
SHA-1 hash: $_otherSha1
keychain: "/tmp/other.keychain"
SHA-256 hash: $_sha256
SHA-1 hash: $_sha1
keychain: "/tmp/login.keychain-db"
''',
      );
      final signer = MacOsSigner(tools: tools);

      final identities = await signer.availableIdentities();

      expect(identities, hasLength(1));
      expect(identities!.single.sha1, _sha1);
      expect(await signer.certificateSha256(identities.single), _sha256);
      expect(
        tools.calls,
        contains('security find-certificate -a -c $_name -Z'),
      );
    },
  );

  test('signing carries the exact certificate SHA-256 fingerprint', () async {
    final tools = _tools(
      certificateOutput:
          '''
SHA-256 hash: $_sha256
SHA-1 hash: $_sha1
''',
    );
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
  });

  test(
    'an unreadable fingerprint fails before codesign can mutate bytes',
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
      expect(
        tools.calls.where((call) => call.startsWith('codesign --force')),
        isEmpty,
      );
    },
  );

  group('a runtime admits only the modules it ships', () {
    final module = 'ab' * 20;
    final other = '0f' * 20;

    test(
      'signing embeds a constraint naming exactly the pinned code hashes',
      () async {
        String? call;
        String? constraint;
        String? constraintPath;
        final tools = _tools(
          certificateOutput: 'SHA-256 hash: $_sha256\nSHA-1 hash: $_sha1\n',
          onSign: (key) {
            call = key;
            constraintPath = key
                .split(' --library-constraint ')
                .last
                .split(' --sign ')
                .first;
            expect(constraintPath, isNot(startsWith('/tmp/runtime.')));
            constraint = File(constraintPath!).readAsStringSync();
          },
        );

        final signed = await MacOsSigner(tools: tools).sign(
          binary: '/tmp/runtime',
          team: 'TEAM123456',
          codeId: 'io.example.tool',
          pinnedLibraries: [module, other],
        );

        expect(signed.ok, isTrue, reason: signed.problem);
        expect(
          call,
          contains('--enforce-constraint-validity'),
          reason: 'a constraint this macOS cannot evaluate must fail to sign',
        );
        expect(constraint, contains('<key>cdhash</key>'));
        expect(constraint, contains(r'<key>$in</key>'));
        expect(
          constraint,
          contains('<data>q6urq6urq6urq6urq6urq6urq6s=</data>'),
        );
        expect(
          constraint,
          contains('<data>Dw8PDw8PDw8PDw8PDw8PDw8PDw8=</data>'),
        );
        expect(
          File(constraintPath!).existsSync(),
          isFalse,
          reason: 'a codesign input must not survive into the workspace',
        );
      },
    );

    test('a signature with nothing to pin carries no constraint', () async {
      final tools = _tools(
        certificateOutput: 'SHA-256 hash: $_sha256\nSHA-1 hash: $_sha1\n',
      );

      await MacOsSigner(
        tools: tools,
      ).sign(binary: '/tmp/tool', team: 'TEAM123456', codeId: 'io.example');

      expect(
        tools.calls.singleWhere((call) => call.startsWith('codesign --force')),
        isNot(contains('--library-constraint')),
      );
    });

    test(
      'a malformed code hash is refused before anything is signed',
      () async {
        final tools = _tools(
          certificateOutput: 'SHA-256 hash: $_sha256\nSHA-1 hash: $_sha1\n',
        );

        final signed = await MacOsSigner(tools: tools).sign(
          binary: '/tmp/runtime',
          team: 'TEAM123456',
          codeId: 'io.example.tool',
          pinnedLibraries: ['not a hash'],
        );

        expect(signed.ok, isFalse);
        expect(signed.problem, contains('malformed'));
        expect(tools.calls, isEmpty);
      },
    );

    test('code hashes are every candidate codesign displays', () async {
      final tools = _tools(
        certificateOutput: '',
        displays: {
          'codesign -dvvv /tmp/app.aot': ToolResult(
            exitCode: 0,
            stdout: '',
            stderr:
                'Hash type=sha256 size=32\n'
                'CandidateCDHash sha1=$other\n'
                'CandidateCDHash sha256=$module\n'
                'CandidateCDHashFull sha256=${module}0123456789abcdef01234567\n'
                'CDHash=$module\n',
          ),
        },
      );

      expect(
        (await MacOsSigner(
          tools: tools,
        ).codeDirectoryHashes('/tmp/app.aot')).hashes,
        [other, module],
      );
    });

    test(
      'a module whose code hash cannot be read answers null with codesign',
      () async {
        final tools = _tools(
          certificateOutput: '',
          displays: {
            'codesign -dvvv /tmp/app.aot': ToolResult(
              exitCode: 1,
              stdout: '',
              stderr: 'not signed at all',
            ),
          },
        );

        final reading = await MacOsSigner(
          tools: tools,
        ).codeDirectoryHashes('/tmp/app.aot');
        expect(reading.hashes, isNull);
        expect(
          reading.display.stderr,
          contains('not signed at all'),
          reason: 'the failure must be able to show what codesign said',
        );
      },
    );
  });
}

RecordingTools _tools({
  required String certificateOutput,
  void Function(String key)? onSign,
  Map<String, ToolResult> displays = const {},
}) => RecordingTools(
  results: displays,
  onRun: (key) {
    if (key.startsWith('codesign --force')) {
      final path = key
          .split(' --entitlements ')
          .last
          .split(' --identifier ')
          .first;
      final entitlements = File(path).readAsStringSync();
      expect(entitlements, contains('<dict>'));
      expect(entitlements, isNot(contains('<key>')));
      onSign?.call(key);
    }
  },
  answers: (key) {
    if (key == 'security find-identity -v -p codesigning') {
      return ToolResult(exitCode: 0, stdout: '1) $_sha1 "$_name"', stderr: '');
    }
    if (key.startsWith('security find-certificate')) {
      return ToolResult(exitCode: 0, stdout: certificateOutput, stderr: '');
    }
    if (key.startsWith('codesign -d -r-')) {
      return ToolResult(
        exitCode: 0,
        stdout: 'designated => identifier "io.example.tool"',
        stderr: '',
      );
    }
    return null;
  },
);
